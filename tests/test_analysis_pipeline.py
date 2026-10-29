"""load_tracking validation, analyze_game orchestration (collaborators faked) and save/load."""

from __future__ import annotations

import gzip
import json

import pytest

from scout.analysis import pipeline
from scout.analysis.plays import PlayRules
from scout.errors import ErrorCode, ScoutError
from scout.schemas import (
    CourtCalibration,
    Game,
    Play,
    PlayerRef,
    PlayType,
    PlayTypeSummary,
    PipelineWarning,
    Roster,
    RosterPlayer,
    ShotZone,
    TeamSide,
    TrackAssignment,
)
from tests import helpers

S, O = TeamSide.SCOUTED, TeamSide.OTHER


def _tracking(*, homography=True, court=True, length_ft=84.0):
    frames = range(0, 3600, 3)
    tracks = [
        helpers.track(1, 0, [(f, 25.5, 25.0) for f in frames], jersey="23", court=court),  # 1200 samples
        helpers.track(2, 0, [(f, 10.0, 25.0) for f in frames[:300]], jersey="14", court=court),  # 300 samples
        helpers.track(11, 1, [(f, 78.0, 25.0) for f in frames], jersey="3", court=court),
        helpers.track(99, None, [(f, 42.0, 1.0) for f in frames], role="referee", court=court),
    ]
    events = [
        helpers.event("j", "jump_ball", 0, won_by_team=0),
        helpers.event("s1", "shot", 150, track_id=1, team_id=0, made=True, shot_court_xy=[25.5, 25.0]),
        helpers.event("s2", "shot", 600, track_id=11, team_id=1, made=True, shot_court_xy=[78.0, 25.0]),
    ]
    tracking = helpers.tracking(tracks, events=events, homography=homography)
    court_info = tracking.court.model_copy(update={"length_ft": length_ft})
    warning = PipelineWarning(code="OCR_SPARSE", message="Few jersey numbers were readable.")
    return tracking.model_copy(update={"court": court_info, "warnings": [warning]})


def _game(**kw) -> Game:
    return Game(**{"scouted_team": "Central", "other_team": "North", "scouted_color": "navy", **kw})


def _rosters(game: Game) -> dict[TeamSide, Roster]:
    smith = RosterPlayer(id="p23", jersey="23", first_name="Sam", last_name="Smith")
    return {S: Roster(game_id=game.id, side=S, players=[smith]), O: Roster(game_id=game.id, side=O)}


def fake_assign_tracks(tracking, team_map, rosters, overrides=None):
    """Exact jersey matching only: enough to drive the transform without the real matcher."""
    out = []
    for t in tracking.tracks:
        if t.role == "referee":
            out.append(TrackAssignment(track_id=t.track_id, role="referee", frames=len(t.samples)))
            continue
        side = team_map.get(t.team_id)
        read = t.jersey_reads[0].text if t.jersey_reads else None
        player = next((p for p in rosters[side].players if p.jersey == read), None) if side else None
        out.append(TrackAssignment(
            track_id=t.track_id, team_id=t.team_id, side=side, player_id=player.id if player else None,
            jersey=read, best_read=read, match_score=1.0 if player else 0.0,
            method="exact" if player else "unrostered", frames=len(t.samples),
        ))
    return out


@pytest.fixture
def fakes(monkeypatch):
    calls: dict[str, int] = {}

    def count(name):
        calls[name] = calls.get(name, 0) + 1

    def detect(index, timeline, possessions, assignments, team_map, court, rules):
        count("detect")
        first = next(r for r in timeline if r.id == "s1")
        return [Play(id="pl_1", type=PlayType.ISOLATION, category="offense", side=S, start_t=first.t - 2,
                     end_t=first.t, start_frame=first.frame - 60, end_frame=first.frame,
                     players={"ball_handler": PlayerRef(jersey="23")})]

    def link(timeline, possessions, plays):
        count("link")
        for r in timeline:
            if r.id == "s1":
                r.play_id = "pl_1"

    def summarize(plays, possessions):
        count("summarize")
        return [PlayTypeSummary(type=PlayType.ISOLATION, category="offense", side=S, count=len(plays))]

    def load_rules(path=None):
        count("rules")
        return PlayRules()

    # raising=False: the real plays module may be mid-rewrite by its owner.
    monkeypatch.setattr(pipeline, "assign_tracks", fake_assign_tracks)
    for name, fake in (("load_play_rules", load_rules), ("detect_plays", detect), ("link_plays", link),
                       ("summarize_plays", summarize)):
        monkeypatch.setattr(pipeline.play_rec, name, fake, raising=False)
    return calls


# ---------------------------------------------------------------------------
# load_tracking
# ---------------------------------------------------------------------------


def test_load_tracking_plain_and_gzip(tmp_path):
    tracking = _tracking()
    plain = tmp_path / "tracking.json"
    plain.write_text(tracking.model_dump_json())
    packed = tmp_path / "tracking.json.gz"
    packed.write_bytes(gzip.compress(tracking.model_dump_json().encode()))
    assert pipeline.load_tracking(plain) == tracking
    assert pipeline.load_tracking(packed) == tracking


@pytest.mark.parametrize(
    ("content", "needle"),
    [
        (b"{not json", "not valid JSON"),
        (gzip.compress(b'{"schema_version": "1.0", "video": {}}')[:-12], "damaged"),
        (b"[1, 2, 3]", "not a JSON object"),
    ],
)
def test_load_tracking_unreadable(tmp_path, content, needle):
    path = tmp_path / "tracking.json.gz"
    path.write_bytes(content)
    with pytest.raises(ScoutError) as exc:
        pipeline.load_tracking(path)
    assert exc.value.code == ErrorCode.TRACKING_RESULT_INVALID and needle in exc.value.message


def test_load_tracking_wrong_major_version(tmp_path):
    data = json.loads(_tracking().model_dump_json())
    data["schema_version"] = "2.1"
    path = tmp_path / "tracking.json"
    path.write_text(json.dumps(data))
    with pytest.raises(ScoutError) as exc:
        pipeline.load_tracking(path)
    assert exc.value.code == ErrorCode.TRACKING_RESULT_INVALID
    assert "2.1" in exc.value.message and "1.0" in exc.value.message


def test_load_tracking_lists_first_validation_errors(tmp_path):
    data = json.loads(_tracking().model_dump_json())
    data["video"]["fps"] = 0
    for t in data["tracks"]:
        del t["track_id"]  # four more errors
    data["events"][0]["type"] = "dunk_contest"
    path = tmp_path / "tracking.json"
    path.write_text(json.dumps(data))
    with pytest.raises(ScoutError) as exc:
        pipeline.load_tracking(path)
    message = exc.value.message
    assert exc.value.code == ErrorCode.TRACKING_RESULT_INVALID
    assert "schema 1.0" in message and "video.fps" in message and "tracks.0.track_id" in message
    assert "... and 1 more" in message and exc.value.detail


def test_load_tracking_missing_file(tmp_path):
    with pytest.raises(ScoutError) as exc:
        pipeline.load_tracking(tmp_path / "nope.json.gz")
    assert exc.value.code == ErrorCode.TRACKING_RESULT_INVALID and "No tracking data" in exc.value.message


# ---------------------------------------------------------------------------
# analyze_game
# ---------------------------------------------------------------------------


def test_analyze_game_end_to_end_with_fakes(fakes):
    game = _game()
    analysis = pipeline.analyze_game(_tracking(), game, _rosters(game))
    assert fakes == {"rules": 1, "detect": 1, "link": 1, "summarize": 1}
    assert analysis.game_id == game.id and analysis.generated_at.tzinfo is not None

    scouted, other = analysis.team(S), analysis.team(O)
    assert (scouted.name, scouted.team_id, scouted.color_name, scouted.score) == ("Central", 0, "navy", 3)
    assert (other.name, other.team_id, other.color_rgb, other.score) == ("North", 1, (240, 240, 240), 2)

    box = analysis.box_score(S)
    assert box.team_name == "Central" and box.totals.pts == 3
    assert [(line.player.label, line.pts) for line in box.players] == [("#23 Sam Smith", 3)]
    assert analysis.box_score(O).players[0].player.label == "#3"

    assert analysis.shots[0].play_id == "pl_1" and analysis.shots[0].zone == ShotZone.THREE
    assert analysis.plays[0].id == "pl_1" and analysis.play_summary[0].count == 1
    assert len(analysis.track_assignments) == 4
    assert analysis.timeline[-1].score_scouted == 3 and analysis.timeline[-1].score_other == 2
    assert any(r.label == "Possession: North" for r in analysis.timeline)

    dq = analysis.data_quality
    assert dq.homography_available and dq.coord_mode == "court"
    assert dq.jersey_match_rate == pytest.approx(0.8)  # 1200 of 1500 scouted samples; North has no roster
    assert dq.unmatched_jerseys == ["scouted:#14"]
    assert (dq.tracks_total, dq.tracks_assigned) == (3, 1)
    assert dq.event_confidence_mean == pytest.approx(0.9)
    codes = [w.code for w in dq.warnings]
    assert codes == ["OCR_SPARSE", "NO_ROSTER"]
    assert dq.warnings[1].message == "No roster for North: players are shown by jersey number only"


def test_analyze_game_uses_manual_calibration_rescaled(fakes):
    # Calibration clicked on a half-resolution frame: 10 px = 1 ft there, so 20 px = 1 ft in the film.
    calibration = CourtCalibration(points=[], matrix=[[0.1, 0, 0], [0, 0.1, 0], [0, 0, 1]],
                                   reprojection_error_ft=0.2, video_width=960, video_height=540)
    tracking = _tracking(homography=False, court=False)
    tracking.events[1].attrs = {"made": True, "shot_xy_px": [120.0, 500.0]}  # (6, 25) ft: at the rim
    game = _game(calibration=calibration)
    analysis = pipeline.analyze_game(tracking, game, _rosters(game))
    assert analysis.data_quality.homography_available and analysis.data_quality.coord_mode == "court"
    assert analysis.shots[0].court_xy == pytest.approx((6.0, 25.0))
    assert analysis.shots[0].subzone == "restricted_area"


def test_analyze_game_without_court_mapping_warns(fakes):
    tracking = _tracking(homography=False, court=False)
    for e in tracking.events:
        e.attrs.pop("shot_court_xy", None)  # an unmapped court has no court coordinates
    game = _game()
    analysis = pipeline.analyze_game(tracking, game, _rosters(game))
    dq = analysis.data_quality
    assert not dq.homography_available and dq.coord_mode == "pixel"
    assert "COURT_NOT_MAPPED" in [w.code for w in dq.warnings]
    assert all(s.zone == ShotZone.UNKNOWN for s in analysis.shots)


def test_analyze_game_uses_pipeline_court_size(fakes):
    tracking = _tracking(length_ft=74.0)
    tracking.events[2].attrs = {"made": True, "shot_court_xy": [69.0, 25.0]}  # right rim of a 74 ft court
    game = _game()
    analysis = pipeline.analyze_game(tracking, game, _rosters(game))
    assert next(s for s in analysis.shots if s.event_id == "s2").subzone == "restricted_area"


def test_analyze_game_low_match_rate_and_missing_rosters(fakes):
    game = _game(other_team="")
    analysis = pipeline.analyze_game(_tracking(), game, {})
    dq = analysis.data_quality
    assert analysis.team(O).name == "Other team"
    assert dq.jersey_match_rate == 0.0 and dq.unmatched_jerseys == []
    assert [w.severity for w in dq.warnings if w.code == "NO_ROSTER"] == ["warning", "info"]

    smith14 = RosterPlayer(id="p14", jersey="14", last_name="Bench")
    analysis = pipeline.analyze_game(_tracking(), game, {S: Roster(game_id=game.id, side=S, players=[smith14])})
    assert analysis.data_quality.jersey_match_rate == pytest.approx(0.2)
    assert "LOW_JERSEY_MATCH" in [w.code for w in analysis.data_quality.warnings]


def test_analyze_game_error_wrapping(fakes, monkeypatch):
    game = _game()

    def roster_trouble(*args, **kwargs):
        raise ScoutError(ErrorCode.ROSTER_PARSE_FAILED, "bad roster")

    monkeypatch.setattr(pipeline, "assign_tracks", roster_trouble)
    with pytest.raises(ScoutError) as exc:
        pipeline.analyze_game(_tracking(), game, _rosters(game))
    assert exc.value.code == ErrorCode.ROSTER_PARSE_FAILED  # ScoutErrors pass through unchanged

    def boom(*args, **kwargs):
        raise RuntimeError("boom")

    monkeypatch.setattr(pipeline, "assign_tracks", boom)
    with pytest.raises(ScoutError) as exc:
        pipeline.analyze_game(_tracking(), game, _rosters(game))
    assert exc.value.code == ErrorCode.ANALYSIS_FAILED and exc.value.retryable
    assert "RuntimeError: boom" in exc.value.detail


# ---------------------------------------------------------------------------
# save / load
# ---------------------------------------------------------------------------


def test_save_and_load_analysis_roundtrip(fakes, tmp_path):
    game = _game()
    analysis = pipeline.analyze_game(_tracking(), game, _rosters(game))
    path = tmp_path / "games" / "g1" / "analysis.json"
    pipeline.save_analysis(analysis, path)
    assert pipeline.load_analysis(path).model_dump() == analysis.model_dump()
    assert not list(path.parent.glob("*.tmp"))  # atomic write leaves no temp files
    packed = tmp_path / "analysis.json.gz"
    pipeline.save_analysis(analysis, packed)
    assert packed.read_bytes()[:2] == b"\x1f\x8b"
    assert pipeline.load_analysis(packed).model_dump() == analysis.model_dump()


def test_load_analysis_errors(tmp_path):
    with pytest.raises(ScoutError) as exc:
        pipeline.load_analysis(tmp_path / "missing.json")
    assert exc.value.code == ErrorCode.ANALYSIS_NOT_READY
    bad = tmp_path / "analysis.json"
    bad.write_text('{"game_id": "g"}')
    with pytest.raises(ScoutError) as exc:
        pipeline.load_analysis(bad)
    assert exc.value.code == ErrorCode.ANALYSIS_FAILED
