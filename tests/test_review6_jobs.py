"""Sixth review round, worker area (scout/worker.py, scout/db.py, scout/schemas.py and the film routes).

* Late cancels for a REANALYZE and a REPORT (docs/ARCHITECTURE.md, "Job lifecycle"): a cancel stops a
  REANALYZE only until its analysis starts and a REPORT only until Claude starts writing. After that the
  job succeeds, a cancel only skips the report a REANALYZE was still to write, and a job warning says so.
  A REANALYZE with a report due ended cancelled over the analysis it had saved (the page said
  "Re-analysis was cancelled" over the new analysis), and the other late cancels were ignored without a word.
* One rule for "too late to cancel" (``scout.schemas.cancel_stops_job``): a cancel request for such a job
  says "Cancel requested: too late to stop this job, so it will finish." instead of "Cancelling...". The
  stage write is the point of no return, so that message and what the worker does always agree, also when
  the worker that wrote the stage died and the next one re-claims the job (as for an ANALYZE since round 4).
* ``Game.has_tracking``: true exactly when tracking.json.gz is in the game folder, in every Game body the
  API returns, also for games saved before the field existed, so the pages know a REANALYZE can start.
* An ANALYZE claimed after its worker installed the new results goes straight on to the analysis, also
  without a cancel: no GPU poll and no new download, so its stage never goes back to gpu_processing (where
  a graceful stop handed it back as a job whose results were not installed, and the next claim installed
  them again over the track fixes the coach had made for the new run).

The late cancels and has_tracking go through the real API with an in-process worker in demo mode (the
``scout`` fixture of tests/test_review4_integration.py: the mock processor, the real analysis, Claude
faked). The re-claimed jobs and the stage-write races use the scripted FakeProcessor and the fakes of
tests/test_worker.py. The expected warnings and messages are the docs' words, not the code's constants.
"""

from __future__ import annotations

import json
import time
from typing import Any

import pytest
from fastapi.testclient import TestClient

from scout import db, schemas, storage
from scout.analysis import pipeline
from scout.reporting import claude_report
from scout.errors import ErrorCode, ScoutError
from scout.jobs.queue import submit_job
from scout.main import create_app
from scout.schemas import Game, GameStatus, Job, JobKind, JobStage, JobStatus
from scout.worker import Worker
from tests import helpers
from tests.test_api_support import fake_mp4
from tests.test_review3_integration import _upload_film
from tests.test_review3_jobs import _analysed
from tests.test_review3_verify_jobs import NEW_FIX
from tests.test_review4_integration import (  # noqa: F401 - the scout fixture
    LATE_CANCEL,
    LATE_CANCEL_REPORT_SKIPPED,
    _analysed_game,
    _failing_once,
    _new_game,
    _run,
    scout,
)
from tests.test_review4_jobs import NEW_OVERLAY, NewRun, _settings
from tests.test_review4_verify_jobs import INSTALLED_OVERLAY, _installed_then_died
from tests.test_worker import FakeProcessor, fakes, filmed_game, make_worker, queue, updates  # noqa: F401 - fixtures

# docs/ARCHITECTURE.md, "Job lifecycle".
LATE_REANALYSIS = "Cancelled after the analysis had started: the analysis was finished."
LATE_REANALYSIS_REPORT_SKIPPED = (
    "Cancelled after the analysis had started: the analysis was finished, the scouting report was skipped."
)
LATE_REPORT = "Cancelled after Claude had started writing the report: the report was kept."
TOO_LATE_TO_STOP = "Cancel requested: too late to stop this job, so it will finish."
CANCELLING = "Cancelling..."
TOO_LATE = {  # the stages at which a cancel no longer stops each kind of job
    JobKind.ANALYZE: {JobStage.ANALYZING, JobStage.REPORTING},
    JobKind.REANALYZE: {JobStage.ANALYZING, JobStage.REPORTING},
    JobKind.REPORT: {JobStage.REPORTING},
}
SPARSE_BALL = "Ball tracking was sparse: some rebounds may be missing."  # a GPU warning the first worker saved


@pytest.fixture
def api(auth_headers):
    """The real API, without a worker."""
    with TestClient(create_app(), headers=auth_headers) as test_client:
        yield test_client


def _reports(client, game_id: str) -> int:
    return len(client.get(f"/api/games/{game_id}/reports").json())


def _analysis_made_at(client, game_id: str) -> str:
    return client.get(f"/api/games/{game_id}/analysis").json()["generated_at"]


def _cancel_at(scout, stage: str, job: dict) -> dict:  # noqa: F811
    """The coach clicks Cancel once the job gets to ``stage``: the server's answer, and the job as the page
    polls it right after."""
    client = scout.client
    seen: dict[str, Any] = {}

    def cancel() -> None:
        seen["answer"] = client.post(f"/api/jobs/{job['id']}/cancel").json()
        seen["polled"] = client.get(f"/api/jobs/{job['id']}").json()

    scout.hooks[stage] = cancel
    return seen


# ---------------------------------------------------------------------------
# 1. Late cancels for a REANALYZE and a REPORT
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("report", "stage", "warning", "new_reports"),
    [
        pytest.param(False, "analyzing", LATE_REANALYSIS, 0, id="no-report-due"),
        pytest.param(True, "analyzing", LATE_REANALYSIS_REPORT_SKIPPED, 0, id="report-due"),
        pytest.param(True, "reporting", LATE_REANALYSIS, 1, id="claude-writing-the-report"),
    ],
)
def test_a_reanalysis_cancelled_after_its_analysis_started_runs_to_the_end(
    scout, report, stage, warning, new_reports  # noqa: F811
):
    """Re-run analysis, and the coach clicks Cancel during the analysis or while Claude writes the report it
    was asked for (``params.report``, as a Retry of a failed Full re-analysis sends). On HEAD the cancel was
    ignored without a word (no report due, or Claude already writing it), or the job saved the new analysis,
    skipped the report and ended cancelled, so the page said "Re-analysis was cancelled" over the new
    analysis. Now the job succeeds with the docs' warning, and the cancel answer says it will finish."""
    client = scout.client
    game_id, fix = _analysed_game(scout)
    earlier = _analysis_made_at(client, game_id)
    reports = _reports(client, game_id)
    job = client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze", "params": {"report": report}}).json()
    seen = _cancel_at(scout, stage, job)
    done = _run(scout, job)

    assert scout.hooks == {}  # the job got to that stage
    assert (done["status"], done["stage"], done["error"], done["message"]) == (
        "succeeded",
        "done",
        None,
        "Analysis updated",
    )
    assert done["warnings"] == [warning]
    assert (seen["answer"]["status"], seen["answer"]["cancel_requested"]) == ("running", True)
    assert seen["answer"]["message"] == seen["polled"]["message"] == TOO_LATE_TO_STOP
    game = client.get(f"/api/games/{game_id}").json()
    assert (game["status"], game["has_analysis"], game["error"]) == ("ready", True, None)
    assert _analysis_made_at(client, game_id) > earlier  # the new analysis is in place
    assert client.get(f"/api/games/{game_id}/tracks").json()["overrides"] == [fix]  # built with the coach's fix
    assert _reports(client, game_id) == reports + new_reports  # one Claude was writing is kept


def test_a_report_cancelled_while_claude_writes_it_is_kept_and_says_so(scout):  # noqa: F811
    """Generate report, then Cancel while Claude writes it: the job ended succeeded without a word about the
    cancel. Too late to skip it: the report is kept, and the job warning says so."""
    client = scout.client
    game_id, _fix = _analysed_game(scout)
    reports = _reports(client, game_id)
    job = client.post(f"/api/games/{game_id}/reports", json={}).json()
    seen = _cancel_at(scout, "reporting", job)
    done = _run(scout, job)

    assert (done["status"], done["stage"], done["error"], done["message"], done["warnings"]) == (
        "succeeded",
        "done",
        None,
        "Scouting report ready",
        [LATE_REPORT],
    )
    assert _reports(client, game_id) == reports + 1
    assert seen["answer"]["message"] == seen["polled"]["message"] == TOO_LATE_TO_STOP


def test_guard_a_report_whose_claude_call_fails_after_a_late_cancel_fails_with_its_error(scout):  # noqa: F811
    """(Guard.) As it would without the cancel: failed, with Claude's error and its Retry, and no report."""
    client = scout.client
    game_id, _fix = _analysed_game(scout)
    reports = _reports(client, game_id)
    job = client.post(f"/api/games/{game_id}/reports", json={}).json()

    def cancelled_then_overloaded() -> None:
        client.post(f"/api/jobs/{job['id']}/cancel")
        raise ScoutError(ErrorCode.REPORT_OVERLOADED)

    scout.hooks["reporting"] = cancelled_then_overloaded
    done = _run(scout, job)

    assert (done["status"], done["error"]["code"], done["warnings"]) == ("failed", "REPORT_OVERLOADED", [])
    assert done["message"] == done["error"]["title"] and done["error"]["retryable"] is True
    assert _reports(client, game_id) == reports


def test_guard_a_reanalysis_whose_analysis_fails_after_a_late_cancel_fails_with_its_error(scout):  # noqa: F811
    """(Guard.) As it would without the cancel: failed with the analysis error (the page's Re-run analysis),
    no report, and the earlier analysis still on disk."""
    client = scout.client
    game_id, _fix = _analysed_game(scout)
    earlier = _analysis_made_at(client, game_id)
    reports = _reports(client, game_id)
    job = client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze", "params": {"report": True}}).json()

    def cancelled_then_broken() -> None:
        client.post(f"/api/jobs/{job['id']}/cancel")
        raise ScoutError(ErrorCode.CONFIG_INVALID, detail="config/play_rules.yaml: pick_and_roll.max_screen_ft")

    scout.hooks["analyzing"] = cancelled_then_broken
    done = _run(scout, job)

    assert (done["status"], done["stage"], done["error"]["code"], done["warnings"]) == (
        "failed",
        "analyzing",
        "CONFIG_INVALID",
        [],
    )
    assert done["message"] == done["error"]["title"]
    game = client.get(f"/api/games/{game_id}").json()
    assert (game["status"], game["error"]["code"]) == ("failed", "CONFIG_INVALID")
    assert (_analysis_made_at(client, game_id), _reports(client, game_id)) == (earlier, reports)


def test_guard_a_reanalysis_cancelled_while_queued_stops_at_once(scout):  # noqa: F811
    """(Guard.) Nothing has started: the job is cancelled at once and the game keeps its analysis."""
    client = scout.client
    game_id, _fix = _analysed_game(scout)
    earlier = _analysis_made_at(client, game_id)
    job = client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"}).json()
    answer = client.post(f"/api/jobs/{job['id']}/cancel").json()

    assert (answer["status"], answer["stage"], answer["message"]) == ("cancelled", "done", "Cancelled")
    assert not scout.worker.run_once(timeout=0.2)  # nothing left for the worker
    assert client.get(f"/api/games/{game_id}").json()["status"] == "ready"
    assert _analysis_made_at(client, game_id) == earlier


@pytest.mark.parametrize("kind", ["reanalyze", "report"])
def test_guard_a_running_job_cancelled_before_its_main_step_still_stops(scout, kind):  # noqa: F811
    """(Guard.) Claimed, but the analysis (or Claude) has not started: the cancel still stops it."""
    client = scout.client
    game_id, _fix = _analysed_game(scout)
    earlier = _analysis_made_at(client, game_id)
    reports = _reports(client, game_id)
    job = client.post(f"/api/games/{game_id}/jobs", json={"kind": kind}).json()
    claimed = db.claim_job(scout.worker.worker_id, 60, job_id=job["id"])
    answer = client.post(f"/api/jobs/{job['id']}/cancel").json()
    scout.worker.process_job(claimed)
    done = client.get(f"/api/jobs/{job['id']}").json()

    assert (answer["status"], answer["message"]) == ("running", CANCELLING)
    assert (done["status"], done["error"], done["warnings"]) == ("cancelled", None, [])
    assert client.get(f"/api/games/{game_id}").json()["status"] == "ready"
    assert (_analysis_made_at(client, game_id), _reports(client, game_id)) == (earlier, reports)


@pytest.mark.parametrize(("stage", "warning"), [("analyzing", LATE_CANCEL_REPORT_SKIPPED), ("reporting", LATE_CANCEL)])
def test_guard_a_full_reanalysis_cancelled_after_its_install_still_finishes(scout, stage, warning):  # noqa: F811
    """(Guard, round 4.) An ANALYZE keeps its own late-cancel warnings."""
    client = scout.client
    game_id, _fix = _analysed_game(scout)
    reports = _reports(client, game_id)
    full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    _cancel_at(scout, stage, full)
    done = _run(scout, full)

    assert (done["status"], done["error"], done["warnings"]) == ("succeeded", None, [warning])
    assert _reports(client, game_id) == reports + (1 if stage == "reporting" else 0)


# --- the stage write is the point of no return ----------------------------------------------------


def _cancel_as_the_stage_is_written(worker: Worker, job_id: str, stage: JobStage, *, after: bool) -> list[str]:
    """The coach's cancel lands just before (or just after) the worker writes ``stage``: the messages the
    server answered the cancel with."""
    answers: list[str] = []
    write = worker._stage

    def stage_written(job_id_: str, stage_: JobStage, progress: float, message: str) -> Job:
        if stage_ == stage and not after:
            answers.append(db.request_cancel(job_id).message)
        staged = write(job_id_, stage_, progress, message)
        if stage_ == stage and after:
            answers.append(db.request_cancel(job_id).message)
        return staged

    worker._stage = stage_written
    return answers


@pytest.mark.parametrize("kind", [JobKind.REANALYZE, JobKind.REPORT])
def test_a_cancel_just_before_the_main_stage_is_written_still_stops_the_job(
    filmed_game, queue, fakes, kind  # noqa: F811
):
    """The worker checked for a cancel, then took a moment before it wrote the stage (a REPORT loads the
    whole analysis.json first). A cancel in between was answered "Cancelling..." and then ignored: the
    analysis or the report was done and the job succeeded. Now the stage write decides: asked for before
    it, the job is cancelled, as the answer said."""
    game = _analysed(filmed_game)
    earlier = storage.analysis_path(game.id).read_bytes()
    job = submit_job(game.id, kind, queue=queue)
    worker = make_worker(FakeProcessor(), queue)
    main_stage = JobStage.ANALYZING if kind == JobKind.REANALYZE else JobStage.REPORTING
    answers = _cancel_as_the_stage_is_written(worker, job.id, main_stage, after=False)
    worker.run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error, done.warnings) == (JobStatus.CANCELLED, None, [])
    assert answers == [CANCELLING]
    assert fakes.analyze == [] and fakes.reports == [] and db.list_reports(game.id) == []
    assert storage.analysis_path(game.id).read_bytes() == earlier
    assert db.get_game(game.id).status == GameStatus.READY


@pytest.mark.parametrize("kind", [JobKind.ANALYZE, JobKind.REANALYZE])
def test_a_cancel_just_before_the_report_stage_is_written_skips_the_report(
    filmed_game, queue, fakes, monkeypatch, kind  # noqa: F811
):
    """After the analysis, with a report due: the coach is told it is too late to stop the job (its stage is
    analyzing), and the cancel must skip the report. One that landed between the worker's last check and
    the reporting stage write was answered "Cancelling..." and the report was written anyway."""
    settings = _settings(monkeypatch, auto_report=True)
    game = _analysed(filmed_game)
    params = {"report": True} if kind == JobKind.REANALYZE else {}
    job = submit_job(game.id, kind, params, queue=queue)
    worker = make_worker(NewRun(), queue, settings)
    answers = _cancel_as_the_stage_is_written(worker, job.id, JobStage.REPORTING, after=False)
    worker.run_once(timeout=1)

    done = db.get_job(job.id)
    skipped = LATE_CANCEL_REPORT_SKIPPED if kind == JobKind.ANALYZE else LATE_REANALYSIS_REPORT_SKIPPED
    assert (done.status, done.error, done.warnings) == (JobStatus.SUCCEEDED, None, [skipped])
    assert len(fakes.analyze) == 1 and fakes.reports == [] and db.list_reports(game.id) == []
    assert answers == [TOO_LATE_TO_STOP]


@pytest.mark.parametrize(
    ("kind", "stage", "warning"),
    [
        (JobKind.REANALYZE, JobStage.ANALYZING, LATE_REANALYSIS),
        (JobKind.REPORT, JobStage.REPORTING, LATE_REPORT),
    ],
)
def test_a_cancel_just_after_the_main_stage_is_written_is_too_late(
    filmed_game, queue, fakes, kind, stage, warning  # noqa: F811
):
    """The other side of the same write: the answer says the job will finish, and it does."""
    game = _analysed(filmed_game)
    job = submit_job(game.id, kind, queue=queue)
    worker = make_worker(FakeProcessor(), queue)
    answers = _cancel_as_the_stage_is_written(worker, job.id, stage, after=True)
    worker.run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error, done.warnings) == (JobStatus.SUCCEEDED, None, [warning])
    assert answers == [TOO_LATE_TO_STOP]


# --- ... also when the worker that got past it died ----------------------------------------------


def _died_at(game: Game, queue, kind: JobKind, stage: JobStage, params: dict[str, Any]) -> Job:  # noqa: F811
    """A REANALYZE or REPORT whose worker died at ``stage`` (killed during the analysis, or while Claude
    wrote the report); its lease has run out, so the next worker re-claims it."""
    job = submit_job(game.id, kind, params, queue=queue)
    assert db.claim_job("w-dead", 60, job_id=job.id) is not None
    return db.update_job(job.id, stage=stage, lease_expires_at=time.time() - 1)


DIED_PAST_THE_POINT_OF_NO_RETURN = [
    pytest.param(JobKind.REANALYZE, JobStage.ANALYZING, {}, LATE_REANALYSIS, id="reanalysis"),
    pytest.param(
        JobKind.REANALYZE, JobStage.ANALYZING, {"report": True}, LATE_REANALYSIS_REPORT_SKIPPED, id="report-due"
    ),
    pytest.param(
        JobKind.REANALYZE, JobStage.REPORTING, {"report": True}, LATE_REANALYSIS_REPORT_SKIPPED, id="claude-writing"
    ),
    pytest.param(JobKind.REPORT, JobStage.REPORTING, {}, LATE_REPORT, id="report"),
]


@pytest.mark.parametrize("when", ["while-it-waited-for-a-worker", "as-the-next-worker-started"])
@pytest.mark.parametrize(("kind", "stage", "params", "warning"), DIED_PAST_THE_POINT_OF_NO_RETURN)
def test_a_job_whose_worker_died_past_the_point_of_no_return_still_runs_to_the_end_after_a_cancel(
    filmed_game, queue, fakes, monkeypatch, kind, stage, params, warning, when  # noqa: F811
):
    """The coach clicks Cancel on a job whose worker died after its analysis started (or after Claude
    started writing), while the job waits for its lease to run out or just as the next worker picks it
    up: the answer is "too late to stop this job, so it will finish", as the stage says. The next worker
    ended it cancelled all the same (the game back to its earlier analysis, no report). It now runs to the
    end like an ANALYZE whose worker died after its install: the analysis is done again from the stored
    tracking, a report not started by this worker is skipped (a REPORT job is written: it is the job), and
    the job warning says so."""
    settings = _settings(monkeypatch, auto_report=True)
    game = _analysed(filmed_game)
    job = _died_at(game, queue, kind, stage, params)
    worker = make_worker(FakeProcessor(), queue, settings)
    if when == "while-it-waited-for-a-worker":
        answers = [db.request_cancel(job.id).message]
    else:
        main_stage = JobStage.ANALYZING if kind == JobKind.REANALYZE else JobStage.REPORTING
        answers = _cancel_as_the_stage_is_written(worker, job.id, main_stage, after=False)
    worker.run_once(timeout=1)

    done = db.get_job(job.id)
    assert answers == [TOO_LATE_TO_STOP]
    assert (done.status, done.stage, done.error, done.warnings) == (JobStatus.SUCCEEDED, JobStage.DONE, None, [warning])
    assert len(fakes.analyze) == (1 if kind == JobKind.REANALYZE else 0)
    assert len(fakes.reports) == len(db.list_reports(game.id)) == (1 if kind == JobKind.REPORT else 0)
    stored = db.get_game(game.id)
    assert (stored.status, stored.has_analysis, stored.error) == (GameStatus.READY, True, None)


@pytest.mark.parametrize(("kind", "stage", "params", "warning"), DIED_PAST_THE_POINT_OF_NO_RETURN)
def test_guard_a_cancel_still_wins_when_their_workers_keep_dying(
    filmed_game, queue, fakes, monkeypatch, kind, stage, params, warning  # noqa: F811
):
    """(Guard.) Out of attempts: maybe the job is what kills the workers, so it is not run again; the
    cancel wins over WORKER_LOST, as for an ANALYZE, and the game keeps its earlier analysis."""
    settings = _settings(monkeypatch, auto_report=True)
    game = _analysed(filmed_game)
    earlier = storage.analysis_path(game.id).read_bytes()
    job = _died_at(game, queue, kind, stage, params)
    db.update_job(job.id, attempts=job.max_attempts)  # the next claim is one too many
    db.request_cancel(job.id)
    make_worker(FakeProcessor(), queue, settings).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error, done.warnings) == (JobStatus.CANCELLED, None, [])
    assert fakes.analyze == fakes.reports == [] and db.list_reports(game.id) == []
    assert storage.analysis_path(game.id).read_bytes() == earlier
    assert db.get_game(game.id).status == GameStatus.READY


@pytest.mark.parametrize("kind", [JobKind.REANALYZE, JobKind.REPORT])
def test_guard_a_job_whose_worker_died_before_its_main_step_is_still_cancelled(
    filmed_game, queue, fakes, kind  # noqa: F811
):
    """(Guard.) Claimed, then its worker died before the analysis (or Claude) started: "Cancelling...", and
    the next worker ends it cancelled."""
    game = _analysed(filmed_game)
    job = _died_at(game, queue, kind, JobStage.QUEUED, {})
    answer = db.request_cancel(job.id)
    make_worker(FakeProcessor(), queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (answer.message, done.status, done.error, done.warnings) == (CANCELLING, JobStatus.CANCELLED, None, [])
    assert fakes.analyze == fakes.reports == [] and db.get_game(game.id).status == GameStatus.READY


# ---------------------------------------------------------------------------
# 2. One rule for "too late to cancel", and the job message
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("stage", list(JobStage))
@pytest.mark.parametrize("kind", list(JobKind))
def test_cancel_stops_job_for_every_kind_and_stage(kind, stage):
    """docs/ARCHITECTURE.md: "A cancel no longer stops an ANALYZE or REANALYZE at analyzing or reporting, or
    a REPORT at reporting (scout.schemas.cancel_stops_job ...)". Every other stage is still in time."""
    assert schemas.cancel_stops_job(kind, stage) is (stage not in TOO_LATE[kind])


@pytest.mark.parametrize("stage", [stage for stage in JobStage if stage != JobStage.DONE])
@pytest.mark.parametrize("kind", list(JobKind))
def test_a_cancel_request_says_when_it_is_too_late_to_stop_the_job(game, kind, stage):
    """A running job is flagged for its worker either way; the message said "Cancelling..." also for a job
    the cancel no longer stops (the late ones failed on HEAD)."""
    job = db.create_job(game.id, kind)
    db.update_job(job.id, status=JobStatus.RUNNING, stage=stage, worker_id="w-test", lease_expires_at=time.time() + 60)
    flagged = db.request_cancel(job.id)

    message = TOO_LATE_TO_STOP if stage in TOO_LATE[kind] else CANCELLING
    assert (flagged.status, flagged.stage, flagged.cancel_requested, flagged.message) == (
        JobStatus.RUNNING,
        stage,
        True,
        message,
    )
    assert db.get_job(job.id).message == message


@pytest.mark.parametrize(
    ("stage", "message"),
    [(JobStage.GPU_PROCESSING, CANCELLING), (JobStage.ANALYZING, TOO_LATE_TO_STOP)],
)
def test_a_queued_job_with_a_gpu_call_gets_the_same_message(game, stage, message):
    """A queued row with a GPU call (as an older version's Redis reaper left them) is flagged like a running
    job, with the same rule (the analyzing case failed on HEAD)."""
    job = db.create_job(game.id, JobKind.ANALYZE)
    db.update_job(job.id, external_id="fake:orphan", processor="fake", stage=stage)
    flagged = db.request_cancel(job.id)

    assert (flagged.status, flagged.cancel_requested, flagged.message) == (JobStatus.QUEUED, True, message)


@pytest.mark.parametrize("kind", list(JobKind))
def test_guard_a_queued_job_without_a_gpu_call_is_still_cancelled_at_once(game, kind):
    """(Guard.)"""
    job = db.create_job(game.id, kind)
    done = db.request_cancel(job.id)

    assert (done.status, done.stage, done.cancel_requested, done.message) == (
        JobStatus.CANCELLED,
        JobStage.DONE,
        True,
        "Cancelled",
    )
    assert done.finished_at is not None


def test_guard_a_finished_job_is_left_alone(game):
    """(Guard.)"""
    job = db.create_job(game.id, JobKind.REPORT)
    db.update_job(job.id, status=JobStatus.SUCCEEDED, stage=JobStage.DONE, message="Scouting report ready")
    after = db.request_cancel(job.id)

    assert (after.status, after.cancel_requested, after.message) == (
        JobStatus.SUCCEEDED,
        False,
        "Scouting report ready",
    )


# ---------------------------------------------------------------------------
# 3. Game.has_tracking
# ---------------------------------------------------------------------------


def _put_tracking(game_id: str) -> None:
    """The GPU results in the game folder, as an ANALYZE installs them."""
    storage.game_dir(game_id, create=True)
    storage.write_json(storage.tracking_path(game_id), helpers.tracking([]).model_dump_json())


def _stored(game_id: str) -> dict[str, Any]:
    """The game's document as the database holds it."""
    with db.session() as conn:
        row = conn.execute("SELECT data FROM games WHERE id = ?", (game_id,)).fetchone()
    return json.loads(row["data"])


def _store(game_id: str, document: dict[str, Any]) -> None:
    """Write a game document as it is, the way an older version (or a restored backup) left it."""
    with db.session() as conn:
        conn.execute("UPDATE games SET data = ? WHERE id = ?", (json.dumps(document), game_id))


def _start_upload(api: TestClient, game_id: str) -> str:
    data = fake_mp4()
    r = api.post(f"/api/games/{game_id}/uploads", json={"filename": "vs-central.mp4", "size": len(data)})
    assert r.status_code == 201, r.text
    upload_id = r.json()["id"]
    r = api.put(
        f"/api/uploads/{upload_id}/chunk",
        params={"offset": 0},
        content=data,
        headers={"Content-Type": "application/octet-stream"},
    )
    assert r.status_code == 200, r.text
    return upload_id


@pytest.mark.parametrize("tracking", [True, False], ids=["with-tracking", "without-tracking"])
def test_every_game_body_says_whether_the_tracking_is_on_disk(api, game, tracking):
    """GET /api/games, GET and PATCH /api/games/{id} (and POST /api/games, a game with no folder yet)."""
    if tracking:
        _put_tracking(game.id)
    created = api.post("/api/games", json={"scouted_team": "North"}).json()
    bodies = {
        "list": next(body for body in api.get("/api/games").json() if body["id"] == game.id),
        "get": api.get(f"/api/games/{game.id}").json(),
        "patch": api.patch(f"/api/games/{game.id}", json={"notes": "Watch the press"}).json(),
    }

    assert created.get("has_tracking") is False
    assert {route: body.get("has_tracking") for route, body in bodies.items()} == dict.fromkeys(bodies, tracking)
    assert _stored(game.id).get("has_tracking") is tracking  # the PATCH stored it too


@pytest.mark.parametrize("tracking", [True, False], ids=["old-tracking-on-disk", "none"])
@pytest.mark.parametrize("film", ["upload", "link"])
@pytest.mark.parametrize("auto_start", [False, True])
def test_a_new_film_has_no_tracking(api, game, film, tracking, auto_start):
    """POST /api/uploads/{id}/complete and POST /api/games/{id}/video-url delete the old film's tracking:
    the game in their answer, and every read after, says so, and a REANALYZE cannot start."""
    if tracking:
        _put_tracking(game.id)
    params = {"auto_start": str(auto_start).lower()}
    if film == "upload":
        r = api.post(f"/api/uploads/{_start_upload(api, game.id)}/complete", params=params)
    else:
        r = api.post(f"/api/games/{game.id}/video-url", params=params, json={"url": "https://example.com/film.mp4"})
    assert r.status_code == 200, r.text

    assert not storage.tracking_path(game.id).exists()
    assert r.json()["game"].get("has_tracking") is False
    assert api.get(f"/api/games/{game.id}").json().get("has_tracking") is False
    assert _stored(game.id).get("has_tracking") is False
    if not auto_start:
        refused = api.post(f"/api/games/{game.id}/jobs", json={"kind": "reanalyze"})
        assert (refused.status_code, refused.json()["error"]["code"]) == (409, "ANALYSIS_NOT_READY")


def test_a_retried_upload_complete_answers_with_the_tracking_on_disk_now(api, game):
    """A retried "complete" answers like the first time, with the game as it is now."""
    upload_id = _start_upload(api, game.id)
    first = api.post(f"/api/uploads/{upload_id}/complete", params={"auto_start": "false"}).json()
    _put_tracking(game.id)  # the analysis it started has installed its results since
    again = api.post(f"/api/uploads/{upload_id}/complete", params={"auto_start": "false"}).json()

    assert (first["game"].get("has_tracking"), again["game"].get("has_tracking")) == (False, True)


@pytest.mark.parametrize("tracking", [True, False], ids=["with-tracking", "without-tracking"])
def test_a_game_saved_before_the_field_existed_reads_it_from_the_disk(api, game, tracking):
    """No migration step: the stored document has no has_tracking at all."""
    document = _stored(game.id)
    document.pop("has_tracking", None)
    _store(game.id, document)
    if tracking:
        _put_tracking(game.id)

    assert api.get(f"/api/games/{game.id}").json().get("has_tracking") is tracking
    assert next(body for body in api.get("/api/games").json() if body["id"] == game.id).get("has_tracking") is tracking
    assert db.get_game(game.id).has_tracking is tracking  # the worker reads it the same way


@pytest.mark.parametrize(("stored", "on_disk"), [(True, False), (False, True)])
def test_the_disk_wins_over_a_stored_flag_that_disagrees(api, game, stored, on_disk):
    """A data folder restored from a backup, or a worker killed between moving the tracking in and saving
    the flag: true exactly when the file is there."""
    _store(game.id, {**_stored(game.id), "has_tracking": stored})
    if on_disk:
        _put_tracking(game.id)

    assert api.get(f"/api/games/{game.id}").json().get("has_tracking") is on_disk


def test_the_install_sets_has_tracking_at_once_also_when_the_analysis_then_fails(scout, monkeypatch):  # noqa: F811
    """A first analysis whose server analysis breaks (a bad config file): the tracking is installed, so the
    game says so as soon as it is in place (in the stored document too), and a REANALYZE can start once
    the cause is fixed."""
    client = scout.client
    game_id = _new_game(scout)
    seen: dict[str, Any] = {}

    def installed_then_broken(*_args: Any, **_kwargs: Any) -> Any:
        seen["api"] = client.get(f"/api/games/{game_id}").json()
        seen["stored"] = _stored(game_id)
        raise ScoutError(ErrorCode.CONFIG_INVALID, detail="config/play_rules.yaml: pick_and_roll.max_screen_ft")

    monkeypatch.setattr(pipeline, "analyze_game", installed_then_broken)
    filmed = _upload_film(client, game_id, auto_start=True)
    done = _run(scout, filmed["job"])

    assert filmed["game"].get("has_tracking") is False
    assert (done["status"], done["stage"], done["error"]["code"]) == ("failed", "analyzing", "CONFIG_INVALID")
    assert (seen["api"].get("has_tracking"), seen["api"]["has_analysis"]) == (True, False)
    assert seen["stored"].get("has_tracking") is True
    game = client.get(f"/api/games/{game_id}").json()
    assert (game["status"], game["has_analysis"], game.get("has_tracking")) == ("failed", False, True)
    assert client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"}).status_code == 201


def test_a_full_reanalysis_cancelled_before_its_install_after_a_failure_keeps_has_tracking(
    scout, monkeypatch  # noqa: F811
):
    """A Full re-analysis failed after its install (its tracking is in place, without an analysis), then the
    next one was cancelled on the GPU: the game is back to 'uploaded' without an analysis, but with the
    tracking, so the page must offer Re-run analysis, not Analyze film."""
    client = scout.client
    game_id, _fix = _analysed_game(scout)
    _failing_once(monkeypatch, ErrorCode.CONFIG_INVALID)
    failed = _run(scout, client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json())
    assert (failed["status"], failed["stage"]) == ("failed", "analyzing")  # past the GPU: the new run is installed
    full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    scout.hooks["gpu_processing"] = lambda: client.post(f"/api/jobs/{full['id']}/cancel")
    cancelled = _run(scout, full)

    assert (cancelled["status"], cancelled["warnings"]) == ("cancelled", [])
    game = client.get(f"/api/games/{game_id}").json()
    assert (game["status"], game["has_analysis"], game.get("has_tracking")) == ("uploaded", False, True)
    listed = next(body for body in client.get("/api/games").json() if body["id"] == game_id)
    assert listed.get("has_tracking") is True and _stored(game_id).get("has_tracking") is True
    assert client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"}).status_code == 201


# ---------------------------------------------------------------------------
# 4. An ANALYZE claimed after its install goes straight on to the analysis
# ---------------------------------------------------------------------------


def _claimed_after_its_install(game: Game, queue, stage: JobStage) -> Job:  # noqa: F811
    """A Full re-analysis whose worker installed the new run, saved the GPU's warning on the job and died
    at ``stage`` (tests/test_review4_verify_jobs.py)."""
    job = _installed_then_died(game, queue, stage)
    return db.update_job(job.id, warnings=[SPARSE_BALL])


def _cleanups(gpu: FakeProcessor) -> list[tuple[str, Any]]:
    """Every processor.cleanup call: (handle, the response dict it was given)."""
    calls: list[tuple[str, Any]] = []
    gpu.cleanup = lambda handle, result: calls.append((handle, result))  # type: ignore[method-assign]
    return calls


def _stages(updates: list[dict[str, Any]]) -> list[JobStage]:  # noqa: F811
    return [fields["stage"] for fields in updates if "stage" in fields]


@pytest.mark.parametrize("auto_report", [False, True])
@pytest.mark.parametrize("stage", [JobStage.ANALYZING, JobStage.REPORTING])
def test_a_job_claimed_after_its_install_goes_straight_on_to_the_analysis(
    filmed_game, queue, fakes, updates, monkeypatch, stage, auto_report  # noqa: F811
):
    """Without a cancel the next worker polled the GPU call and downloaded and installed the same results
    again, writing gpu_processing and downloading_results meanwhile (the page asked "Stop this job?"
    although a cancel would only skip the report). Now it neither polls nor downloads: its stages are the
    analysis (and the report) only, it finishes from the installed results with the first worker's job
    warnings, and the GPU call is released as on any finish."""
    settings = _settings(monkeypatch, auto_report=auto_report)
    game = _analysed(filmed_game)
    job = _claimed_after_its_install(game, queue, stage)
    gpu = NewRun(annotated=True)  # a new download would bring NEW_OVERLAY
    cleanups = _cleanups(gpu)
    updates.clear()
    make_worker(gpu, queue, settings).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.stage, done.error, done.message) == (
        JobStatus.SUCCEEDED,
        JobStage.DONE,
        None,
        "Analysis complete",
    )
    assert gpu.submitted == gpu.polled == gpu.fetched == [] and gpu.ready_checks == 0
    report = [JobStage.REPORTING] if auto_report else []
    assert _stages(updates) == [JobStage.ANALYZING, *report, JobStage.DONE]
    assert done.warnings == [SPARSE_BALL]  # the first worker's, kept
    assert gpu.cancelled == [] and cleanups == [(f"fake:{job.id}", None)]  # the call had finished
    assert len(fakes.analyze) == 1 and fakes.analyze[0]["tracking"].job_id == job.id  # the installed results
    assert len(fakes.reports) == (1 if auto_report else 0)
    assert storage.annotated_video_path(game.id).read_bytes() == INSTALLED_OVERLAY != NEW_OVERLAY
    stored = db.get_game(game.id)
    assert (stored.status, stored.has_analysis, stored.has_annotated_video) == (GameStatus.READY, True, True)


@pytest.mark.parametrize("stage", [JobStage.ANALYZING, JobStage.REPORTING])
def test_guard_with_a_cancel_it_also_goes_straight_on_and_skips_the_report(
    filmed_game, queue, fakes, updates, monkeypatch, stage  # noqa: F811
):
    """(Guard, round 4.) The cancel only skips the report, and the job warning says so."""
    settings = _settings(monkeypatch, auto_report=True)
    game = _analysed(filmed_game)
    job = _claimed_after_its_install(game, queue, stage)
    db.request_cancel(job.id)
    gpu = NewRun(annotated=True)
    cleanups = _cleanups(gpu)
    updates.clear()
    make_worker(gpu, queue, settings).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error, done.warnings) == (
        JobStatus.SUCCEEDED,
        None,
        [SPARSE_BALL, LATE_CANCEL_REPORT_SKIPPED],
    )
    assert gpu.polled == gpu.fetched == [] and cleanups == [(f"fake:{job.id}", None)]
    assert JobStage.GPU_PROCESSING not in _stages(updates) and fakes.reports == []


def test_a_graceful_stop_no_longer_hands_it_back_at_the_gpu_stage(filmed_game, queue, fakes):  # noqa: F811
    """systemctl restart as the next worker picks the job up: its re-poll of the GPU call handed the job
    back at gpu_processing, so the claim after that no longer knew the results were installed and
    installed them again over the track fix the coach had made for the new run. The stages after the GPU
    run to the end on a graceful stop (docs/ARCHITECTURE.md), and so does this one now."""
    game = _analysed(filmed_game)
    job = _claimed_after_its_install(game, queue, JobStage.REPORTING)  # the new analysis was saved
    new_fix = db.set_track_override(game.id, NEW_FIX)  # the coach fixed one of the new run's tracks
    stopping = make_worker(NewRun(annotated=True), queue)
    stopping.stop()  # SIGTERM
    stopping.run_once(timeout=1)
    after_the_stop = db.get_job(job.id)
    if after_the_stop.status == JobStatus.RUNNING:  # handed back: the next worker resumes it
        make_worker(NewRun(annotated=True), queue).run_once(timeout=1)

    assert db.list_track_overrides(game.id) == [new_fix]
    assert fakes.analyze[-1]["overrides"] == [new_fix]
    assert storage.annotated_video_path(game.id).read_bytes() == INSTALLED_OVERLAY
    assert (after_the_stop.status, after_the_stop.stage) == (JobStatus.SUCCEEDED, JobStage.DONE)


def test_a_takeover_during_its_analysis_leaves_it_to_the_new_owner_who_goes_straight_on(
    filmed_game, queue, fakes, monkeypatch  # noqa: F811
):
    """Our lease ran out while the machine slept through the analysis and w-other took the job over: we
    step aside (no finish, the GPU call left alone). When w-other dies too, the next worker again goes
    straight on from the installed results."""
    game = _analysed(filmed_game)
    job = _claimed_after_its_install(game, queue, JobStage.ANALYZING)
    analyze = pipeline.analyze_game  # the fakes' stand-in
    calls = {"n": 0}

    def slept_through_the_first(*args: Any, **kwargs: Any) -> Any:
        calls["n"] += 1
        if calls["n"] == 1:
            db.update_job(job.id, worker_id="w-other")
        return analyze(*args, **kwargs)

    monkeypatch.setattr(pipeline, "analyze_game", slept_through_the_first)
    first = NewRun(annotated=True)
    make_worker(first, queue).run_once(timeout=1)
    stepped_aside = db.get_job(job.id)
    db.update_job(job.id, lease_expires_at=time.time() - 1)  # w-other died too
    last = NewRun(annotated=True)
    make_worker(last, queue).run_once(timeout=1)

    assert (stepped_aside.status, stepped_aside.stage, stepped_aside.worker_id) == (
        JobStatus.RUNNING,
        JobStage.ANALYZING,
        "w-other",
    )
    assert first.cancelled == first.cleaned == []  # left to w-other
    assert first.polled == first.fetched == last.polled == last.fetched == []
    done = db.get_job(job.id)
    assert (done.status, done.warnings) == (JobStatus.SUCCEEDED, [SPARSE_BALL])
    assert storage.annotated_video_path(game.id).read_bytes() == INSTALLED_OVERLAY


def test_a_job_claimed_after_its_install_whose_analysis_fails_releases_the_finished_call(
    filmed_game, queue, fakes  # noqa: F811
):
    """Failed from the installed results, without polling the call first: nothing to cancel on the GPU,
    its files are cleaned up, and the game keeps the new tracking for a Re-run analysis."""
    game = _analysed(filmed_game)
    job = _claimed_after_its_install(game, queue, JobStage.ANALYZING)
    fakes.analyze_error = ScoutError(ErrorCode.CONFIG_INVALID)
    gpu = NewRun(annotated=True)
    cleanups = _cleanups(gpu)
    make_worker(gpu, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.stage, done.error.code, done.warnings) == (
        JobStatus.FAILED,
        JobStage.ANALYZING,
        "CONFIG_INVALID",
        [SPARSE_BALL],
    )
    assert gpu.polled == gpu.fetched == gpu.cancelled == [] and cleanups == [(f"fake:{job.id}", None)]
    assert storage.tracking_path(game.id).is_file() and not storage.incoming_dir(game.id).exists()
    stored = db.get_game(game.id)
    assert (stored.status, stored.has_analysis, stored.has_annotated_video) == (GameStatus.FAILED, False, True)


# ---------------------------------------------------------------------------
# Also found: a REANALYZE or a REPORT taken over during its main step
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("kind", [JobKind.REANALYZE, JobKind.REPORT])
def test_a_reanalysis_or_a_report_taken_over_during_its_main_step_is_left_to_the_new_owner(
    filmed_game, queue, fakes, monkeypatch, kind  # noqa: F811
):
    """docs/ARCHITECTURE.md: a worker whose lease lapsed "steps aside when another worker has taken the job
    over". An ANALYZE did; a REANALYZE (after its analysis) or a REPORT (after Claude) never looked, and
    marked w-other's job succeeded while w-other was still running it."""
    _analysed(filmed_game)
    job = submit_job(filmed_game.id, kind, queue=queue)
    owner, name = (pipeline, "analyze_game") if kind == JobKind.REANALYZE else (claude_report, "generate_report")
    step = getattr(owner, name)  # the fakes' stand-in

    def slept_through(*args: Any, **kwargs: Any) -> Any:
        db.update_job(job.id, worker_id="w-other")  # our lease ran out and w-other claimed the job
        return step(*args, **kwargs)

    monkeypatch.setattr(owner, name, slept_through)
    make_worker(FakeProcessor(), queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.worker_id, done.finished_at, done.error) == (JobStatus.RUNNING, "w-other", None, None)
