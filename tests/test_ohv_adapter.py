"""OpenHoopVision adapter: JSONL -> Perception + raw events, court geometry, bootstrap patch.

The fixture ``tests/fixtures/ohv_game.jsonl`` follows the basketball_frame_v2 records of
OHV commit ec969037 (20 analysed frames at 15 fps, 1280x720, plus a truncated tail line).
"""

from __future__ import annotations

import json
import math
import subprocess
import sys
from pathlib import Path

import pytest

from modal_app.pipeline import adapter, ohv
from modal_app.pipeline.types import VideoMeta
from modal_app.pipeline.video import FrameMap

FIXTURE = Path(__file__).parent / "fixtures" / "ohv_game.jsonl"
TEAM_COLORS_BGR = [(60, 20, 10), (240, 240, 245)]


def _meta(fps: float = 15.0, width: int = 1280, height: int = 720, analysis_fps: float = 15.0, step: int = 1) -> VideoMeta:
    return VideoMeta(
        path="game.mp4", filename="game.mp4", fps=fps, width=width, height=height,
        frame_count=int(round(20 * fps / 15)), duration_s=20 / 15, analysis_fps=analysis_fps, step=step, codec="h264",
    )  # fmt: skip


@pytest.fixture(scope="module")
def adapted() -> adapter.AdapterResult:
    return adapter.adapt_ohv(FIXTURE, _meta(), FrameMap.identity(15.0), team_colors_bgr=TEAM_COLORS_BGR)


def _event(adapted, type_, **attrs):
    for event in adapted.events:
        if event["type"] == type_ and all(event["attrs"].get(k) == v for k, v in attrs.items()):
            return event
    raise AssertionError(f"no {type_} event with {attrs}")


# ---------------------------------------------------------------------------
# Tracks, teams, jerseys
# ---------------------------------------------------------------------------


def test_tracks_are_keyed_by_global_player_id(adapted):
    players = {tid for tid, t in adapted.perception.tracks.items() if t.role == "player"}
    assert players == {1, 2, 3, 4, 5}  # the display-only overlay player (id None) is dropped
    assert adapted.perception.tracks[1].obs[0].bbox == (300.0, 300.0, 360.0, 480.0)
    assert adapted.perception.tracks[1].obs[0].conf == pytest.approx(0.91)


def test_frames_become_zero_based_original_frames(adapted):
    assert [o.frame for o in adapted.perception.tracks[1].obs] == list(range(20))
    # player 5's identity is withheld on the last frame (id None) -> no observation there
    assert [o.frame for o in adapted.perception.tracks[5].obs] == list(range(19))


def test_teams_dark_is_zero_light_is_one(adapted):
    tracks = adapted.perception.tracks
    assert (tracks[1].team_id, tracks[2].team_id, tracks[3].team_id, tracks[4].team_id, tracks[5].team_id) == (0, 0, 1, 1, 0)
    dark, light = adapted.perception.teams
    assert dark == {"team_id": 0, "color_rgb": (10, 20, 60), "color_name": "dark", "track_count": 3}
    assert light == {"team_id": 1, "color_rgb": (245, 240, 240), "color_name": "light", "track_count": 2}


def test_no_team_rgb_without_ohv_summary():
    result = adapter.adapt_ohv(FIXTURE, _meta(), FrameMap.identity(15.0))
    teams = result.perception.teams
    assert [(t["color_rgb"], t["color_name"]) for t in teams] == [(None, "dark"), (None, "light")]  # not measured


def test_jersey_reads_one_per_second_with_confidence(adapted):
    tracks = adapted.perception.tracks
    assert tracks[1].jersey_reads == [(0, "23", adapter.LOCKED_JERSEY_CONF), (15, "23", adapter.LOCKED_JERSEY_CONF)]
    assert tracks[2].jersey_reads == [(0, "4", adapter.CANDIDATE_JERSEY_CONF), (15, "4", adapter.CANDIDATE_JERSEY_CONF)]
    assert tracks[4].jersey_reads == []


def test_court_positions_convert_to_feet_at_known_points(adapted):
    tracks = adapted.perception.tracks
    assert tracks[1].obs[0].court_xy == pytest.approx((5.25, 25.0))  # OHV left basket
    assert tracks[2].obs[0].court_xy == pytest.approx((0.0, 50.0))  # OHV (0, 0): left baseline, far sideline
    assert tracks[3].obs[0].court_xy == pytest.approx((84.0, 0.0))  # OHV (L, W): right baseline, near sideline
    assert tracks[4].obs[0].court_xy is None  # OHV had no fresh court map for this player
    assert adapted.stats.court_coverage == pytest.approx(79 / 99)


def test_keypoints_kept_on_a_subset_of_frames(adapted):
    with_pose = [o.frame for o in adapted.perception.tracks[1].obs if o.keypoints is not None]
    assert with_pose == list(range(0, 20, adapter.KEYPOINT_EVERY_N))
    assert len(adapted.perception.tracks[1].obs[0].keypoints) == 17
    assert all(o.keypoints is None for o in adapted.perception.tracks[2].obs)  # OHV sent no pose


def test_referee_boxes_become_one_referee_track(adapted):
    referees = [t for t in adapted.perception.tracks.values() if t.role == "referee"]
    assert len(referees) == 1
    ref = referees[0]
    assert ref.track_id >= adapter.REFEREE_TRACK_ID_BASE and ref.team_id is None
    assert [o.frame for o in ref.obs] == [0, 3, 6, 9, 12, 15, 18]


def test_rim_segment(adapted):
    (rim,) = adapted.perception.rims
    assert (rim.side, rim.xy_px, rim.frame_start, rim.frame_end) == ("right", (1100.0, 246.0), 0, 19)


# ---------------------------------------------------------------------------
# Ball
# ---------------------------------------------------------------------------


def test_ball_holders_and_positions(adapted):
    ball = {b.frame: b for b in adapted.perception.ball}
    assert len(ball) == 20
    held = ball[0]
    assert (held.holder_track_id, held.interpolated, held.conf) == (1, False, pytest.approx(0.83))
    assert held.court_xy == pytest.approx((5.25, 25.0))  # ground position = the holder's
    loose = ball[3]
    assert (loose.holder_track_id, loose.court_xy, loose.xy) == (None, None, (620.0, 388.0))
    hidden = ball[5]  # OHV frame 6: no ball box, but OHV knows player 3 holds it
    assert (hidden.holder_track_id, hidden.interpolated, hidden.conf) == (3, True, adapter.HOLDER_BALL_CONF)
    assert hidden.xy == pytest.approx((750.0, 310 + 0.45 * 180))  # middle of player 3's box
    interpolated = ball[6]
    assert interpolated.interpolated and interpolated.conf == pytest.approx(0.3)
    assert adapted.stats.ball_coverage == pytest.approx(18 / 20)


# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------


def test_event_list_is_deduplicated_sorted_and_uniquely_numbered(adapted):
    assert [e["type"] for e in adapted.events] == ["pass", "shot", "rebound", "turnover", "shot", "shot", "turnover"]
    assert [e["frame"] for e in adapted.events] == sorted(e["frame"] for e in adapted.events)
    assert len({e["event_id"] for e in adapted.events}) == len(adapted.events)
    assert adapted.stats.dribbles == 1  # counted, not emitted
    assert all(e["attrs"]["source"] == "openhoopvision" for e in adapted.events)


def test_pass_event(adapted):
    event = _event(adapted, "pass")
    assert (event["frame"], event["t"], event["track_id"], event["team_id"]) == (1, round(1 / 15, 3), 1, 0)
    assert event["attrs"]["to_track"] == 2 and event["attrs"]["completed"] is True
    assert event["attrs"]["end_frame"] == 2


def test_missed_and_made_shots(adapted):
    miss = _event(adapted, "shot", made=False)
    assert (miss["frame"], miss["track_id"], miss["team_id"], miss["conf"]) == (4, 2, 0, 0.7)
    assert miss["attrs"]["is_three"] is False
    assert miss["attrs"]["shot_court_xy"] == pytest.approx([6.0 / adapter.FT, 50 - 7.0 / adapter.FT], abs=0.01)
    assert miss["attrs"]["shot_xy_px"] == [546.0, 500.0]  # shooter's feet at the release frame

    three = _event(adapted, "shot", made=True, is_three=True)
    assert (three["frame"], three["track_id"], three["conf"]) == (12, 1, 0.9)  # ball-in-basket confirmed
    assert three["attrs"]["assisted_by_track"] == 2
    assert three["attrs"]["points_source"] == "court_location"


def test_shot_without_global_id_uses_local_track_and_track_team(adapted):
    shot = _event(adapted, "shot", points_source="two_point_fallback")
    assert (shot["track_id"], shot["team_id"]) == (5, 0)  # local track 16 was global 5; OHV gave no team
    assert shot["attrs"]["made"] is True and shot["attrs"]["is_three"] is None
    assert shot["attrs"]["shot_court_xy"] is None


def test_rebound_and_turnovers(adapted):
    rebound = _event(adapted, "rebound")
    assert (rebound["frame"], rebound["track_id"], rebound["team_id"]) == (8, 3, 1)
    assert rebound["attrs"]["offensive"] is False
    steal = _event(adapted, "turnover", kind="steal")
    assert (steal["track_id"], steal["attrs"]["stolen_by_track"]) == (3, 1)
    other = _event(adapted, "turnover", kind="other")
    assert other["attrs"]["stolen_by_track"] is None and other["attrs"]["gained_by_track"] == 4


def test_truncated_last_line_is_skipped(adapted):
    assert adapted.stats.frames == 20 and adapted.stats.bad_lines == 1
    assert adapted.stats.median_players == 6


# ---------------------------------------------------------------------------
# Pre-transcode mapping, calibration
# ---------------------------------------------------------------------------


def test_transcoded_copy_maps_back_to_original_frames_and_pixels():
    meta = _meta(fps=30.0, width=1920, height=1080, analysis_fps=15.0, step=2)
    frame_map = FrameMap(source_fps=30.0, analysed_fps=15.0, scale_x=1.5, scale_y=1.5)
    result = adapter.adapt_ohv(FIXTURE, meta, frame_map)
    track = result.perception.tracks[1]
    assert [o.frame for o in track.obs] == list(range(0, 40, 2))
    assert track.obs[0].bbox == (450.0, 450.0, 540.0, 720.0)
    assert track.obs[0].keypoints[0] == pytest.approx((483.0, 450.0, 0.9))  # (322, 300) in the analysed copy
    assert track.jersey_reads == [(0, "23", adapter.LOCKED_JERSEY_CONF), (30, "23", adapter.LOCKED_JERSEY_CONF)]
    shot = next(e for e in result.events if e["type"] == "shot" and e["attrs"]["made"] is True and e["attrs"]["is_three"])
    assert (shot["frame"], shot["t"]) == (24, 0.8)
    assert shot["attrs"]["end_frame"] == 30
    assert shot["attrs"]["shot_xy_px"] == [567.0, 720.0]
    assert result.perception.ball[3].xy == (930.0, 582.0)
    assert result.perception.rims[0].xy_px == (1650.0, 369.0)


def test_manual_calibration_fills_missing_court_positions():
    # Calibrated on a 640x360 preview: feet = (px / 20, 50 - py / 20) at that size.
    calibration = {"matrix": [[0.05, 0, 0], [0, -0.05, 50], [0, 0, 1]], "video_width": 640, "video_height": 360}
    result = adapter.adapt_ohv(FIXTURE, _meta(), FrameMap.identity(15.0), calibration=calibration)
    perception = result.perception
    assert len(perception.homographies) == 1 and perception.homographies[0].source == "manual"
    # player 4 has no OHV court position: its feet (930, 510) -> preview (465, 255) -> feet
    assert perception.tracks[4].obs[0].court_xy == pytest.approx((23.25, 37.25))
    assert perception.tracks[1].obs[0].court_xy == pytest.approx((5.25, 25.0))  # OHV's own position wins
    loose = next(b for b in perception.ball if b.frame == 3)  # no holder: ground projection of the ball
    assert loose.court_xy == pytest.approx((15.5, 40.3))


def test_project_and_calibration_edge_cases():
    assert adapter.project([[1, 0, 0], [0, 1, 0], [0, 0, 0]], 1.0, 1.0) is None
    assert adapter.calibration_homography(None, _meta()) is None
    assert adapter.calibration_homography({"matrix": [[1, 0], [0, 1]]}, _meta()) is None


def test_missing_and_garbage_fields_are_tolerated(tmp_path):
    records = [
        {"frame": 1, "players": [{"id": 7, "box": [10, 10, 5, 50]}, {"id": "x", "box": [1, 2, 3]}, "junk"], "ball": {"center": ["a", 1]}},
        {"frame": 2, "players": [{"id": 7, "box": [10, 10, 40, 90], "team": "light", "court_xy": [float("nan"), 1.0], "jersey_number": "2B"}]},
        [1, 2, 3],
        {"players": [{"id": 7, "box": [12, 10, 42, 90], "pose": [[1, 2]]}], "events": [{"event": "shot"}, "x"]},
    ]
    path = tmp_path / "odd.jsonl"
    path.write_text("\n".join(json.dumps(r) for r in records) + "\n\n", encoding="utf-8")
    result = adapter.adapt_ohv(path, _meta(), FrameMap.identity(15.0))
    track = result.perception.tracks[7]
    assert [o.frame for o in track.obs] == [1, 2]  # record without "frame" -> next frame number
    assert track.team_id == 1 and track.obs[0].court_xy is None and track.obs[1].keypoints is None
    assert track.jersey_reads == []  # "2B" is not a jersey number
    assert result.events == [] and result.perception.ball == []
    assert result.stats.bad_lines == 1 and result.stats.frames == 3


# ---------------------------------------------------------------------------
# Court geometry patch + bootstrap
# ---------------------------------------------------------------------------


def test_ohv_court_to_feet():
    assert adapter.ohv_court_to_feet((0.0, 0.0), width_ft=50) == (0.0, 50.0)
    assert adapter.ohv_court_to_feet((25.6032, 15.24), width_ft=50) == pytest.approx((84.0, 0.0))
    assert adapter.ohv_court_to_feet((1.6002, 7.62), width_ft=50) == pytest.approx((5.25, 25.0))


def test_high_school_court_patch():
    patch = ohv.CourtSpec().to_ohv_patch()
    geometry = patch["geometry"]
    assert patch["length_m"] == pytest.approx(25.6032) and patch["width_m"] == pytest.approx(15.24)
    assert geometry["paint_width_m"] == pytest.approx(3.6576)  # 12 ft lane (NBA 16 ft)
    assert geometry["lane_half_width_m"] == pytest.approx(1.8288)
    assert geometry["free_throw_line_m"] == pytest.approx(5.7912)
    assert geometry["basket_offset_m"] == pytest.approx(1.6002)
    assert geometry["three_point_radius_m"] == pytest.approx(6.0198)  # 19'9"
    assert geometry["three_point_center_x_m"] == pytest.approx(7.62)  # top of the arc, 25 ft
    assert geometry["baseline_offset_m"] == pytest.approx(1.6002, abs=1e-5)  # corner line 5'3" from the sideline
    assert geometry["baseline_key_distance_m"] == pytest.approx(1.6002, abs=0.01)  # straight segment ends at the basket line
    assert geometry["three_point_corner_x_m"] == pytest.approx(8.5344)  # 28 ft sideline mark
    # OHV's events/scoring.py computes sqrt(r^2 - (W/2 - corner_y)^2): must stay real.
    radicand = geometry["three_point_radius_m"] ** 2 - (patch["width_m"] / 2 - geometry["baseline_offset_m"]) ** 2
    assert radicand >= 0
    assert ohv.CourtSpec(length_ft=74).to_ohv_patch()["length_m"] == pytest.approx(74 * 0.3048)


def _fake_ohv_tree(root: Path) -> None:
    (root / "tracking").mkdir(parents=True)
    (root / "events").mkdir()
    (root / "torch").mkdir()
    (root / "tracking" / "court.py").write_text(
        "COURT_LENGTH_M = 28.65\nCOURT_WIDTH_M = 15.24\n"
        "COURT_GEOMETRY = {'three_point_radius_m': 7.24, 'paint_width_m': 4.88}\n"
        "def court_paths():\n    return [COURT_LENGTH_M, COURT_GEOMETRY['three_point_radius_m']]\n"
        "COURT_PATHS = court_paths()\n"
    )
    # Like OHV's events/scoring.py and render/minimap.py: copies the constants at import time.
    (root / "events" / "scoring.py").write_text("from tracking.court import COURT_GEOMETRY, COURT_LENGTH_M, COURT_PATHS\n")
    (root / "torch" / "__init__.py").write_text("class cuda:\n    @staticmethod\n    def is_available():\n        return False\n")
    (root / "main.py").write_text(
        "import json, sys\n"
        "def main():\n"
        "    import events.scoring as scoring\n"
        "    out = sys.argv[sys.argv.index('--tracks') + 1]\n"
        "    with open(out, 'w') as fh:\n"
        "        json.dump({'argv': sys.argv[1:], 'length': scoring.COURT_LENGTH_M,\n"
        "                   'radius': scoring.COURT_GEOMETRY['three_point_radius_m'],\n"
        "                   'paint': scoring.COURT_GEOMETRY['paint_width_m'], 'paths': scoring.COURT_PATHS}, fh)\n"
    )


def test_bootstrap_patches_court_before_ohv_imports_it(tmp_path):
    home, work = tmp_path / "ohv", tmp_path / "work"
    _fake_ohv_tree(home)
    work.mkdir()
    bootstrap, court_file = ohv.write_launch_files(work, ohv.CourtSpec(length_ft=74.0))
    out = work / "out.json"
    proc = subprocess.run(
        [sys.executable, str(bootstrap), str(court_file), "--video", "v.mp4", "--tracks", str(out)],
        cwd=home, capture_output=True, text=True, check=False, env={"PATH": "/usr/bin:/bin"},
    )  # fmt: skip
    assert proc.returncode == 0, proc.stderr
    seen = json.loads(out.read_text())
    assert seen["argv"] == ["--video", "v.mp4", "--tracks", str(out)]
    assert seen["length"] == pytest.approx(74 * 0.3048)
    assert seen["radius"] == pytest.approx(6.0198) and seen["paint"] == pytest.approx(3.6576)
    assert seen["paths"] == pytest.approx([74 * 0.3048, 6.0198])  # derived paths recomputed
    assert "ohv-bootstrap: court 22.56 x 15.24 m" in proc.stdout


def test_bootstrap_refuses_to_run_without_cuda_when_required(tmp_path):
    home, work = tmp_path / "ohv", tmp_path / "work"
    _fake_ohv_tree(home)
    work.mkdir()
    bootstrap, court_file = ohv.write_launch_files(work, ohv.CourtSpec())
    proc = subprocess.run(
        [sys.executable, str(bootstrap), str(court_file), "--tracks", str(work / "t.json")],
        cwd=home, capture_output=True, text=True, check=False, env={"PATH": "/usr/bin:/bin", "OHV_REQUIRE_CUDA": "1"},
    )  # fmt: skip
    assert proc.returncode == ohv.NO_CUDA_EXIT_CODE
    assert not (work / "t.json").exists()


def test_court_conversion_is_consistent_with_the_patched_template():
    """Every OHV template keypoint lands on the matching high-school landmark in our frame."""
    patch = ohv.CourtSpec().to_ohv_patch()
    g, length_m, width_m = patch["geometry"], patch["length_m"], patch["width_m"]
    landmarks_m = {
        "left_basket": (g["basket_offset_m"], width_m / 2),
        "right_far_corner": (length_m, 0.0),
        "left_elbow_far": (g["free_throw_line_m"], (width_m - g["paint_width_m"]) / 2),
        "top_of_left_arc": (g["three_point_center_x_m"], width_m / 2),
    }
    feet = {name: adapter.ohv_court_to_feet(xy, width_ft=50.0) for name, xy in landmarks_m.items()}
    assert feet["left_basket"] == pytest.approx((5.25, 25.0))
    assert feet["right_far_corner"] == pytest.approx((84.0, 50.0))
    assert feet["left_elbow_far"] == pytest.approx((19.0, 31.0))  # far side of the 12 ft lane
    assert math.dist(feet["top_of_left_arc"], (5.25, 25.0)) == pytest.approx(19.75)


def test_orientation_check_flags_mirrored_positions():
    from modal_app.pipeline.types import Perception

    def check(pairs):
        builder = adapter._Builder(_meta(), FrameMap.identity(15.0), length_ft=84.0, width_ft=50.0, calibration=None)
        builder._orientation_pairs = pairs
        perception = Perception(video=_meta())
        builder._check_orientation(perception)
        return [w["code"] for w in perception.warnings]

    mirrored = [((10.0 + i, 8.0 + i % 4), (10.0 + i, 42.0 - i % 4)) for i in range(30)]
    agreeing = [((10.0 + i, 8.0 + i % 4), (10.5 + i, 8.0 + i % 4)) for i in range(30)]
    assert check(mirrored) == ["COURT_ORIENTATION_CHECK"]
    assert check(agreeing) == []
    assert check(mirrored[:5]) == []  # too little evidence


def test_calibrated_runs_collect_orientation_evidence():
    calibration = {"matrix": [[0.05, 0, 0], [0, -0.05, 50], [0, 0, 1]], "video_width": 640, "video_height": 360}
    result = adapter.adapt_ohv(FIXTURE, _meta(), FrameMap.identity(15.0), calibration=calibration)
    # The made-up calibration disagrees with OHV either way round: no orientation warning.
    assert "COURT_ORIENTATION_CHECK" not in {w["code"] for w in result.perception.warnings}
