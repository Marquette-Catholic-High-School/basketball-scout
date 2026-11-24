"""Live games (docs/LIVE.md): the join of the parts' tracking, the API and the LIVE job."""

from __future__ import annotations

import threading
import time
from datetime import timedelta

import pytest
from fastapi.testclient import TestClient

from scout import config, db, live, storage
from scout.analysis import synthetic
from scout.analysis.live_merge import (
    PARTS_MISSING_CODE,
    TRACK_ID_BLOCK,
    LiveJoin,
    Part,
    global_track_id,
    is_live_tracking,
    merge_parts,
)
from scout.errors import ErrorCode, ScoutError
from scout.processing.base import PollResult
from scout.schemas import (
    GameStatus,
    JobKind,
    JobStatus,
    LiveEndReason,
    LiveInfo,
    LiveSegment,
    LiveSegmentStatus,
    LiveState,
    RawEventType,
    TeamInfo,
)
from tests import helpers

# ---------------------------------------------------------------------------
# Joining the parts
# ---------------------------------------------------------------------------


def _part(seed: int, seconds: float = 60.0):
    tracking, _ = synthetic.generate_synthetic_game(seed=seed, duration_s=seconds, roster_seed=7)
    return tracking


def test_join_moves_frames_tracks_and_events_onto_one_timeline():
    first, second = _part(11), _part(12)
    merged = merge_parts([Part(1, 60, second), Part(0, 60, first)])

    assert merged.video.frame_count == first.video.frame_count + second.video.frame_count
    assert merged.video.duration_s == pytest.approx(120.0, abs=0.1)
    assert is_live_tracking(merged)
    assert merged.pipeline.options["parts"] == 2 and merged.pipeline.options["parts_analysed"] == 2

    offset = first.video.frame_count
    ids = {t.track_id for t in merged.tracks}
    assert {t.track_id for t in first.tracks} <= ids  # part 0 keeps its ids
    assert {TRACK_ID_BLOCK + t.track_id for t in second.tracks} <= ids
    moved = next(t for t in merged.tracks if t.track_id == global_track_id(1, second.tracks[0].track_id))
    assert moved.samples[0].f == second.tracks[0].samples[0].f + offset
    assert [r.frame for r in moved.jersey_reads] == [r.frame + offset for r in second.tracks[0].jersey_reads]

    held = [b for b in merged.ball if b.f >= offset and b.holder_track_id is not None]
    assert held and all(b.holder_track_id >= TRACK_ID_BLOCK for b in held)
    assert all(e.t == pytest.approx(e.frame / merged.video.fps, abs=0.01) for e in merged.events)
    assert len({e.event_id for e in merged.events}) == len(merged.events)
    assert [e.frame for e in merged.events] == sorted(e.frame for e in merged.events)


def test_join_remaps_the_tracks_an_event_names():
    def make(shooter: int, passer: int):
        tracks = [helpers.track(shooter, 0, [(0, 10, 10), (30, 12, 10)]), helpers.track(passer, 0, [(0, 20, 10), (30, 22, 10)])]
        events = [
            helpers.event("e1", "pass", 10, track_id=passer, team_id=0, to_track=shooter),
            helpers.event("e2", "shot", 20, track_id=shooter, team_id=0, made=True, assisted_by_track=passer, blocked_by_track=None),
        ]
        return helpers.tracking(tracks, events=events, duration_s=2.0)

    merged = merge_parts([Part(0, 2, make(1, 2)), Part(3, 2, make(5, 6))], detect_periods=False)
    late = [e for e in merged.events if e.frame >= 60]
    assert [e.event_id for e in late] == ["p0003-e1", "p0003-e2"]
    assert late[0].track_id == 3 * TRACK_ID_BLOCK + 6 and late[0].attrs["to_track"] == 3 * TRACK_ID_BLOCK + 5
    assert late[1].attrs["assisted_by_track"] == 3 * TRACK_ID_BLOCK + 6
    assert late[1].attrs["blocked_by_track"] is None and late[1].attrs["made"] is True


def test_join_matches_teams_by_colour_when_a_part_numbers_them_the_other_way():
    first = helpers.tracking([helpers.track(1, 0, [(0, 1, 1)]), helpers.track(2, 1, [(0, 2, 2)])], duration_s=1.0)
    second = helpers.tracking(
        [helpers.track(1, 0, [(0, 1, 1)]), helpers.track(2, 1, [(0, 2, 2)])],
        events=[helpers.event("e1", "jump_ball", 3, won_by_team=0)],
        duration_s=1.0,
    )
    second = second.model_copy(
        update={"teams": [TeamInfo(team_id=0, color_rgb=(238, 238, 238), color_name="white"), TeamInfo(team_id=1, color_rgb=(22, 22, 58), color_name="navy")]}
    )
    merged = merge_parts([Part(0, 1, first), Part(1, 1, second)], detect_periods=False)
    by_id = {t.track_id: t.team_id for t in merged.tracks}
    assert by_id[1] == 0 and by_id[2] == 1
    assert by_id[TRACK_ID_BLOCK + 1] == 1 and by_id[TRACK_ID_BLOCK + 2] == 0  # white is team 1 in the join
    assert next(e for e in merged.events if e.type == RawEventType.JUMP_BALL).attrs["won_by_team"] == 1
    assert [t.color_name for t in merged.teams] == ["navy", "white"]

    unnamed = second.model_copy(update={"teams": [t.model_copy(update={"color_name": None}) for t in second.teams]})
    merged = merge_parts([Part(0, 1, first), Part(1, 1, unnamed)], detect_periods=False)
    assert {t.track_id: t.team_id for t in merged.tracks}[TRACK_ID_BLOCK + 1] == 1  # by the colour itself


def test_a_part_without_tracking_keeps_its_time_and_is_reported():
    a, b = _part(21), _part(22)
    merged = merge_parts([Part(0, 60, None), Part(1, 60, a), Part(2, 60, None), Part(3, 60, b)])
    fps = merged.video.fps
    assert merged.video.duration_s == pytest.approx(240.0, abs=0.2)
    assert min(s.f for t in merged.tracks for s in t.samples) >= round(60 * fps)  # nothing in the first minute
    late = [t for t in merged.tracks if t.track_id >= 3 * TRACK_ID_BLOCK]
    assert late and min(s.f for t in late for s in t.samples) >= round(180 * fps)
    warning = next(w for w in merged.warnings if w.code == PARTS_MISSING_CODE)
    assert "0:00-1:00" in warning.message and "2:00-3:00" in warning.message
    # The minute nobody was seen in is not a timeout.
    assert not [e for e in merged.events if e.type == RawEventType.TIMEOUT and round(118 * fps) <= e.frame <= round(180 * fps)]


def test_a_part_without_play_is_a_break_not_a_hole():
    from scout.analysis.live_merge import NO_PLAY_CODE

    a, b = _part(23), _part(24)
    merged = merge_parts([Part(0, 60, a), Part(1, 60, None, empty=True), Part(2, 60, None, empty=True), Part(3, 60, b)])
    fps = merged.video.fps
    codes = {w.code: w for w in merged.warnings}
    assert PARTS_MISSING_CODE not in codes
    assert codes[NO_PLAY_CODE].severity == "info" and "1:00-3:00" in codes[NO_PLAY_CODE].message
    # Two minutes without anybody on the floor is a stoppage the period detector may use.
    breaks = [e for e in merged.events if e.type in (RawEventType.TIMEOUT, RawEventType.PERIOD_END)]
    assert any(round(55 * fps) <= e.frame <= round(125 * fps) for e in breaks)


def test_each_part_s_own_periods_are_replaced_by_the_game_s():
    parts = [Part(i, 60, _part(30 + i)) for i in range(3)]
    assert all(any(e.type == RawEventType.PERIOD_START for e in p.tracking.events) for p in parts)
    merged = merge_parts(parts)
    starts = [e for e in merged.events if e.type == RawEventType.PERIOD_START]
    assert len(starts) == 1 and starts[0].attrs["period"] == 1 and starts[0].event_id.startswith("lp")
    assert starts[0].frame < parts[0].tracking.video.frame_count  # in the first part


def test_nothing_to_join_until_a_part_is_analysed():
    join = LiveJoin()
    join.add(Part(0, 60, None))
    with pytest.raises(ValueError, match="no analysed part"):
        join.result()
    assert join.duration_s == 0.0
    join.add(Part(1, 60, _part(41)))
    assert join.duration_s == pytest.approx(120.0, abs=0.2) and join.analysed == 1 and join.parts == 2
    with pytest.raises(ValueError, match="added after"):
        join.add(Part(1, 60, None))


def test_the_join_analyses_like_any_tracking(game):
    from scout.analysis import pipeline

    merged = merge_parts([Part(i, 90, _part(50 + i, 90)) for i in range(3)])
    rosters = synthetic.synthetic_rosters(game.id, seed=7)
    analysis = pipeline.analyze_game(merged, game, rosters, [])
    named = [line for box in analysis.box_scores for line in box.players if line.player.player_id]
    assert named, "players of all parts are matched to the one roster"
    assert sum(box.totals.pts for box in analysis.box_scores) > 0
    assert max(e.t for e in analysis.timeline) > 180  # events from the last part
    matched = {a.track_id // TRACK_ID_BLOCK for a in analysis.track_assignments if a.player_id}
    assert matched == {0, 1, 2}, "tracks of every part are matched"


# ---------------------------------------------------------------------------
# Which parts are settled
# ---------------------------------------------------------------------------


def _segment(index: int, status: LiveSegmentStatus, *, age_s: float = 0.0) -> LiveSegment:
    return LiveSegment(
        game_id="g_1", index=index, duration_s=60, size=10, status=status, uploaded_at=db.utcnow() - timedelta(seconds=age_s)
    )


def test_settled_prefix_stops_at_the_first_part_still_on_the_gpu():
    done, busy, failed = LiveSegmentStatus.DONE, LiveSegmentStatus.PROCESSING, LiveSegmentStatus.FAILED
    info = LiveInfo(segment_seconds=60)
    now = db.utcnow()
    assert live.settled_prefix([], info, now) == []
    prefix = live.settled_prefix([_segment(0, done), _segment(1, failed), _segment(2, busy), _segment(3, done)], info, now)
    assert [(p.index, p.analysed) for p in prefix] == [(0, True), (1, False)]


def test_settled_prefix_skips_a_part_that_is_not_coming():
    done = LiveSegmentStatus.DONE
    info = LiveInfo(segment_seconds=75)
    now = db.utcnow()
    fresh = [_segment(0, done), _segment(2, done, age_s=5)]
    assert [p.index for p in live.settled_prefix(fresh, info, now)] == [0]  # part 1 may still arrive
    waited = [_segment(0, done), _segment(2, done, age_s=live.GAP_GRACE_S + 1), _segment(3, LiveSegmentStatus.EMPTY)]
    prefix = live.settled_prefix(waited, info, now)
    assert [(p.index, p.analysed, p.duration_s) for p in prefix] == [(0, True, 60), (1, False, 75), (2, True, 60), (3, False, 60)]
    assert [p.empty for p in prefix] == [False, False, False, True]
    ending = LiveInfo(segment_seconds=75, state=LiveState.FINISHING)
    assert [p.index for p in live.settled_prefix(fresh, ending, now)] == [0, 1, 2]


def test_segment_job_ids_round_trip():
    assert live.segment_job_id("j_ab12", 7) == "j_ab12-p00007"
    assert live.parent_job_id("j_ab12-p00007") == "j_ab12"
    assert live.parent_job_id("j_ab12") == "j_ab12"


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------


def _fake_mp4(size: int = 4096) -> bytes:
    head = b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 12
    return head + b"\x11" * (size - len(head))


@pytest.fixture
def client(auth_headers, monkeypatch):
    monkeypatch.setenv("SCOUT_MOCK_SECONDS", "0")
    config.reset_settings()
    from scout.main import create_app

    with TestClient(create_app()) as test_client:
        test_client.headers.update(auth_headers)
        yield test_client


def _new_game(client) -> str:
    r = client.post("/api/games", json={"scouted_team": "Central", "other_team": "North", "scouted_color": "dark"})
    assert r.status_code == 201, r.text
    return r.json()["id"]


def _send_part(client, game_id: str, index: int, *, seconds: float = 60.0, data: bytes | None = None):
    data = data or _fake_mp4()
    r = client.post(f"/api/games/{game_id}/live/segments", json={"index": index, "duration_s": seconds, "size": len(data)})
    if r.status_code not in (200, 201) or r.json()["status"] == "complete":
        return r
    upload = r.json()
    r = client.put(
        f"/api/uploads/{upload['id']}/chunk",
        params={"offset": upload["received"]},
        content=data[upload["received"] :],
        headers={"Content-Type": "application/octet-stream"},
    )
    assert r.status_code == 200, r.text
    return client.post(f"/api/uploads/{upload['id']}/complete")


def test_start_live_makes_the_game_live_and_queues_its_job(client):
    game_id = _new_game(client)
    r = client.post(f"/api/games/{game_id}/live", json={"segment_seconds": 90})
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["game"]["live"]["state"] == "capturing" and body["game"]["live"]["segment_seconds"] == 90
    assert body["game"]["status"] == "queued" and body["segments"] == []
    assert body["job"]["kind"] == "live" and body["job"]["id"] == body["game"]["latest_job_id"]

    again = client.post(f"/api/games/{game_id}/live")  # the app restarted: same session
    assert again.status_code == 200 and again.json()["job"]["id"] == body["job"]["id"]
    assert len(db.list_jobs(game_id=game_id)) == 1
    assert client.get(f"/api/games/{game_id}/live").json()["game"]["id"] == game_id
    assert client.get(f"/api/games/{game_id}").json()["live"]["segment_seconds"] == 90


def test_start_live_defaults_and_limits(client, settings):
    game_id = _new_game(client)
    r = client.post(f"/api/games/{game_id}/live")
    assert r.status_code == 201 and r.json()["game"]["live"]["segment_seconds"] == settings.live_segment_seconds
    other = _new_game(client)
    assert client.post(f"/api/games/{other}/live", json={"segment_seconds": 5}).status_code == 422
    assert client.get(f"/api/games/{other}/live").status_code == 404
    assert client.post(f"/api/games/{other}/jobs", json={"kind": "live"}).status_code == 422


def test_a_game_with_film_cannot_go_live(client):
    game_id = _new_game(client)
    data = _fake_mp4()
    upload = client.post(f"/api/games/{game_id}/uploads", json={"filename": "game.mp4", "size": len(data)}).json()
    client.put(f"/api/uploads/{upload['id']}/chunk", params={"offset": 0}, content=data)
    assert client.post(f"/api/uploads/{upload['id']}/complete", params={"auto_start": "false"}).status_code == 200
    r = client.post(f"/api/games/{game_id}/live")
    assert r.status_code == 409 and r.json()["error"]["code"] == "CONFLICT"
    assert db.get_game(game_id).live is None


def test_parts_arrive_through_the_chunked_upload(client):
    game_id = _new_game(client)
    client.post(f"/api/games/{game_id}/live")
    r = _send_part(client, game_id, 0, seconds=61.5)
    assert r.status_code == 200, r.text
    info = r.json()["game"]["live"]
    assert info["segments_received"] == 1 and info["received_s"] == 61.5 and info["last_segment_at"]
    assert r.json()["job"]["kind"] == "live"
    assert storage.live_segment_video_path(game_id, 0).read_bytes() == _fake_mp4()
    assert storage.find_source_video(game_id) is None and not db.get_game(game_id).has_video

    segment = db.get_live_segment(game_id, 0)
    assert segment.status == LiveSegmentStatus.UPLOADED and segment.duration_s == 61.5

    again = client.post(f"/api/games/{game_id}/live/segments", json={"index": 0, "duration_s": 61.5, "size": 4096})
    assert again.status_code == 200 and again.json()["status"] == "complete"  # already here: nothing to send
    _send_part(client, game_id, 1)
    status = client.get(f"/api/games/{game_id}/live").json()
    assert [s["index"] for s in status["segments"]] == [0, 1] and status["game"]["live"]["received_s"] == 121.5


def test_a_half_sent_part_resumes(client):
    game_id = _new_game(client)
    client.post(f"/api/games/{game_id}/live")
    data = _fake_mp4(6000)
    first = client.post(f"/api/games/{game_id}/live/segments", json={"index": 0, "duration_s": 60, "size": len(data)})
    assert first.status_code == 201
    upload = first.json()
    client.put(f"/api/uploads/{upload['id']}/chunk", params={"offset": 0}, content=data[:2500])
    resumed = client.post(f"/api/games/{game_id}/live/segments", json={"index": 0, "duration_s": 60, "size": len(data)})
    assert resumed.status_code == 200 and resumed.json()["id"] == upload["id"] and resumed.json()["received"] == 2500
    assert _send_part(client, game_id, 0, data=data).status_code == 200
    assert storage.live_segment_video_path(game_id, 0).read_bytes() == data

    other = client.post(f"/api/games/{game_id}/live/segments", json={"index": 1, "duration_s": 60, "size": 5000}).json()
    replaced = client.post(f"/api/games/{game_id}/live/segments", json={"index": 1, "duration_s": 60, "size": 7000})
    assert replaced.status_code == 201 and replaced.json()["id"] != other["id"]  # not the same file: start over
    assert db.get_upload(other["id"]).status == "aborted"


def test_parts_are_refused_when_they_are_not_video_or_the_game_is_not_live(client):
    game_id = _new_game(client)
    r = client.post(f"/api/games/{game_id}/live/segments", json={"index": 0, "duration_s": 60, "size": 10})
    assert r.status_code == 404
    client.post(f"/api/games/{game_id}/live")
    r = client.post(f"/api/games/{game_id}/live/segments", json={"index": 0, "duration_s": 60, "size": 10, "filename": "a.mov"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "VIDEO_INVALID"
    bad = _send_part(client, game_id, 0, data=b"not a video at all, just text....")
    assert bad.status_code == 422 and bad.json()["error"]["code"] == "VIDEO_INVALID"
    assert db.get_live_segment(game_id, 0) is None
    # A normal film upload has to wait for the live game.
    r = client.post(f"/api/games/{game_id}/uploads", json={"filename": "game.mp4", "size": 4096})
    assert r.status_code == 409 and "live" in r.json()["error"]["message"]


def test_finish_stops_the_game_taking_film(client):
    game_id = _new_game(client)
    client.post(f"/api/games/{game_id}/live")
    _send_part(client, game_id, 0)
    open_upload = client.post(f"/api/games/{game_id}/live/segments", json={"index": 1, "duration_s": 60, "size": 4096}).json()
    r = client.post(f"/api/games/{game_id}/live/finish")
    assert r.status_code == 200 and r.json()["game"]["live"]["state"] == "finishing"
    assert r.json()["game"]["live"]["end_reason"] == "finished"
    assert client.post(f"/api/games/{game_id}/live/finish").status_code == 200  # asked twice
    assert db.get_upload(open_upload["id"]).status == "aborted"
    late = client.post(f"/api/games/{game_id}/live/segments", json={"index": 2, "duration_s": 60, "size": 4096})
    assert late.status_code == 409 and late.json()["error"]["code"] == "LIVE_ENDED"


def test_the_game_ends_at_the_longest_film_the_server_takes(client, monkeypatch):
    monkeypatch.setenv("SCOUT_MAX_VIDEO_MINUTES", "2")
    config.reset_settings()
    from scout.main import create_app

    with TestClient(create_app()) as limited:
        limited.headers.update(client.headers)
        game_id = _new_game(limited)
        limited.post(f"/api/games/{game_id}/live")
        assert _send_part(limited, game_id, 0, seconds=100).status_code == 200
        r = limited.post(f"/api/games/{game_id}/live/segments", json={"index": 1, "duration_s": 100, "size": 4096})
        assert r.status_code == 409 and r.json()["error"]["code"] == "LIVE_ENDED" and "2 minutes" in r.json()["error"]["message"]
        info = db.get_game(game_id).live
        assert info.state == LiveState.FINISHING and info.end_reason == LiveEndReason.LIMIT


def test_cancelling_a_queued_live_job_ends_the_game(client):
    game_id = _new_game(client)
    job_id = client.post(f"/api/games/{game_id}/live").json()["job"]["id"]
    r = client.post(f"/api/jobs/{job_id}/cancel")
    assert r.json()["status"] == "cancelled"
    game = db.get_game(game_id)
    assert game.live.state == LiveState.ENDED and game.live.end_reason == LiveEndReason.CANCELLED
    assert game.status == GameStatus.DRAFT
    assert client.post(f"/api/games/{game_id}/live").status_code == 201  # nothing arrived: it may start again


# ---------------------------------------------------------------------------
# The LIVE job
# ---------------------------------------------------------------------------


def _worker(**changes):
    from scout.worker import Worker

    worker = Worker(worker_id="test-worker")
    worker.processor.poll_interval = 0.02
    for name, value in changes.items():
        setattr(worker, name, value)
    return worker


def _wait(condition, timeout: float = 20.0, message: str = "condition"):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = condition()
        if value:
            return value
        time.sleep(0.02)
    raise AssertionError(f"timed out waiting for {message}")


def test_live_game_fills_in_part_by_part_and_ends_as_a_normal_game(client, monkeypatch):
    joined: list[int] = []

    def fake_join(game_id, segments):  # ffmpeg is not there in the tests
        joined.extend(s.index for s in segments)
        film = storage.source_video_path(game_id)
        film.write_bytes(b"".join(storage.live_segment_video_path(game_id, s.index).read_bytes() for s in segments))
        return film

    monkeypatch.setattr(live, "join_film", fake_join)
    game_id = _new_game(client)
    job_id = client.post(f"/api/games/{game_id}/live", json={"segment_seconds": 60}).json()["job"]["id"]
    worker = _worker()
    thread = threading.Thread(target=worker.run_once, kwargs={"timeout": 2}, daemon=True)
    thread.start()
    try:
        _wait(lambda: db.get_job(job_id).status == JobStatus.RUNNING, message="the worker to take the job")
        _wait(lambda: db.get_game(game_id).status == GameStatus.PROCESSING, message="the game to show as processing")

        _send_part(client, game_id, 0)
        first = _wait(lambda: (g := db.get_game(game_id)).live.analysis_version >= 1 and g, message="the first analysis")
        assert first.status == GameStatus.READY and first.has_analysis and not first.has_video
        assert first.live.segments_analysed == 1 and first.live.analysed_s == pytest.approx(60, abs=0.5)
        early = client.get(f"/api/games/{game_id}/analysis").json()
        assert early["box_scores"] and db.get_job(job_id).status == JobStatus.RUNNING

        _send_part(client, game_id, 1)
        _send_part(client, game_id, 2)
        later = _wait(lambda: (g := db.get_game(game_id)).live.segments_analysed == 3 and g, message="all three parts")
        assert later.live.analysed_s == pytest.approx(180, abs=1) and later.live.analysis_version >= 2
        grown = client.get(f"/api/games/{game_id}/analysis").json()
        assert len(grown["timeline"]) > len(early["timeline"])
        assert "3 of 3 parts analysed, stats through 3:00" in db.get_job(job_id).message

        assert client.post(f"/api/games/{game_id}/live/finish").status_code == 200
        thread.join(timeout=20)
        assert not thread.is_alive()
    finally:
        worker.stop()
        thread.join(timeout=5)

    job = db.get_job(job_id)
    assert job.status == JobStatus.SUCCEEDED and job.message == "Live game analysed" and job.warnings == []
    game = db.get_game(game_id)
    assert game.status == GameStatus.READY and game.has_video and game.has_tracking and game.has_analysis
    assert game.live.state == LiveState.ENDED and game.live.end_reason == LiveEndReason.FINISHED and game.live.ended_at
    assert joined == [0, 1, 2] and game.video_size == 3 * 4096
    assert not storage.live_dir(game_id).exists()  # the film and the tracking file hold it all now
    statuses = [s.status for s in db.list_live_segments(game_id)]
    assert statuses == [LiveSegmentStatus.DONE] * 3

    from scout.analysis import pipeline

    tracking = pipeline.load_tracking(storage.tracking_path(game_id))
    assert is_live_tracking(tracking) and tracking.video.duration_s == pytest.approx(180, abs=1)
    # It is a normal game now: a roster fix re-runs the analysis from the joined tracking.
    r = client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"})
    assert r.status_code == 201, r.text
    assert worker.run_once(timeout=2) and db.get_job(r.json()["id"]).status == JobStatus.SUCCEEDED
    assert client.post(f"/api/games/{game_id}/live").status_code == 409  # not live again


def _run_to_the_end(client, game_id: str, parts: int, worker=None, **kwargs):
    client.post(f"/api/games/{game_id}/live", json={"segment_seconds": 60})
    for index in range(parts):
        assert _send_part(client, game_id, index, **kwargs).status_code == 200
    client.post(f"/api/games/{game_id}/live/finish")
    worker = worker or _worker()
    assert worker.run_once(timeout=2)
    return db.get_job(db.get_game(game_id).latest_job_id)


def test_demo_parts_share_the_game_s_players(client):
    game_id = _new_game(client)
    job = _run_to_the_end(client, game_id, 3)
    assert job.status == JobStatus.SUCCEEDED, job.error
    rosters = db.get_rosters(game_id)
    assert all(r.players for r in rosters.values())  # demo rosters, saved once
    analysis = client.get(f"/api/games/{game_id}/analysis").json()
    assignments = analysis["track_assignments"]
    blocks = {a["track_id"] // TRACK_ID_BLOCK for a in assignments if a.get("player_id")}
    assert blocks == {0, 1, 2}, "tracks of every part are matched to the roster"


def test_without_ffmpeg_the_parts_stay_and_the_job_says_so(client, monkeypatch):
    monkeypatch.setattr(live.shutil, "which", lambda name: None)
    game_id = _new_game(client)
    job = _run_to_the_end(client, game_id, 2)
    assert job.status == JobStatus.SUCCEEDED
    assert any("could not be put together" in w for w in job.warnings)
    game = db.get_game(game_id)
    assert not game.has_video and game.has_tracking and game.status == GameStatus.READY
    assert storage.live_segment_video_path(game_id, 1).is_file()


def test_a_live_game_without_film_ends_empty(client):
    game_id = _new_game(client)
    job = _run_to_the_end(client, game_id, 0)
    assert job.status == JobStatus.SUCCEEDED and job.warnings == ["The live game ended before any film arrived."]
    game = db.get_game(game_id)
    assert game.status == GameStatus.DRAFT and game.live.end_reason == LiveEndReason.EMPTY and not game.has_analysis


def test_the_game_ends_by_itself_when_no_film_arrives(client, monkeypatch):
    monkeypatch.setenv("SCOUT_LIVE_IDLE_MINUTES", "0.0005")  # 30 ms
    config.reset_settings()
    game_id = _new_game(client)
    client.post(f"/api/games/{game_id}/live")
    _send_part(client, game_id, 0)
    time.sleep(0.05)
    worker = _worker()
    assert worker.run_once(timeout=2)
    game = db.get_game(game_id)
    assert game.live.state == LiveState.ENDED and game.live.end_reason == LiveEndReason.IDLE
    assert game.status == GameStatus.READY and game.live.segments_analysed == 1


class _FailingParts:
    """Wraps the mock processor: the GPU call of the listed parts fails."""

    def __init__(self, inner, failing: dict[int, ErrorCode]):
        self.inner, self.failing, self.name = inner, failing, inner.name
        self.poll_interval = 0.02
        self.should_stop = None
        self.submitted: list[str] = []
        self.cancelled: list[str] = []

    def check_ready(self):
        pass

    def submit(self, *, job_id, video, options):
        self.submitted.append(job_id)
        return self.inner.submit(job_id=job_id, video=video, options=options)

    def poll(self, handle):
        index = int(handle.rsplit("-p", 1)[1])
        if index in self.failing:
            return PollResult(state="failed", error=ScoutError(self.failing[index]))
        return self.inner.poll(handle)

    def fetch(self, handle, result, dest_dir):
        return self.inner.fetch(handle, result, dest_dir)

    def cancel(self, handle):
        self.cancelled.append(handle)

    def cleanup(self, handle, result):
        pass


def test_a_part_the_gpu_cannot_analyse_leaves_a_gap_not_a_failed_game(client, monkeypatch):
    monkeypatch.setattr(live, "join_film", lambda game_id, segments: None)
    game_id = _new_game(client)
    worker = _worker()
    processor = _FailingParts(worker.processor, {1: ErrorCode.VIDEO_DECODE_FAILED})
    worker.processor = processor
    job = _run_to_the_end(client, game_id, 3, worker=worker)
    assert job.status == JobStatus.SUCCEEDED, job.error
    assert any(w.startswith("Part 2 of the film could not be analysed") for w in job.warnings)
    segments = db.list_live_segments(game_id)
    assert [s.status for s in segments] == [LiveSegmentStatus.DONE, LiveSegmentStatus.FAILED, LiveSegmentStatus.DONE]
    assert segments[1].error.code == "VIDEO_DECODE_FAILED"
    assert sum(1 for j in processor.submitted if j.endswith("-p00001")) == 1  # not retryable: sent once
    game = db.get_game(game_id)
    assert game.live.segments_analysed == 2 and game.live.segments_failed == 1
    assert game.live.analysed_s == pytest.approx(180, abs=1)
    analysis = client.get(f"/api/games/{game_id}/analysis").json()
    assert any(w["code"] == PARTS_MISSING_CODE for w in analysis["data_quality"]["warnings"])


def test_a_part_without_play_is_not_a_failure(client, monkeypatch):
    """Halftime, a timeout, warm-ups: the GPU answers "too few players" or "no ball" for such film."""
    monkeypatch.setattr(live, "join_film", lambda game_id, segments: None)
    game_id = _new_game(client)
    worker = _worker()
    processor = _FailingParts(worker.processor, {0: ErrorCode.DETECTION_FAILED, 2: ErrorCode.BALL_NOT_DETECTED})
    worker.processor = processor
    job = _run_to_the_end(client, game_id, 4, worker=worker)
    assert job.status == JobStatus.SUCCEEDED, job.error
    assert not [w for w in job.warnings if "could not be analysed" in w]
    segments = db.list_live_segments(game_id)
    empty, done = LiveSegmentStatus.EMPTY, LiveSegmentStatus.DONE
    assert [s.status for s in segments] == [empty, done, empty, done]
    assert len(processor.submitted) == 4  # no second try for a break
    info = db.get_game(game_id).live
    assert (info.segments_analysed, info.segments_empty, info.segments_failed) == (2, 2, 0)
    assert info.analysed_s == pytest.approx(240, abs=1)
    analysis = client.get(f"/api/games/{game_id}/analysis").json()
    codes = {w["code"] for w in analysis["data_quality"]["warnings"]}
    assert "LIVE_NO_PLAY" in codes and PARTS_MISSING_CODE not in codes


def test_warm_ups_before_the_game_show_as_parts_without_play(client, monkeypatch):
    monkeypatch.setattr(live, "join_film", lambda game_id, segments: None)
    game_id = _new_game(client)
    job_id = client.post(f"/api/games/{game_id}/live").json()["job"]["id"]
    worker = _worker()
    worker.processor = _FailingParts(worker.processor, {0: ErrorCode.DETECTION_FAILED, 1: ErrorCode.DETECTION_FAILED})
    thread = threading.Thread(target=worker.run_once, kwargs={"timeout": 2}, daemon=True)
    thread.start()
    try:
        _send_part(client, game_id, 0)
        _send_part(client, game_id, 1)
        info = _wait(lambda: (g := db.get_game(game_id)).live.segments_empty == 2 and g.live, message="two parts without play")
        assert info.segments_analysed == 0 and info.analysis_version == 0 and not db.get_game(game_id).has_analysis
        _send_part(client, game_id, 2)  # tip-off
        _wait(lambda: db.get_game(game_id).live.segments_analysed == 1, message="the first stats")
        assert db.get_game(game_id).live.analysed_s == pytest.approx(180, abs=1)
        client.post(f"/api/games/{game_id}/live/finish")
        thread.join(timeout=20)
    finally:
        worker.stop()
        thread.join(timeout=5)
    assert db.get_job(job_id).status == JobStatus.SUCCEEDED


def test_a_failed_rebuild_of_the_stats_does_not_stop_the_recording(client, monkeypatch):
    """The film must keep being taken whatever happens to the stats: the game stays live, the job says so,
    and the next part is the next try."""
    from scout.analysis import pipeline

    monkeypatch.setattr(live, "join_film", lambda game_id, segments: None)
    real = pipeline.analyze_game
    calls = {"n": 0}

    def flaky(tracking, game, rosters, overrides=None, **kwargs):
        calls["n"] += 1
        if calls["n"] == 2:
            raise ScoutError(ErrorCode.ANALYSIS_FAILED, detail="boom")
        return real(tracking, game, rosters, overrides, **kwargs)

    monkeypatch.setattr(pipeline, "analyze_game", flaky)
    game_id = _new_game(client)
    job_id = client.post(f"/api/games/{game_id}/live").json()["job"]["id"]
    worker = _worker()
    thread = threading.Thread(target=worker.run_once, kwargs={"timeout": 2}, daemon=True)
    thread.start()
    try:
        _send_part(client, game_id, 0)
        _wait(lambda: db.get_game(game_id).live.analysis_version == 1, message="the first stats")
        _send_part(client, game_id, 1)  # this rebuild fails
        _wait(lambda: db.get_job(job_id).warnings, message="the warning")
        game = db.get_game(game_id)
        assert game.live.state == LiveState.CAPTURING and game.status == GameStatus.READY
        assert game.live.analysis_version == 1 and db.get_job(job_id).status == JobStatus.RUNNING
        assert "still being recorded" in db.get_job(job_id).warnings[0]
        assert game.live.analysed_s == pytest.approx(60, abs=1)  # the stats it had
        assert _send_part(client, game_id, 2).status_code == 200  # still taking film
        caught_up = _wait(lambda: (g := db.get_game(game_id)).live.analysis_version == 2 and g, message="the stats to catch up")
        assert caught_up.live.analysed_s == pytest.approx(180, abs=1)
        client.post(f"/api/games/{game_id}/live/finish")
        thread.join(timeout=20)
    finally:
        worker.stop()
        thread.join(timeout=5)
    assert db.get_job(job_id).status == JobStatus.SUCCEEDED


def test_a_game_whose_last_rebuild_failed_ends_failed_with_its_film_and_tracking(client, monkeypatch):
    from scout.analysis import pipeline

    monkeypatch.setattr(live, "join_film", lambda game_id, segments: None)

    def broken(*args, **kwargs):
        raise ScoutError(ErrorCode.CONFIG_INVALID, "play_rules.yaml cannot be used.")

    monkeypatch.setattr(pipeline, "analyze_game", broken)
    game_id = _new_game(client)
    job = _run_to_the_end(client, game_id, 2)
    assert job.status == JobStatus.FAILED and job.error.code == "CONFIG_INVALID"
    game = db.get_game(game_id)
    assert game.status == GameStatus.FAILED and game.live.state == LiveState.ENDED
    assert game.has_tracking and not game.has_analysis  # once the cause is fixed, Re-run analysis builds the stats
    monkeypatch.undo()


def test_a_retryable_failure_sends_the_part_once_more(client, monkeypatch):
    monkeypatch.setattr(live, "join_film", lambda game_id, segments: None)
    game_id = _new_game(client)
    worker = _worker()
    processor = _FailingParts(worker.processor, {0: ErrorCode.MODAL_REMOTE_ERROR})
    worker.processor = processor
    job = _run_to_the_end(client, game_id, 1, worker=worker)
    assert sum(1 for j in processor.submitted if j.endswith("-p00000")) == 2
    # No part could be analysed: the job fails with the part's error, and the game keeps its film parts.
    assert job.status == JobStatus.FAILED and job.error.code == "MODAL_REMOTE_ERROR"
    game = db.get_game(game_id)
    assert game.status == GameStatus.FAILED and game.live.state == LiveState.ENDED
    assert game.live.end_reason == LiveEndReason.FAILED


def test_cancel_stops_the_gpu_calls_and_keeps_what_was_analysed(client, monkeypatch):
    monkeypatch.setenv("SCOUT_MOCK_SECONDS", "30")  # parts stay on the "GPU"
    config.reset_settings()
    monkeypatch.setattr(live, "join_film", lambda game_id, segments: None)
    game_id = _new_game(client)
    job_id = client.post(f"/api/games/{game_id}/live").json()["job"]["id"]
    _send_part(client, game_id, 0)
    worker = _worker()
    processor = _FailingParts(worker.processor, {})
    worker.processor = processor
    thread = threading.Thread(target=worker.run_once, kwargs={"timeout": 2}, daemon=True)
    thread.start()
    try:
        _wait(lambda: db.get_live_segment(game_id, 0).status == LiveSegmentStatus.PROCESSING, message="part 0 on the GPU")
        assert client.post(f"/api/jobs/{job_id}/cancel").json()["cancel_requested"] is True
        thread.join(timeout=20)
        assert not thread.is_alive()
    finally:
        worker.stop()
        thread.join(timeout=5)
    assert db.get_job(job_id).status == JobStatus.CANCELLED
    assert processor.cancelled == [f"mock:{job_id}-p00000"]
    game = db.get_game(game_id)
    assert game.live.state == LiveState.ENDED and game.live.end_reason == LiveEndReason.CANCELLED
    assert game.status == GameStatus.DRAFT  # nothing analysed, the film not joined
    assert db.get_live_segment(game_id, 0).status == LiveSegmentStatus.UPLOADED
    late = client.post(f"/api/games/{game_id}/live/segments", json={"index": 1, "duration_s": 60, "size": 4096})
    assert late.status_code == 409 and late.json()["error"]["code"] == "LIVE_ENDED"

    # Start again: a new LIVE job finishes the parts that are on the server.
    monkeypatch.setenv("SCOUT_MOCK_SECONDS", "0")
    config.reset_settings()
    retry = client.post(f"/api/jobs/{job_id}/retry")
    assert retry.status_code == 200, retry.text
    assert retry.json()["kind"] == "live" and db.get_game(game_id).live.state == LiveState.FINISHING
    assert _worker().run_once(timeout=2)
    assert db.get_job(retry.json()["id"]).status == JobStatus.SUCCEEDED
    game = db.get_game(game_id)
    assert game.status == GameStatus.READY and game.live.state == LiveState.ENDED and game.live.segments_analysed == 1


def test_a_restarted_worker_resumes_the_parts_calls(client, monkeypatch):
    monkeypatch.setattr(live, "join_film", lambda game_id, segments: None)
    game_id = _new_game(client)
    job_id = client.post(f"/api/games/{game_id}/live").json()["job"]["id"]
    _send_part(client, game_id, 0)
    _send_part(client, game_id, 1)
    # A worker that sent both parts to the GPU and then died.
    job = db.claim_job("dead-worker", lease_seconds=-1)
    assert job.id == job_id
    for index in (0, 1):
        segment = db.get_live_segment(game_id, index)
        db.save_live_segment(
            segment.model_copy(
                update={"status": LiveSegmentStatus.PROCESSING, "external_id": f"mock:{job_id}-p{index:05d}", "processor": "mock", "attempts": 1}
            )
        )
    client.post(f"/api/games/{game_id}/live/finish")
    worker = _worker()
    processor = _FailingParts(worker.processor, {})
    worker.processor = processor
    assert worker.run_once(timeout=2)
    assert processor.submitted == []  # resumed, not paid for twice
    assert db.get_job(job_id).status == JobStatus.SUCCEEDED
    assert db.get_game(game_id).live.segments_analysed == 2


def test_an_uploaded_film_makes_it_a_normal_game_again(client, monkeypatch):
    monkeypatch.setattr(live, "join_film", lambda game_id, segments: None)
    game_id = _new_game(client)
    _run_to_the_end(client, game_id, 2)
    assert db.get_game(game_id).live is not None and storage.live_dir(game_id).exists()
    data = _fake_mp4()
    upload = client.post(f"/api/games/{game_id}/uploads", json={"filename": "full.mp4", "size": len(data)}).json()
    client.put(f"/api/uploads/{upload['id']}/chunk", params={"offset": 0}, content=data)
    r = client.post(f"/api/uploads/{upload['id']}/complete", params={"auto_start": "false"})
    assert r.status_code == 200, r.text
    game = db.get_game(game_id)
    assert game.live is None and game.has_video and not game.has_analysis
    assert not storage.live_dir(game_id).exists() and db.list_live_segments(game_id) == []


def test_deleting_a_live_game_removes_its_parts(client):
    game_id = _new_game(client)
    client.post(f"/api/games/{game_id}/live")
    _send_part(client, game_id, 0)
    assert client.delete(f"/api/games/{game_id}").status_code == 204
    assert not storage.game_dir(game_id).exists() and db.list_live_segments(game_id) == []


_STAND_IN_FFMPEG = """#!/bin/sh
# Stands in for ffmpeg's concat: joins the files named in the list (-i) into the last argument.
[ -n "$FAIL" ] && { echo "stand-in: asked to fail" >&2; exit 1; }
out=""; list=""; prev=""
for arg in "$@"; do
  [ "$prev" = "-i" ] && list="$arg"
  prev="$arg"; out="$arg"
done
: > "$out"
sed -e "s/^file '//" -e "s/'$//" "$list" | while read -r name; do cat "$name" >> "$out"; done
printf '%s\n' "$@" > "$(dirname "$out")/../ffmpeg-args.txt"
"""


def test_join_film_puts_the_parts_together_in_stream_order(game, monkeypatch, tmp_path):
    ffmpeg = tmp_path / "ffmpeg"
    ffmpeg.write_text(_STAND_IN_FFMPEG)
    ffmpeg.chmod(0o755)
    monkeypatch.setattr(live.shutil, "which", lambda name: str(ffmpeg) if name == "ffmpeg" else None)
    storage.live_dir(game.id, create=True)
    segments = []
    for index in (2, 0, 1, 4):  # part 3 never arrived; part 4's file is gone
        segments.append(LiveSegment(game_id=game.id, index=index, duration_s=60, size=10))
        if index != 4:
            storage.live_segment_video_path(game.id, index).write_bytes(f"<part {index}>".encode())

    film = live.join_film(game.id, segments)

    assert film == storage.source_video_path(game.id) and film.read_bytes() == b"<part 0><part 1><part 2>"
    args = (storage.game_dir(game.id) / "ffmpeg-args.txt").read_text().split("\n")
    assert args[args.index("-f") + 1] == "concat" and args[args.index("-c") + 1] == "copy"  # no re-encoding
    assert "-nostdin" in args and "+faststart" in args
    assert not (storage.live_dir(game.id) / "parts.txt").exists()
    assert not (storage.live_dir(game.id) / "film.partial.mp4").exists()
    assert storage.live_segment_video_path(game.id, 0).is_file()  # the caller removes the parts, once the game knows its film


def test_join_film_that_fails_leaves_the_parts_and_no_half_film(game, monkeypatch, tmp_path):
    ffmpeg = tmp_path / "ffmpeg"
    ffmpeg.write_text(_STAND_IN_FFMPEG)
    ffmpeg.chmod(0o755)
    monkeypatch.setattr(live.shutil, "which", lambda name: str(ffmpeg))
    monkeypatch.setenv("FAIL", "1")
    storage.live_dir(game.id, create=True)
    storage.live_segment_video_path(game.id, 0).write_bytes(b"<part 0>")
    segment = LiveSegment(game_id=game.id, index=0, duration_s=60, size=8)
    assert live.join_film(game.id, [segment]) is None
    assert storage.find_source_video(game.id) is None
    assert storage.live_segment_video_path(game.id, 0).read_bytes() == b"<part 0>"
    assert sorted(p.name for p in storage.live_dir(game.id).iterdir()) == ["seg-00000.mp4"]


def test_the_game_ends_with_its_film_when_ffmpeg_is_there(client, monkeypatch, tmp_path):
    ffmpeg = tmp_path / "ffmpeg"
    ffmpeg.write_text(_STAND_IN_FFMPEG)
    ffmpeg.chmod(0o755)
    monkeypatch.setattr(live.shutil, "which", lambda name: str(ffmpeg) if name == "ffmpeg" else None)
    game_id = _new_game(client)
    job = _run_to_the_end(client, game_id, 3)
    assert job.status == JobStatus.SUCCEEDED and job.warnings == []
    game = db.get_game(game_id)
    assert game.has_video and game.video_size == 3 * 4096
    assert game.video_filename == f"live-{game.live.started_at.date().isoformat()}.mp4"
    assert storage.source_video_path(game_id).read_bytes() == _fake_mp4() * 3
    assert not storage.live_dir(game_id).exists()
    r = client.get(f"/api/games/{game_id}/video")
    assert r.status_code == 200 and len(r.content) == 3 * 4096


def test_join_film_needs_ffmpeg_and_parts(game, monkeypatch):
    segment = LiveSegment(game_id=game.id, index=0, duration_s=60, size=10)
    assert live.join_film(game.id, [segment]) is None  # no part on disk
    storage.live_dir(game.id, create=True)
    storage.live_segment_video_path(game.id, 0).write_bytes(_fake_mp4())
    monkeypatch.setattr(live.shutil, "which", lambda name: None)
    assert live.join_film(game.id, [segment]) is None
    assert storage.live_segment_video_path(game.id, 0).is_file()
