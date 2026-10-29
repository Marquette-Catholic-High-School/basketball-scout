// Job panel on the game page: live progress of the latest analysis job (polled every
// 3 s), Cancel, a notice when no worker is there to take a queued job, and a friendly
// error with Retry (Re-run analysis once the GPU results are saved) when a job fails.

import { api, gamePath, isJobActive, jobPath, pollJob } from "./api.js";
import { jobKindLabel, jobStageText, workerWarning } from "./labels.js";
import { byId, clearError, el, errorBox, formatDuration, notice, setChildren, show, withBusy } from "./ui.js";

const POLL_MS = 3000;
const HEALTH_MS = 15000; // while a job is queued, ask /api/health this often whether a worker runs

function elapsedSince(iso) {
  const started = Date.parse(iso || "");
  return Number.isFinite(started) ? formatDuration((Date.now() - started) / 1000) : null;
}

/**
 * What Cancel asks first. Once an ANALYZE has installed its new results (stage analyzing or
 * reporting) a cancel no longer stops it: the analysis is finished and only the automatic
 * report is skipped, unless Claude is already writing it (scout/worker.py, _run_analyze).
 */
function cancelQuestion(job) {
  if (job.kind === "analyze" && job.stage === "analyzing") {
    return "Too late to stop the analysis: the new GPU results are already in place, so it will finish.\n\n"
      + "Cancelling now only skips the automatic scouting report.";
  }
  if (job.kind === "analyze" && job.stage === "reporting") {
    return "Too late to cancel: the analysis is finished and Claude is already writing the scouting report.\n\n"
      + "The job will finish on its own, and the report is kept.";
  }
  return "Stop this job? You can start it again later.";
}

/** A cancel no longer stops this job: it carries on to the end (see cancelQuestion). */
const tooLateToStop = (job) => job.kind === "analyze" && ["analyzing", "reporting"].includes(job.stage);

export class JobPanel {
  /**
   * onChange(job) runs when a job finishes or a new one is started, so the page can reload;
   * onUpdate(job) runs with every poll of a running job (the page header shows its progress);
   * restartConfirm(job) is what Start again asks before it starts the cancelled job again
   * (null: it starts at once).
   */
  constructor({ onChange, onUpdate = null, restartConfirm = null }) {
    this.panel = byId("job-panel");
    this.onChange = onChange;
    this.onUpdate = onUpdate;
    this.restartConfirm = restartConfirm;
    this.controller = null;
    this.jobId = null;
    this.view = null; // nodes of the "in progress" panel, updated in place by each poll
    this.finalKey = null; // "<job id>:<status>" of the finished job on show
  }

  /** Show the latest analysis job (or hide the panel when there is none). */
  show(job) {
    if (!job) {
      this.stop();
      show(this.panel, false);
      return;
    }
    if (isJobActive(job)) this.track(job);
    else if ((job.id !== this.jobId || !this.controller) && this.finalKey !== `${job.id}:${job.status}`) this.renderFinal(job);
  }

  async track(job) {
    if (this.jobId === job.id && this.controller) return;
    this.stop();
    const controller = new AbortController();
    this.controller = controller;
    this.jobId = job.id;
    this.renderActive(job);
    try {
      const final = await pollJob(job.id, (j) => this.renderActive(j), { intervalMs: POLL_MS, signal: controller.signal });
      if (this.controller !== controller) return;
      this.controller = null;
      this.renderFinal(final);
      this.onChange(final);
    } catch (err) {
      if (err.name === "AbortError" || this.controller !== controller) return;
      this.controller = null;
      setChildren(this.panel, errorBox(err, [el("button", { type: "button", text: "Check again", onClick: () => this.track(job) })]));
    }
  }

  stop() {
    this.controller?.abort();
    this.controller = null;
  }

  /**
   * Built once per job and then updated in place, so a focused Cancel button keeps focus
   * and screen readers (the panel is a polite live region) only hear the stage change,
   * not the progress line that changes with every poll.
   */
  buildActive(job) {
    const view = {
      jobId: job.id,
      job,
      title: el("h2", {}),
      cancel: el("button", { type: "button", class: "btn-small btn-danger", onClick: (e) => this.cancel(e.currentTarget) }),
      stage: el("p", { class: "job-stage" }),
      fill: el("span", {}),
      details: el("p", { class: "small muted job-details", "aria-live": "off" }),
      worker: el("div", {}),
      workerProblem: null, // hint of the worker notice shown, "" for none
      healthAt: 0, // Date.now() of the last worker check
      error: el("div", {}),
    };
    view.bar = el("div", { class: "progress", role: "progressbar", "aria-label": "Analysis progress", "aria-valuemin": "0", "aria-valuemax": "100" }, view.fill);
    setChildren(this.panel,
      el("div", { class: "card-head" }, view.title, view.cancel),
      view.stage,
      view.bar,
      view.details,
      view.worker,
      view.error,
      el("p", { class: "small muted", text: "You can close this page; processing continues on the server." }));
    return view;
  }

  renderActive(job) {
    show(this.panel, true);
    this.finalKey = null;
    if (!this.view || this.view.jobId !== job.id || !this.panel.contains(this.view.title)) this.view = this.buildActive(job);
    const view = this.view;
    view.job = job;
    const pct = Math.round(job.progress || 0);
    const elapsed = job.started_at ? elapsedSince(job.started_at) : null;
    const setText = (node, text) => {
      if (node.textContent !== text) node.textContent = text;
    };
    // Asked too late to stop it: it carries on, so the panel says what it does, not "Cancelling…" (nor the server's message).
    const late = job.cancel_requested && tooLateToStop(job);
    setText(view.title, `${jobKindLabel(job.kind)} in progress`);
    setText(view.stage, jobStageText(late ? { ...job, cancel_requested: false } : job));
    setText(view.cancel, late ? "Cancel requested" : job.cancel_requested ? "Cancelling…" : "Cancel");
    view.cancel.disabled = Boolean(job.cancel_requested);
    view.bar.classList.toggle("progress-indeterminate", job.status === "queued");
    view.bar.setAttribute("aria-valuenow", String(pct));
    view.fill.style.width = `${pct}%`;
    setText(view.details, [`${pct}% overall`, late ? null : job.message, elapsed ? `running for ${elapsed}` : null].filter(Boolean).join(" · "));
    if (job.status === "queued") {
      this.checkWorker(view);
    } else if (view.workerProblem) {
      view.workerProblem = "";
      setChildren(view.worker);
    }
    this.onUpdate?.(job);
  }

  /** A queued job waits for the background worker: say so when none is running (as the games list does). */
  async checkWorker(view) {
    if (Date.now() - view.healthAt < HEALTH_MS) return;
    view.healthAt = Date.now();
    const health = await api.get("/api/health").catch(() => null);
    if (this.view !== view || view.job.status !== "queued" || !health) return;
    const warning = workerWarning(health);
    // The notice is an alert: rewrite it when the problem changes, not with every "last seen" time.
    const problem = warning ? warning[2] : "";
    if (problem === view.workerProblem) return;
    view.workerProblem = problem;
    setChildren(view.worker, warning ? notice(warning[0], warning[1], null, warning[2]) : null);
  }

  renderFinal(job) {
    this.jobId = job.id;
    this.view = null;
    this.finalKey = `${job.id}:${job.status}`;
    if (job.status === "succeeded") {
      show(this.panel, Boolean(job.warnings?.length));
      if (job.warnings?.length) {
        setChildren(this.panel, el("div", { class: "notice notice-warning", role: "status" },
          el("strong", { class: "notice-title", text: `${jobKindLabel(job.kind)} finished with warnings` }),
          el("ul", {}, job.warnings.map((w) => el("li", { text: w })))));
      }
      return;
    }
    show(this.panel, true);
    if (job.status === "cancelled") {
      setChildren(this.panel, notice("info", `${jobKindLabel(job.kind)} was cancelled`, "Start it again whenever you are ready."),
        el("button", { type: "button", class: "btn-primary", text: "Start again", onClick: (e) => this.restart(job, e.currentTarget) }));
      return;
    }
    const actions = [];
    // An ANALYZE that failed after the GPU results were saved is retried as a REANALYZE (scout/api/jobs.py),
    // offered also for an error that is not retryable: once the cause is fixed, that cheap re-run is what helps.
    const rerun = job.kind === "analyze" && ["analyzing", "reporting"].includes(job.stage);
    if (rerun || job.error?.retryable !== false) {
      actions.push(el("button", { type: "button", class: "btn-primary", text: rerun ? "Re-run analysis" : "Retry", onClick: (e) => this.retry(job, e.currentTarget) }));
    }
    const info = job.error || { title: `${jobKindLabel(job.kind)} failed`, message: job.message || "The job stopped with an error." };
    setChildren(this.panel, errorBox({ info }, actions),
      info.detail ? el("details", { class: "small muted" }, el("summary", { text: "Technical details (for IT staff)" }), el("pre", { class: "mono", text: info.detail })) : null);
  }

  async cancel(button) {
    const view = this.view;
    if (!view || !window.confirm(cancelQuestion(view.job))) return;
    button.disabled = true;
    button.textContent = tooLateToStop(view.job) ? "Cancel requested" : "Cancelling…";
    clearError(view.error);
    try {
      const job = await api.post(jobPath(view.job.id, "/cancel"));
      // A queued job is cancelled at once; the next poll shows it as finished.
      if (this.view === view && isJobActive(job)) this.renderActive(job);
    } catch (err) {
      button.disabled = false;
      button.textContent = "Cancel";
      setChildren(view.error, errorBox(err));
    }
  }

  async retry(job, button) {
    await this.start(button, () => api.post(jobPath(job.id, "/retry")));
  }

  async restart(job, button) {
    const question = this.restartConfirm?.(job);
    if (question && !window.confirm(question)) return;
    await this.start(button, () => api.post(gamePath(job.game_id, "/jobs"), { kind: job.kind }));
  }

  async start(button, request) {
    await withBusy(button, "Starting…", async () => {
      try {
        const newJob = await request();
        this.track(newJob);
        this.onChange(newJob);
      } catch (err) {
        this.finalKey = null; // the next page refresh shows the job (and its Retry button) again
        setChildren(this.panel, errorBox(err));
      }
    });
  }
}
