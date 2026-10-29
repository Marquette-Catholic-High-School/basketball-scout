// Job panel on the game page: live progress of the latest analysis job (polled every
// 3 s), Cancel, and a friendly error with Retry when a job fails.

import { api, gamePath, isJobActive, jobPath, pollJob } from "./api.js";
import { jobKindLabel, jobStageText } from "./labels.js";
import { byId, el, errorBox, formatDuration, notice, setChildren, show, withBusy } from "./ui.js";

const POLL_MS = 3000;

function elapsedSince(iso) {
  const started = Date.parse(iso || "");
  return Number.isFinite(started) ? formatDuration((Date.now() - started) / 1000) : null;
}

export class JobPanel {
  /** onChange(job) runs when a job finishes or a new one is started, so the page can reload. */
  constructor({ onChange }) {
    this.panel = byId("job-panel");
    this.onChange = onChange;
    this.controller = null;
    this.jobId = null;
  }

  /** Show the latest analysis job (or hide the panel when there is none). */
  show(job) {
    if (!job) {
      this.stop();
      show(this.panel, false);
      return;
    }
    if (isJobActive(job)) this.track(job);
    else if (job.id !== this.jobId || !this.controller) this.renderFinal(job);
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

  renderActive(job) {
    show(this.panel, true);
    const pct = Math.round(job.progress || 0);
    const queued = job.status === "queued";
    const elapsed = job.started_at ? elapsedSince(job.started_at) : null;
    setChildren(this.panel,
      el("div", { class: "card-head" },
        el("h2", { text: `${jobKindLabel(job.kind)} in progress` }),
        el("button", {
          type: "button",
          class: "btn-small btn-danger",
          disabled: job.cancel_requested,
          text: job.cancel_requested ? "Cancelling…" : "Cancel",
          onClick: (e) => this.cancel(job, e.currentTarget),
        })),
      el("p", { class: "job-stage", text: jobStageText(job) }),
      el("div", {
        class: `progress${queued ? " progress-indeterminate" : ""}`,
        role: "progressbar",
        "aria-label": "Analysis progress",
        "aria-valuemin": "0",
        "aria-valuemax": "100",
        "aria-valuenow": String(pct),
      }, el("span", { style: { width: `${pct}%` } })),
      el("p", { class: "small muted" },
        `${pct}% overall`,
        job.message ? ` · ${job.message}` : "",
        elapsed ? ` · running for ${elapsed}` : ""),
      el("p", { class: "small muted", text: "You can close this page; processing continues on the server." }));
  }

  renderFinal(job) {
    this.jobId = job.id;
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
    if (job.error?.retryable !== false) {
      actions.push(el("button", { type: "button", class: "btn-primary", text: "Retry", onClick: (e) => this.retry(job, e.currentTarget) }));
    }
    const info = job.error || { title: `${jobKindLabel(job.kind)} failed`, message: job.message || "The job stopped with an error." };
    setChildren(this.panel, errorBox({ info }, actions),
      info.detail ? el("details", { class: "small muted" }, el("summary", { text: "Technical details (for IT staff)" }), el("pre", { class: "mono", text: info.detail })) : null);
  }

  async cancel(job, button) {
    if (!window.confirm("Stop this job? You can start it again later.")) return;
    await withBusy(button, "Cancelling…", async () => {
      try {
        this.renderActive(await api.post(jobPath(job.id, "/cancel")));
      } catch (err) {
        setChildren(this.panel, errorBox(err));
      }
    });
  }

  async retry(job, button) {
    await this.start(button, () => api.post(jobPath(job.id, "/retry")));
  }

  async restart(job, button) {
    await this.start(button, () => api.post(gamePath(job.game_id, "/jobs"), { kind: job.kind }));
  }

  async start(button, request) {
    await withBusy(button, "Starting…", async () => {
      try {
        const newJob = await request();
        this.track(newJob);
        this.onChange(newJob);
      } catch (err) {
        setChildren(this.panel, errorBox(err));
      }
    });
  }
}
