// Exports: FastScout paste block (copy as tab-separated text AND an HTML table, which
// is what FastScout reads when you paste) with its warnings and the team numbers typed
// in by hand, FastScout Web custom-table CSV, timeline CSV and the raw analysis JSON.

import { api, gamePath } from "./api.js";
import { byId, clearError, el, notice, setChildren, show, showError, withBusy } from "./ui.js";

const ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" };

/** Tab-separated text -> "<table>…</table>" markup for the clipboard (cells escaped). */
export function tsvToHtml(text) {
  const escape = (cell) => cell.replace(/[&<>"]/g, (c) => ESCAPES[c]);
  const rows = String(text).replace(/\r?\n$/, "").split(/\r?\n/)
    .map((line) => `<tr>${line.split("\t").map((cell) => `<td>${escape(cell)}</td>`).join("")}</tr>`);
  return `<table>${rows.join("")}</table>`;
}

/**
 * Copy text (plus an HTML table when html is given) when the browser allows it. Returns
 * "copied", or "manual" after selecting the textarea (plain-HTTP installs: the
 * Clipboard API only works on HTTPS or localhost).
 */
async function copyBlock(text, textarea, html = null) {
  if (window.isSecureContext && navigator.clipboard) {
    try {
      if (html && window.ClipboardItem && navigator.clipboard.write) {
        await navigator.clipboard.write([new ClipboardItem({
          "text/plain": new Blob([text], { type: "text/plain" }),
          "text/html": new Blob([html], { type: "text/html" }),
        })]);
      } else {
        await navigator.clipboard.writeText(text);
      }
      return "copied";
    } catch {
      try {
        await navigator.clipboard.writeText(text);
        return "copied";
      } catch {
        // Permission denied: fall back to manual copy below.
      }
    }
  }
  textarea.focus();
  textarea.select();
  return document.execCommand && document.execCommand("copy") ? "copied" : "manual";
}

export class Exports {
  constructor({ gameId }) {
    this.gameId = gameId;
    this.teamNames = {};
    this.text = "";
    this.teamNumbers = "";
    this.loadedSide = null;
    this.loads = 0; // only the newest team's answers are shown
    this.tablesLoaded = false;
    byId("export-side").addEventListener("change", () => {
      this.updateLinks();
      this.loadBlock();
    });
    byId("export-table").addEventListener("change", () => this.updateLinks());
    byId("export-copy").addEventListener("click", (e) => withBusy(e.currentTarget, "Copying…", () => this.copy()));
    byId("export-team-copy").addEventListener("click", (e) => withBusy(e.currentTarget, "Copying…", () => this.copyTeamNumbers()));
  }

  render(teamNames) {
    this.teamNames = teamNames;
    const side = byId("export-side");
    const current = side.value || "scouted";
    setChildren(side,
      el("option", { value: "scouted", text: teamNames.scouted }),
      el("option", { value: "other", text: teamNames.other }));
    side.value = current;
    this.loadedSide = null;
    this.updateLinks();
  }

  /** Called when the Exports tab is shown: fetch the preview and table list once. */
  async activate() {
    if (!this.tablesLoaded) await this.loadTables();
    if (this.loadedSide !== byId("export-side").value) await this.loadBlock();
  }

  async loadTables() {
    const select = byId("export-table");
    try {
      const tables = await api.get("/api/export/fastscout/tables");
      setChildren(select, tables.length
        ? tables.map((name) => el("option", { value: name, text: name }))
        : el("option", { value: "", text: "Default table" }));
      this.tablesLoaded = true;
    } catch (err) {
      setChildren(select, el("option", { value: "", text: "Default table" }));
      showError(byId("export-error"), err);
    }
    this.updateLinks();
  }

  updateLinks() {
    const side = encodeURIComponent(byId("export-side").value || "scouted");
    const table = encodeURIComponent(byId("export-table").value || "");
    byId("export-txt").href = gamePath(this.gameId, `/export/fastscout.txt?side=${side}&download=1`);
    byId("export-csv").href = gamePath(this.gameId, `/export/fastscout.csv?side=${side}&table=${table}&download=1`);
    byId("export-timeline").href = gamePath(this.gameId, "/export/timeline.csv?download=1");
    byId("export-json").href = gamePath(this.gameId, "/export/analysis.json?download=1");
    const team = this.teamNames[byId("export-side").value] || "Team";
    byId("export-help-team").textContent = team;
  }

  /** Paste block and its notes for the selected team (an answer for a team no longer selected is dropped). */
  async loadBlock() {
    const side = byId("export-side").value || "scouted";
    const load = ++this.loads;
    const preview = byId("export-preview");
    clearError(byId("export-error"));
    clearError(byId("export-status"));
    preview.value = "Loading…";
    this.text = "";
    this.loadedSide = null;
    const notes = this.loadNotes(side, load);
    try {
      const text = await api.text(gamePath(this.gameId, `/export/fastscout.txt?side=${encodeURIComponent(side)}`));
      if (load !== this.loads) return;
      this.text = text || "";
      this.loadedSide = side;
      preview.value = this.text;
    } catch (err) {
      if (load !== this.loads) return;
      preview.value = "";
      showError(byId("export-error"), err);
    }
    await notes;
  }

  /** Things to check before pasting, and the team numbers typed in by hand (not part of the paste). */
  async loadNotes(side, load) {
    this.renderNotes(null);
    try {
      const notes = await api.get(gamePath(this.gameId, `/export/fastscout-notes?side=${encodeURIComponent(side)}`));
      if (load === this.loads) this.renderNotes(notes);
    } catch {
      // Optional extras (an older server has no notes route): the paste block works without them.
      if (load === this.loads) this.renderNotes(null);
    }
  }

  renderNotes(notes) {
    const warnings = Array.isArray(notes?.warnings) ? notes.warnings.filter(Boolean) : [];
    this.teamNumbers = typeof notes?.team_numbers === "string" ? notes.team_numbers.trim() : "";
    setChildren(byId("export-warnings"), warnings.length
      ? el("div", { class: "notice notice-warning" },
        el("strong", { class: "notice-title", text: "Check before pasting" }),
        el("ul", {}, warnings.map((w) => el("li", { text: w }))))
      : null);
    byId("export-team-numbers").value = this.teamNumbers;
    clearError(byId("export-team-status"));
    show(byId("export-team-wrap"), Boolean(this.teamNumbers));
    show(byId("export-notes"), Boolean(warnings.length || this.teamNumbers));
  }

  async copy() {
    const status = byId("export-status");
    if (this.loadedSide !== byId("export-side").value) await this.loadBlock();
    if (!this.text) return;
    const result = await copyBlock(this.text, byId("export-preview"), tsvToHtml(this.text));
    const team = this.teamNames[byId("export-side").value] || "Team";
    setChildren(status, result === "copied"
      ? notice("success", "Copied", `In FastScout: Stats > Edit Stats Database > Box Score > Paste ${team} Data.`)
      : notice("info", "Press Ctrl+C (Cmd+C on a Mac) to copy", "The paste block is selected below. Automatic copying needs the site to be opened over HTTPS."));
  }

  async copyTeamNumbers() {
    if (!this.teamNumbers) return;
    const result = await copyBlock(this.teamNumbers, byId("export-team-numbers"));
    setChildren(byId("export-team-status"), result === "copied"
      ? notice("success", "Copied", "Type these into FastScout by hand; they are not part of the paste.")
      : notice("info", "Press Ctrl+C (Cmd+C on a Mac) to copy", "The team numbers are selected above. Automatic copying needs the site to be opened over HTTPS."));
  }
}
