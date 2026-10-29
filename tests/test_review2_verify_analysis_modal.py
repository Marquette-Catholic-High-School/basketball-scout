"""Verifier tests for the second review round: the GPU pipeline's new periods, timeouts and
FREE_THROWS_NOT_DETECTED warning together with the server's transform, end to end, the
unseen-defensive-rebound inference under the possession invariants, odd films, and one gap
in the local processor's address check (IPv6 site-local addresses)."""

from __future__ import annotations

import json
import random
import shutil
import socket
from collections import Counter
from pathlib import Path

import pytest

from modal_app.pipeline import errors, ohv, result, runner, video
from modal_app.pipeline.errors import PipelineError
from modal_app.pipeline.events import detect_events
from modal_app.pipeline.video import VideoProbe
from scout.analysis import pipeline
from scout.analysis.geometry import CourtConfig
from scout.analysis.plays import PlayRules
from scout.analysis.synthetic import generate_synthetic_game, synthetic_rosters
from scout.schemas import CourtCalibration, EventType, Game, RawEvent, RawEventType, TeamSide, TrackingResult
from tests.test_review2_modal import game_film, periods

S, O = TeamSide.SCOUTED, TeamSide.OTHER
FIXTURE = Path(__file__).parent / "fixtures" / "ohv_game.jsonl"  # 20 analysed frames at 15 fps, with court positions
FT_CODE = "FREE_THROWS_NOT_DETECTED"
PIPELINE_INFO = {"name": "openhoopvision", "version": "test", "models": {}, "options": {}}


# ---------------------------------------------------------------------------
# GPU periods and timeouts -> server possessions
# ---------------------------------------------------------------------------


def test_a_timeout_while_one_team_keeps_the_ball_ends_neither_the_possession_nor_the_period():
    # Team 0 has the ball 240-250 s, everyone sits at the bench for 70 s, team 0 has it again 320-340 s.
    film = game_film(("live", 250), ("stop", 70), ("live", 290))
    events = runner.merge_events(film, [])
    tracking = TrackingResult.model_validate(
        result.build_tracking_result(film, events, job_id="j_1", pipeline_info=PIPELINE_INFO)
    )
    analysis = pipeline.analyze_game(tracking, Game(scouted_team="Central", other_team="North"), {}, rules=PlayRules())

    rows = analysis.timeline
    assert [r.label for r in rows if r.type in (EventType.PERIOD_START, EventType.PERIOD_END)] == ["Start of Period 1"]
    (timeout,) = [r for r in rows if r.type == EventType.TIMEOUT]
    assert round(timeout.t) == 250 and timeout.side is None
    index = next(i for i, p in enumerate(analysis.possessions) if p.id == timeout.possession_id)
    held, after = analysis.possessions[index], analysis.possessions[index + 1]
    assert held.start_t == pytest.approx(240, abs=1) and not held.transition
    assert after.side != held.side and after.start_t > 335  # no new possession when team 0 came back with it


@pytest.mark.parametrize(
    ("segments", "expected"),
    [
        ((("live", 20),), ([(1, 0)], [], [])),  # very short
        ((("stop", 400),), ([], [], [])),  # all quiet: no live play at all
        ((("stop", 60), ("live", 30), ("stop", 60)), ([(1, 60)], [(1, 90)], [])),  # stoppages at both ends
        ((("live", 10), ("stop", 50), ("live", 10)), ([(1, 0)], [], [10])),  # too little play around it: a timeout
        (  # a long stoppage at the very start or end is no halftime
            (("stop", 900), ("live", 500), ("stop", 90), ("live", 500), ("stop", 900)),
            ([(1, 900), (2, 1490)], [(1, 1400), (2, 1990)], []),
        ),
    ],
    ids=["very-short", "all-quiet", "stoppage-at-both-ends", "short-film-timeout", "long-opening-and-closing"],
)
def test_the_period_detector_on_odd_films(segments, expected):
    assert periods(detect_events(game_film(*segments))) == expected


# ---------------------------------------------------------------------------
# FREE_THROWS_NOT_DETECTED: GPU warning -> tracking.json.gz -> DataQuality
# ---------------------------------------------------------------------------


@pytest.fixture
def unmapped_gpu_run(monkeypatch, tmp_path) -> Path:
    """run_pipeline (fake ffprobe / ffmpeg / OHV) on the OHV fixture without court positions;
    returns the tracking.json.gz it wrote."""
    records = [json.loads(line) for line in FIXTURE.read_text().splitlines() if line.strip().endswith("}")]
    for record in records:
        for player in record.get("players") or []:
            player.pop("court_xy", None)
    jsonl = tmp_path / "unmapped.jsonl"
    jsonl.write_text("".join(json.dumps(r) + "\n" for r in records))

    def run_ohv(video_path, work_dir, **kwargs):
        work = Path(work_dir)
        work.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(jsonl, work / "ohv_tracks.jsonl")
        return ohv.OhvRun(
            tracks_path=work / "ohv_tracks.jsonl", events_path=work / "ohv_events.json", output_video=None,
            params=ohv.OhvParams(), attempts=1, summary=ohv.OhvSummary(),
        )  # fmt: skip

    def transcode(src, dst, plan, *, progress=None):
        Path(dst).write_bytes(b"analysis copy")
        return Path(dst)

    probe = VideoProbe(
        path="film.mp4", fps=30.0, fps_rational="30/1", width=1920, height=1080, duration_s=40 / 30,
        frame_count=40, codec="h264",
    )  # fmt: skip
    monkeypatch.setattr(video, "probe_video", lambda path: probe)
    monkeypatch.setattr(video, "check_decodable", lambda path: None)
    monkeypatch.setattr(video, "transcode_for_analysis", transcode)
    monkeypatch.setattr(ohv, "run_ohv", run_ohv)
    monkeypatch.setattr(ohv, "gpu_name", lambda: None)
    film = tmp_path / "film.mp4"
    film.write_bytes(b"film")
    (tmp_path / "scratch").mkdir()
    options = {"render_video": False, "work_dir": str(tmp_path / "scratch")}
    response = runner.run_pipeline(str(film), options, output_dir=str(tmp_path / "out"), job_id="j_1")
    assert response["status"] == "ok", response
    return tmp_path / "out" / "tracking.json.gz"


def test_free_throws_not_detected_reaches_the_data_quality_once_also_after_a_calibrated_reanalysis(unmapped_gpu_run):
    tracking = pipeline.load_tracking(unmapped_gpu_run)
    gpu_codes = [w.code for w in tracking.warnings]
    assert gpu_codes.count(FT_CODE) == 1 and "NO_COURT_HOMOGRAPHY" in gpu_codes
    game =Game(id="g", scouted_team="Central", other_team="North", team_id_map={0: S, 1: O})
    calibration = CourtCalibration(points=[], matrix=[[0.05, 0, 0], [0, 0.05, 0], [0, 0, 1]], reprojection_error_ft=0.3)
    for current in (game, game.model_copy(update={"calibration": calibration})):
        quality = pipeline.analyze_game(tracking, current, {}, rules=PlayRules()).data_quality
        codes = [w.code for w in quality.warnings]
        assert codes.count(FT_CODE) == 1, codes  # the GPU's own: the server's backstop does not add a second one
    assert quality.coord_mode == "court" and "NO_COURT_HOMOGRAPHY" not in codes  # the calibration answers that one


# ---------------------------------------------------------------------------
# Unseen defensive rebounds keep the possession invariants
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("seed", [5, 11])
def test_possession_invariants_hold_without_rebounds_and_with_inferred_timeouts(seed):
    """No rebound events at all (every defensive rebound is unseen) and GPU-style timeouts at
    random moments: the box score, the running score and the possession points agree, and
    possessions alternate sides except across a period break."""
    tracking, truth = generate_synthetic_game(seed=seed, duration_s=300.0)
    rng = random.Random(seed)
    last = tracking.video.frame_count - 1
    timeouts = [
        RawEvent(event_id=f"to{i}", type=RawEventType.TIMEOUT, frame=f, t=f / tracking.video.fps, conf=0.43,
                 attrs={"inferred": True})
        for i, f in enumerate(sorted(rng.sample(range(last), 4)))
    ]  # fmt: skip
    events = [e for e in tracking.events if e.type != RawEventType.REBOUND] + timeouts
    game = Game(id="g_inv", scouted_team="Navy", other_team="White", team_id_map={0: S, 1: O})
    analysis = pipeline.analyze_game(
        tracking.model_copy(update={"events": events}), game, synthetic_rosters(game.id, seed=seed), [],
        court=CourtConfig(), rules=PlayRules(),
    )  # fmt: skip

    end = analysis.timeline[-1]
    running = {S: end.score_scouted, O: end.score_other}
    assert running == {S: truth.score["scouted"], O: truth.score["other"]}
    assert {b.side: b.totals.pts for b in analysis.box_scores} == running
    points = Counter()
    for p in analysis.possessions:
        points[p.side] += p.points
    assert dict(points) == running
    breaks = [r.t for r in analysis.timeline if r.type in (EventType.PERIOD_START, EventType.PERIOD_END)]
    for a, b in zip(analysis.possessions, analysis.possessions[1:], strict=False):
        assert a.side != b.side or any(a.start_t <= t <= b.start_t for t in breaks), (a.id, b.id)
    assert any(p.start_reason == "def_rebound" for p in analysis.possessions)
    assert not [r for r in analysis.timeline if r.type in (EventType.DREB, EventType.OREB)]


# ---------------------------------------------------------------------------
# public_only: IPv6 site-local addresses are private too
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("address", ["fec0::1", "fec0:0:0:1::5", "feff::1"])
def test_ipv6_site_local_addresses_are_not_public(address):
    assert video._is_public_address(address) is False


def test_public_only_refuses_a_name_that_resolves_to_a_site_local_address(monkeypatch, tmp_path):
    connections: list[tuple] = []

    def getaddrinfo(host, port, *args, **kwargs):
        return [(socket.AF_INET6, socket.SOCK_STREAM, 6, "", ("fec0::5", port, 0, 0))]

    def create_connection(address, *args, **kwargs):
        connections.append(address)
        raise ConnectionRefusedError("no server here")

    monkeypatch.setattr(socket, "getaddrinfo", getaddrinfo)
    monkeypatch.setattr(socket, "create_connection", create_connection)
    monkeypatch.setattr(video.time, "sleep", lambda seconds: None)
    with pytest.raises(PipelineError) as info:
        video.download_video("http://nas.example.org/film.mp4", tmp_path / "film.mp4", public_only=True)
    assert info.value.code == errors.VIDEO_DOWNLOAD_FAILED and "private or local network" in info.value.message
    assert connections == []
