"""Game time: only the marked stretches of the film count, and only they go to the GPU."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from scout import config, db, storage
from scout.analysis import game_time, pipeline, synthetic
from scout.analysis.game_time import GAME_TIME_CODE, CutFilm, Piece, clip_tracking, restore_film_times
from scout.errors import ScoutError
from scout.schemas import JobStatus, RawEventType, TimeRange


def _ranges(*pairs):
    return [TimeRange(start_s=a, end_s=b) for a, b in pairs]


@pytest.fixture
def film():
    tracking, _ = synthetic.generate_synthetic_game(seed=5, duration_s=600)
    return tracking


def test_marks_must_run_forwards_and_not_overlap():
    assert [r.start_s for r in game_time.check_ranges(_ranges((300, 500), (10, 200)))] == [10, 300]
    for bad in (_ranges((100, 100)), _ranges((200, 100)), _ranges((0, 300), (250, 400))):
        with pytest.raises(ScoutError):
            game_time.check_ranges(bad)
    assert game_time.describe(_ranges((65, 3700))) == "1:05-1:01:40"


def test_only_marked_time_is_kept(film):
    fps = film.video.fps
    clipped = clip_tracking(film, _ranges((120, 280), (340, 540)))
    frames = [s.f for t in clipped.tracks for s in t.samples]
    assert frames and all(120 * fps <= f <= 280 * fps or 340 * fps <= f <= 540 * fps for f in frames)
    assert all(120 <= e.t <= 280.1 or 340 <= e.t <= 540.1 for e in clipped.events)
    assert all(120 * fps <= r.frame <= 540 * fps for t in clipped.tracks for r in t.jersey_reads)
    assert len(clipped.events) < len(film.events) and len(clipped.ball) < len(film.ball)
    assert clipped.video.duration_s == film.video.duration_s  # the film is the same film
    starts = [e for e in clipped.events if e.type == RawEventType.PERIOD_START]
    assert starts and starts[0].t >= 120  # the game starts at the mark, not with the warm-ups
    assert any(w.code == GAME_TIME_CODE and "2:00-4:40, 5:40-9:00" in w.message for w in clipped.warnings)
    assert clip_tracking(film, []) is film


def test_the_stats_count_only_game_time(film, game):
    rosters = synthetic.synthetic_rosters(game.id, seed=5)
    whole = pipeline.analyze_game(film, game, rosters, [])
    marked = pipeline.analyze_game(film, game.model_copy(update={"play_ranges": _ranges((200, 500))}), rosters, [])
    assert all(200 <= e.t <= 500.5 for e in marked.timeline)
    assert sum(b.totals.fga for b in marked.box_scores) < sum(b.totals.fga for b in whole.box_scores)
    minutes = lambda a: sum(line.minutes_est or 0 for b in a.box_scores for line in b.players)  # noqa: E731
    assert minutes(marked) < minutes(whole)
    assert any(w.code == GAME_TIME_CODE for w in marked.data_quality.warnings)


def test_results_of_a_cut_film_go_back_on_the_whole_film_s_clock():
    cut, _ = synthetic.generate_synthetic_game(seed=6, duration_s=300)  # what the GPU saw: 100 s + 200 s
    fps = cut.video.fps
    pieces = [Piece(start_s=600.0, duration_s=100.0), Piece(start_s=1500.0, duration_s=200.0)]
    restored = restore_film_times(cut, pieces, film_duration_s=2400.0)
    assert restored.video.duration_s == 2400.0 and restored.video.frame_count == round(2400 * fps)
    for before, after in zip(cut.events, restored.events, strict=True):
        expected = 600 + before.t if before.t < 100 else 1500 + (before.t - 100)
        assert after.t == pytest.approx(expected, abs=0.05) and after.frame == round(after.t * fps)
    frames = [s.f / fps for t in restored.tracks for s in t.samples]
    assert min(frames) >= 600 and max(frames) <= 1700.1
    assert not [f for f in frames if 700.1 < f < 1499.9]  # nothing in the break that was cut out
    assert len(restored.ball) == len(cut.ball)


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


def _game_with_film(client) -> str:
    game_id = client.post("/api/games", json={"scouted_team": "Central", "other_team": "North", "scouted_color": "dark"}).json()["id"]
    data = _fake_mp4()
    upload = client.post(f"/api/games/{game_id}/uploads", json={"filename": "game.mp4", "size": len(data)}).json()
    client.put(f"/api/uploads/{upload['id']}/chunk", params={"offset": 0}, content=data)
    assert client.post(f"/api/uploads/{upload['id']}/complete", params={"auto_start": "false"}).status_code == 200
    return game_id


def test_the_marks_are_saved_checked_and_cleared(client):
    game_id = _game_with_film(client)
    marks = [{"start_s": 900, "end_s": 1500}, {"start_s": 60, "end_s": 700}]
    r = client.patch(f"/api/games/{game_id}", json={"play_ranges": marks})
    assert r.status_code == 200, r.text
    assert [m["start_s"] for m in r.json()["play_ranges"]] == [60, 900]  # in film order
    bad = client.patch(f"/api/games/{game_id}", json={"play_ranges": [{"start_s": 0, "end_s": 800}, {"start_s": 700, "end_s": 900}]})
    assert bad.status_code == 422 and "overlap" in bad.json()["error"]["message"]
    assert len(db.get_game(game_id).play_ranges) == 2
    assert client.patch(f"/api/games/{game_id}", json={"play_ranges": None}).json()["play_ranges"] == []
    assert client.get(f"/api/games/{game_id}").json()["play_ranges"] == []


def test_only_the_marked_film_goes_to_the_gpu_and_times_stay_the_films(client, monkeypatch):
    from scout.worker import Worker

    game_id = _game_with_film(client)
    client.patch(f"/api/games/{game_id}", json={"play_ranges": [{"start_s": 1000, "end_s": 1120}, {"start_s": 2000, "end_s": 2180}]})
    seen = {}

    def fake_cut(source, ranges, work_dir):
        work_dir.mkdir(parents=True, exist_ok=True)
        path = work_dir / "game-time.mp4"
        path.write_bytes(_fake_mp4())
        seen["ranges"] = [(r.start_s, r.end_s) for r in ranges]
        return CutFilm(path=path, pieces=[Piece(1000.0, 120.0), Piece(2000.0, 180.0)], film_duration_s=3000.0)

    monkeypatch.setattr(game_time, "cut_film", fake_cut)
    worker = Worker(worker_id="test-worker")
    submitted = {}
    real_submit = worker.processor.submit

    def submit(*, job_id, video, options):
        submitted.update(path=video.path, render=options["render_video"])
        options = {**options, "mock_duration_s": 300.0}  # the cut film is 300 s long
        return real_submit(job_id=job_id, video=video, options=options)

    monkeypatch.setattr(worker.processor, "submit", submit)
    job = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    assert worker.run_once(timeout=2)
    assert db.get_job(job["id"]).status == JobStatus.SUCCEEDED, db.get_job(job["id"]).error

    assert seen["ranges"] == [(1000, 1120), (2000, 2180)]
    assert submitted["path"].name == "game-time.mp4" and submitted["render"] is False
    assert not storage.game_time_dir(game_id).exists()  # cleaned up once the results were in
    tracking = pipeline.load_tracking(storage.tracking_path(game_id))
    assert tracking.video.duration_s == 3000.0
    times = [e.t for e in tracking.events]
    assert min(times) >= 1000 and max(times) <= 2180.5 and not [t for t in times if 1120.5 < t < 1999.5]
    analysis = client.get(f"/api/games/{game_id}/analysis").json()
    assert analysis["timeline"] and all(1000 <= e["t"] <= 1120.5 or 2000 <= e["t"] <= 2180.5 for e in analysis["timeline"])


def test_without_ffmpeg_the_whole_film_is_analysed_and_the_stats_are_still_game_time_only(client, monkeypatch):
    from scout.worker import Worker

    monkeypatch.setattr(game_time.shutil, "which", lambda name: None)
    game_id = _game_with_film(client)
    client.patch(f"/api/games/{game_id}", json={"play_ranges": [{"start_s": 100, "end_s": 400}]})
    job = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    assert Worker(worker_id="test-worker").run_once(timeout=2)
    assert db.get_job(job["id"]).status == JobStatus.SUCCEEDED
    analysis = client.get(f"/api/games/{game_id}/analysis").json()
    assert analysis["timeline"] and all(100 <= e["t"] <= 400.5 for e in analysis["timeline"])
    # Marks changed afterwards: Re-run analysis is enough, no GPU.
    client.patch(f"/api/games/{game_id}", json={"play_ranges": [{"start_s": 100, "end_s": 250}]})
    again = client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"}).json()
    assert Worker(worker_id="test-worker").run_once(timeout=2)
    assert db.get_job(again["id"]).status == JobStatus.SUCCEEDED
    assert all(e["t"] <= 250.5 for e in client.get(f"/api/games/{game_id}/analysis").json()["timeline"])
