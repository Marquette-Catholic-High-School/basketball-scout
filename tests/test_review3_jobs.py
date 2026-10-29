"""Third review round, jobs area: a Full re-analysis clears the earlier run's track overrides and
sets the overlay flag as soon as it installs its results; a job resumed past the wait limit rides
out a Modal outage instead of failing on its first poll."""

from __future__ import annotations

import gzip
import time
from datetime import timedelta
from types import SimpleNamespace
from typing import Any

import pytest

from scout import db, storage
from scout.analysis import synthetic
from scout.errors import ErrorCode, ScoutError
from scout.jobs.queue import submit_job
from scout.processing import modal_client
from scout.processing.base import poll_result_from_response
from scout.processing.mock import MockProcessor
from scout.schemas import CourtCalibration, Game, GameStatus, Job, JobKind, JobStage, JobStatus, TeamSide, TrackOverride
from tests import helpers
from tests.test_processing_modal import EXC, HANDLE, fake_modal, processor  # noqa: F401 - fixtures
from tests.test_worker import (  # noqa: F401 - fixtures
    FakeProcessor,
    env,
    fakes,
    filmed_game,
    make_analysis,
    make_worker,
    queue,
    tiny_synthetic_game,
)

OLD_FIX = TrackOverride(track_id=7, ignore=True)  # "track 7 is the other team's coach", saved for the first run


def _analysed(game: Game, *, overlay: bool = True) -> Game:
    """A game an earlier ANALYZE finished: tracking, overlay, analysis.json and a coach's track fix."""
    storage.write_json(storage.tracking_path(game.id), helpers.tracking([]).model_dump_json())
    if overlay:
        storage.annotated_video_path(game.id).write_bytes(b"first run's overlay")
    storage.write_text_atomic(storage.analysis_path(game.id), make_analysis(game.id).model_dump_json())
    db.set_track_override(game.id, OLD_FIX)
    return db.update_game(game.id, status=GameStatus.READY, has_analysis=True, has_annotated_video=overlay)


def _resumed(game_id: str, queue, stage: JobStage, *, processor: str = "fake", hours: float = 0.5) -> Job:  # noqa: F811
    """An ANALYZE job whose worker died at ``stage``, ``hours`` after the job started. Its lease
    has run out, so the next claim resumes polling its GPU call (a FakeProcessor or Modal one)."""
    job = submit_job(game_id, JobKind.ANALYZE, queue=queue)
    assert db.claim_job("w-dead", 60, job_id=job.id) is not None
    return db.update_job(
        job.id,
        external_id=f"fake:{job.id}" if processor == "fake" else f"fc-01ABC|{job.id}",
        processor=processor,
        stage=stage,
        started_at=db.utcnow() - timedelta(hours=hours),
        lease_expires_at=time.time() - 1,
    )


# --- Full re-analysis: the earlier run's track overrides go -----------------------------------


def test_a_full_reanalysis_clears_the_earlier_runs_track_overrides(filmed_game, queue, fakes):  # noqa: F811
    """The new GPU run numbers its tracks anew: the coach's fix for the first run's track 7 was
    applied by id to whoever is track 7 now (another player, maybe one of the scouted team's)."""
    calibration = CourtCalibration(
        points=[], matrix=helpers.IDENTITY, reprojection_error_ft=0.4, video_width=1920, video_height=1080
    )
    team_map = {0: TeamSide.OTHER, 1: TeamSide.SCOUTED}
    game = _analysed(filmed_game)
    db.update_game(game.id, team_id_map=team_map, calibration=calibration)
    job = submit_job(game.id, JobKind.ANALYZE, queue=queue)
    gpu = FakeProcessor(annotated=True)
    make_worker(gpu, queue).run_once(timeout=1)

    assert db.get_job(job.id).status == JobStatus.SUCCEEDED
    assert gpu.submitted[0]["options"]["calibration"]["matrix"] == helpers.IDENTITY  # the GPU gets it again
    assert fakes.analyze[0]["overrides"] == []  # the new analysis does not apply the old fix
    assert db.list_track_overrides(game.id) == []
    stored = db.get_game(game.id)
    assert (stored.team_id_map, stored.calibration) == (team_map, calibration)  # both stay
    assert (stored.status, stored.has_analysis, stored.has_annotated_video) == (GameStatus.READY, True, True)


def test_a_full_reanalysis_in_demo_mode_clears_them_too(filmed_game, queue, fakes, monkeypatch):  # noqa: F811
    """Demo mode takes the same path: the worker installs the mock processor's synthetic tracking over
    the earlier run's file in the game folder, as it does the Modal and local processors' results."""
    settings = env(monkeypatch, SCOUT_MOCK_SECONDS="0")
    monkeypatch.setattr(synthetic, "generate_synthetic_game", tiny_synthetic_game)
    monkeypatch.setattr(synthetic, "synthetic_rosters", lambda game_id, seed=7: {})
    _analysed(filmed_game)
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    make_worker(MockProcessor(settings), queue, settings).run_once(timeout=1)

    assert db.get_job(job.id).status == JobStatus.SUCCEEDED
    assert fakes.analyze[0]["overrides"] == [] and db.list_track_overrides(filmed_game.id) == []


@pytest.mark.parametrize("stage", [JobStage.GPU_PROCESSING, JobStage.DOWNLOADING])
def test_a_resumed_full_reanalysis_clears_them_once_it_installs(filmed_game, queue, fakes, stage):  # noqa: F811
    """Its worker died before it installed the new run (maybe in the middle of the download): nothing
    has cleared the first run's fixes yet."""
    _analysed(filmed_game)
    job = _resumed(filmed_game.id, queue, stage)
    gpu = FakeProcessor()
    make_worker(gpu, queue).run_once(timeout=1)

    assert db.get_job(job.id).status == JobStatus.SUCCEEDED
    assert gpu.submitted == [] and gpu.fetched == [f"fake:{job.id}"]
    assert fakes.analyze[0]["overrides"] == [] and db.list_track_overrides(filmed_game.id) == []


@pytest.mark.parametrize("stage", [JobStage.ANALYZING, JobStage.REPORTING])
def test_installing_the_same_run_again_keeps_the_fixes_made_for_it(filmed_game, queue, fakes, stage):  # noqa: F811
    """Its worker died after installing this run and clearing the old fixes (killed while Claude
    wrote the report, say). The coach then fixed a track of the NEW run; the next worker fetches
    and installs the same run again, and must not throw that fix away."""
    _analysed(filmed_game)  # the tracking on disk is this run's by now
    db.clear_track_overrides(filmed_game.id)
    new_fix = db.set_track_override(filmed_game.id, TrackOverride(track_id=3, side=TeamSide.OTHER))
    job = _resumed(filmed_game.id, queue, stage)
    gpu = FakeProcessor()
    make_worker(gpu, queue).run_once(timeout=1)

    assert db.get_job(job.id).status == JobStatus.SUCCEEDED
    assert gpu.fetched == [f"fake:{job.id}"]  # installed again
    assert fakes.analyze[0]["overrides"] == [new_fix] and db.list_track_overrides(filmed_game.id) == [new_fix]


def test_a_reanalysis_keeps_the_track_overrides(filmed_game, queue, fakes):  # noqa: F811
    """Re-run analysis redoes the stats from the stored tracking: the track numbers stay the same."""
    _analysed(filmed_game)
    job = submit_job(filmed_game.id, JobKind.REANALYZE, queue=queue)
    make_worker(FakeProcessor(), queue).run_once(timeout=1)

    assert db.get_job(job.id).status == JobStatus.SUCCEEDED
    assert fakes.analyze[0]["overrides"] == [OLD_FIX] and db.list_track_overrides(filmed_game.id) == [OLD_FIX]


# --- the overlay flag is set when the results are installed -------------------------------------


@pytest.mark.parametrize(("overlay_before", "new_overlay"), [(True, False), (False, True)])
@pytest.mark.parametrize("ending", ["analysis fails", "cancelled during the download"])
def test_the_overlay_flag_follows_the_installed_files_at_once(
    filmed_game, queue, fakes, overlay_before, new_overlay, ending  # noqa: F811
):
    """The flag was only written with a saved analysis. A job that ended after installing a new run
    left it true with the old overlay deleted (the Annotated player broke) or false with a new one.
    (Since round 4 a cancel during the download ends the job before the install: the earlier run's
    overlay and flag stay.)"""
    _analysed(filmed_game, overlay=overlay_before)
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    gpu = FakeProcessor(annotated=new_overlay)
    if ending == "analysis fails":
        fakes.analyze_error = ScoutError(ErrorCode.ANALYSIS_FAILED)
    else:
        fetch = gpu.fetch

        def cancel_then_fetch(handle: str, result: dict[str, Any], dest_dir) -> Any:
            db.request_cancel(job.id)
            return fetch(handle, result, dest_dir)

        gpu.fetch = cancel_then_fetch
    make_worker(gpu, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    if ending == "analysis fails":
        assert (done.status, done.stage) == (JobStatus.FAILED, JobStage.ANALYZING)
        in_place = new_overlay
    else:
        assert done.status == JobStatus.CANCELLED
        in_place = overlay_before
    assert storage.annotated_video_path(filmed_game.id).exists() is in_place
    assert db.get_game(filmed_game.id).has_annotated_video is in_place


# --- the wait limit while Modal cannot be reached -----------------------------------------------

OFFLINE = EXC.ConnectionError("Could not connect to the Modal server.")


def _scripted(fake_modal, processor, outcomes: list[Any], *, before=None) -> list[str]:  # noqa: F811
    """FunctionCall.get() raises / returns ``outcomes`` in turn (the last one repeats); ``before(n)``
    runs ahead of poll n. Returns the handles polled."""
    pending, polled, poll = list(outcomes), [], processor.poll

    def scripted_poll(handle: str):
        polled.append(handle)
        if before is not None:
            before(len(polled))
        fake_modal.outcome = pending.pop(0) if len(pending) > 1 else pending[0]
        return poll(handle)

    processor.poll = scripted_poll
    processor.poll_interval = 0.0
    return polled


def _results_on_the_volume(fake_modal, job_id: str) -> dict[str, Any]:  # noqa: F811
    """A finished run's files on the volume, and the response Modal returns for it."""
    tracking = gzip.compress(helpers.tracking([]).model_dump_json().encode())
    fake_modal.volume.files[f"results/{job_id}/tracking.json.gz"] = tracking
    return {"status": "ok", "job_id": job_id, "tracking_path": f"results/{job_id}/tracking.json.gz"}


def test_only_an_unreachable_modal_is_reported_as_unreachable(fake_modal, processor):  # noqa: F811
    fake_modal.outcome = EXC.ServiceError("unavailable")
    status = processor.poll(HANDLE)
    assert (status.state, status.unreachable) == ("running", True)
    fake_modal.outcome = TimeoutError()  # the builtin one: reachable, the call is still running
    assert processor.poll(HANDLE).unreachable is False
    finished = poll_result_from_response({"status": "ok", "tracking_path": "results/j_1/tracking.json.gz"})
    assert (finished.state, finished.unreachable) == ("succeeded", False)


def test_a_connection_that_keeps_dropping_mid_request_is_an_outage(fake_modal, processor):  # noqa: F811
    """When the connection drops mid-request on every retry, the SDK re-raises grpclib's
    StreamTerminatedError as it is (not as modal's ConnectionError). It failed the job with
    MODAL_REMOTE_ERROR as if the GPU call itself had failed: the call was not cancelled and kept
    running for nobody, and the job's cleanup went on to delete its film and results folder."""
    grpclib_exceptions = pytest.importorskip("grpclib.exceptions")
    fake_modal.outcome = grpclib_exceptions.StreamTerminatedError("Connection lost")
    status = processor.poll(HANDLE)
    assert status.state == "running" and "Lost contact" in status.message
    assert status.unreachable


def test_a_job_resumed_past_the_wait_limit_waits_for_the_network(
    filmed_game, queue, fakes, fake_modal, processor  # noqa: F811
):
    """A power cut overnight: the server is back 9 hours after the job started (the limit is 8) but
    its internet is not up yet. The first poll failed the job with MODAL_TIMEOUT, and its cleanup
    could delete the finished results waiting on the volume."""
    job = _resumed(filmed_game.id, queue, JobStage.GPU_PROCESSING, processor="modal", hours=9)
    polled = _scripted(fake_modal, processor, [OFFLINE, OFFLINE, _results_on_the_volume(fake_modal, job.id)])
    make_worker(processor, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error) == (JobStatus.SUCCEEDED, None)
    assert len(polled) == 3
    assert db.get_game(filmed_game.id).status == GameStatus.READY


@pytest.mark.parametrize("offline_polls", [0, 2])
def test_once_modal_answers_a_job_past_the_limit_times_out(
    filmed_game, queue, fakes, fake_modal, processor, offline_polls  # noqa: F811
):
    """Reachable and still running past the limit: MODAL_TIMEOUT, and the GPU call is cancelled."""
    job = _resumed(filmed_game.id, queue, JobStage.GPU_PROCESSING, processor="modal", hours=9)
    polled = _scripted(fake_modal, processor, [OFFLINE] * offline_polls + [TimeoutError()])
    make_worker(processor, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error.code) == (JobStatus.FAILED, ErrorCode.MODAL_TIMEOUT)
    assert len(polled) == offline_polls + 1
    assert fake_modal.cancelled == ["fc-01ABC"]


def test_a_day_without_contact_still_fails_the_job(
    filmed_game, queue, fakes, fake_modal, processor, monkeypatch  # noqa: F811
):
    """The wait limit no longer ends an outage; the processor's own 24 hours without contact
    (counted by this worker process) do, with MODAL_REMOTE_ERROR."""
    now = [1000.0]
    monkeypatch.setattr(modal_client, "time", SimpleNamespace(monotonic=lambda: now[0], sleep=time.sleep))

    def a_day_passes(poll: int) -> None:
        if poll == 3:
            now[0] += modal_client.CONNECTION_GRACE_S + 1

    job = _resumed(filmed_game.id, queue, JobStage.GPU_PROCESSING, processor="modal", hours=9)
    polled = _scripted(fake_modal, processor, [OFFLINE], before=a_day_passes)
    make_worker(processor, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error.code) == (JobStatus.FAILED, ErrorCode.MODAL_REMOTE_ERROR)
    assert "24 hours" in done.error.message
    assert len(polled) == 3
