// Exports: FastScout paste block (copy as tab-separated text AND an HTML table, which
// is what FastScout reads when you paste), FastScout Web custom-table CSV, timeline
// CSV and the raw analysis JSON.

import { api, gamePath } from "./api.js";
import { byId, clearError, el, notice, setChildren, showError, withBusy } from "./ui.js";

const ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" };

/** Tab-separated text -> "<table>…</table>" markup for the clipboard (cells escaped). */
export function tsvToHtml(text) {
  const escape = (cell) => cell.replace(/[&<>"]/g, (c) => ESCAPES[c]);
  const rows = String(text).replace(/\r?\n$/, "").split(/\r?\n/)
    .map((line) => `<tr>${line.split("\t").map((cell) => `<td>${escape(cell)}</td>`).join("")}</tr>`);
  return `<table>${rows.join("")}</table>`;
}

/**
 * Copy text with both clipboard flavours when the browser allows it. Returns
 * "copied", or "manual" after selecting the textarea (plain-HTTP installs: the
 * Clipboard API only works on HTTPS or localhost).
 */
async function copyBlock(text, textarea) {
  if (window.isSecureContext && navigator.clipboard) {
    try {
      if (window.ClipboardItem && navigator.clipboard.write) {
        await navigator.clipboard.write([new ClipboardItem({
          "text/plain": new Blob([text], { type: "text/plain" }),
          "text/html": new Blob([tsvToHtml(text)], { type: "text/html" }),
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
    this.loadedSide = null;
    this.tablesLoaded = false;
    byId("export-side").addEventListener("change", () => {
      this.updateLinks();
      this.loadBlock();
    });
    byId("export-table").addEventListener("change", () => this.updateLinks());
    byId("export-copy").addEventListener("click", (e) => withBusy(e.currentTarget, "Copying…", () => this.copy()));
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

  async loadBlock() {
    const side = byId("export-side").value || "scouted";
    const preview = byId("export-preview");
    clearError(byId("export-error"));
    preview.value = "Loading…";
    try {
      this.text = await api.text(gamePath(this.gameId, `/export/fastscout.txt?side=${encodeURIComponent(side)}`));
      this.loadedSide = side;
      preview.value = this.text;
    } catch (err) {
      this.text = "";
      this.loadedSide = null;
      preview.value = "";
      showError(byId("export-error"), err);
    }
  }

  async copy() {
    const status = byId("export-status");
    if (this.loadedSide !== byId("export-side").value) await this.loadBlock();
    if (!this.text) return;
    const result = await copyBlock(this.text, byId("export-preview"));
    const team = this.teamNames[byId("export-side").value] || "Team";
    setChildren(status, result === "copied"
      ? notice("success", "Copied", `In FastScout: Stats > Edit Stats Database > Box Score > Paste ${team} Data.`)
      : notice("info", "Press Ctrl+C (Cmd+C on a Mac) to copy", "The paste block is selected below. Automatic copying needs the site to be opened over HTTPS."));
  }
}
