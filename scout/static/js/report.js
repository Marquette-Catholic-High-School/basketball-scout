// Claude scouting report: render ReportRecord.report, generate / regenerate with an
// optional coach focus, history, Markdown download and print.

import { api, gamePath, pollJob } from "./api.js";
import { jobStageText } from "./labels.js";
import { byId, clearError, el, formatDateTime, notice, setChildren, show, showError, toast } from "./ui.js";

const LIST_SECTIONS = [
  ["offensive_identity", "Offensive identity"],
  ["defensive_identity", "Defensive identity"],
  ["key_players", "Key players"],
  ["play_tendencies", "Play tendencies"],
  ["transition", "Transition"],
  ["special_situations", "Special situations"],
  ["keys_to_win", "Keys to win"],
  ["defensive_game_plan", "Defensive game plan"],
  ["offensive_game_plan", "Offensive game plan"],
  ["practice_emphasis", "Practice emphasis"],
  ["data_caveats", "Data caveats"],
];

const THREAT_LABELS = { high: "High", medium: "Medium", low: "Low" };

function bulletList(items, tag = "ul") {
  return el(tag, {}, items.map((item) => el("li", { text: item })));
}

function paragraphs(text) {
  return String(text || "").split(/\n\s*\n/).filter((p) => p.trim()).map((p) => el("p", { text: p.trim() }));
}

function keyPlayersTable(players) {
  const headers = ["#", "Player", "Role", "Threat", "Strengths", "Weaknesses", "How to defend"];
  return el("div", { class: "table-wrap" }, el("table", { class: "table-compact" },
    el("thead", {}, el("tr", {}, headers.map((h) => el("th", { scope: "col", text: h })))),
    el("tbody", {}, players.map((p) => el("tr", {},
      el("td", { text: p.jersey }),
      el("th", { scope: "row", text: p.name }),
      el("td", { text: p.role }),
      el("td", {}, el("span", { class: `badge badge-${p.threat_level}`, text: THREAT_LABELS[p.threat_level] || p.threat_level })),
      el("td", {}, bulletList(p.strengths || [])),
      el("td", {}, bulletList(p.weaknesses || [])),
      el("td", { text: p.how_to_defend }))))));
}

function tendenciesTable(rows) {
  const headers = ["Play type", "Frequency", "Effectiveness", "How to counter"];
  return el("div", { class: "table-wrap" }, el("table", { class: "table-compact" },
    el("thead", {}, el("tr", {}, headers.map((h) => el("th", { scope: "col", text: h })))),
    el("tbody", {}, rows.map((r) => el("tr", {},
      el("th", { scope: "row", text: r.play_type }),
      el("td", { text: r.frequency }),
      el("td", { text: r.effectiveness }),
      el("td", { text: r.counter }))))));
}

function sectionContent(key, value) {
  if (key === "key_players") return keyPlayersTable(value);
  if (key === "play_tendencies") return tendenciesTable(value);
  return bulletList(value, key === "keys_to_win" ? "ol" : "ul");
}

export class Report {
  constructor({ gameId }) {
    this.gameId = gameId;
    this.game = null;
    this.reports = [];
    this.polling = null;
    byId("report-generate").addEventListener("click", () => this.generate());
    byId("report-history").addEventListener("change", (e) => this.select(e.target.value));
    byId("report-print").addEventListener("click", () => this.print());
    window.addEventListener("afterprint", () => document.body.classList.remove("print-report"));
  }

  /** Load the report history; resume polling when a report job is already running. */
  async load(game, { activeJob = null, claudeConfigured = null } = {}) {
    this.game = game;
    setChildren(byId("report-claude-warning"), claudeConfigured === false
      ? notice("warning", "Claude is not configured", "Scouting reports need an Anthropic API key.", "Add ANTHROPIC_API_KEY to .env on the server and restart the worker. Stats and exports work without it.")
      : null);
    try {
      const reports = await api.get(gamePath(this.gameId, "/reports"));
      this.reports = [...reports].sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)));
    } catch (err) {
      this.reports = [];
      showError(byId("report-error"), err);
    }
    this.renderHistory();
    this.select(this.reports[0]?.id);
    if (activeJob && !this.polling) this.track(activeJob);
  }

  renderHistory() {
    const select = byId("report-history");
    setChildren(select, this.reports.map((r) => el("option", {
      value: r.id,
      text: `${formatDateTime(r.created_at)} · ${r.model}${r.coach_focus ? " · with coach focus" : ""}`,
    })));
    select.disabled = this.reports.length < 2;
    show(byId("report-history-wrap"), this.reports.length > 0);
    byId("report-generate").textContent = this.reports.length ? "Regenerate report" : "Generate report";
  }

  select(reportId) {
    const record = this.reports.find((r) => r.id === reportId);
    const download = byId("report-download");
    show(download, Boolean(record));
    show(byId("report-print"), Boolean(record));
    if (!record) {
      setChildren(byId("report-body"), el("p", { class: "muted", text: "No scouting report yet. Add anything you want Claude to focus on, then click Generate report." }));
      return;
    }
    byId("report-history").value = record.id;
    download.href = gamePath(this.gameId, `/export/report.md?report_id=${encodeURIComponent(record.id)}&download=1`);
    this.renderReport(record);
  }

  renderReport(record) {
    const report = record.report;
    const sections = LIST_SECTIONS
      .filter(([key]) => Array.isArray(report[key]) && report[key].length)
      .map(([key, title]) => el("section", { class: key === "data_caveats" ? "muted" : null },
        el("h3", { text: title }),
        sectionContent(key, report[key])));
    setChildren(byId("report-body"),
      el("h2", { text: `Scouting report: ${this.game?.display_title || ""}` }),
      el("p", { class: "report-meta", text: `Written ${formatDateTime(record.created_at)} by ${record.model}` }),
      record.coach_focus ? el("p", { class: "report-meta", text: `Coach focus: ${record.coach_focus}` }) : null,
      record.stop_reason === "max_tokens" ? notice("warning", "This report was cut off", "It hit the length limit before finishing.", "Raise SCOUT_CLAUDE_MAX_TOKENS in .env and regenerate.") : null,
      el("p", { class: "report-headline", text: report.headline }),
      paragraphs(report.executive_summary),
      sections);
  }

  async generate() {
    const button = byId("report-generate");
    const focus = byId("report-focus").value.trim();
    clearError(byId("report-error"));
    button.disabled = true;
    try {
      const job = await api.post(gamePath(this.gameId, "/reports"), { coach_focus: focus || null });
      await this.track(job);
    } catch (err) {
      showError(byId("report-error"), err);
    } finally {
      button.disabled = Boolean(this.polling);
    }
  }

  /** Poll a report job, then show the new report (or a friendly error with Retry). */
  async track(job) {
    this.polling?.abort();
    const controller = new AbortController();
    this.polling = controller;
    const button = byId("report-generate");
    const status = byId("report-status");
    button.disabled = true;
    const update = (j) => {
      status.textContent = `${jobStageText(j)}… This usually takes one to three minutes.`;
    };
    update(job);
    try {
      const final = await pollJob(job.id, update, { signal: controller.signal });
      if (final.status === "succeeded") {
        await this.load(this.game);
        toast("Scouting report ready");
      } else if (final.status === "failed") {
        const retry = final.error?.retryable ? [el("button", { type: "button", class: "btn-primary", text: "Try again", onClick: () => this.generate() })] : [];
        showError(byId("report-error"), { info: final.error || { title: "Report failed", message: "The report could not be written." } }, retry);
      } else {
        setChildren(byId("report-error"), notice("info", null, "Report generation was cancelled."));
      }
    } catch (err) {
      if (err.name !== "AbortError") showError(byId("report-error"), err);
    } finally {
      if (this.polling === controller) {
        this.polling = null;
        button.disabled = false;
        status.textContent = "";
      }
    }
  }

  print() {
    document.body.classList.add("print-report");
    window.print();
  }
}
