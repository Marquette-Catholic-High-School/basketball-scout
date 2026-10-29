// Roster page: per-team roster import (CSV/XLSX) and editing, plus manual fixes for the
// film's jersey-to-player assignments (track overrides) and "Save & re-run analysis".

import { api, gamePath } from "./api.js";
import { applyTeamColors } from "./colors.js";
import { byId, clearError, el, formatBytes, formatPct, gameIdFromPath, notice, setChildren, show, showError, toast, withBusy } from "./ui.js";

const gameId = gameIdFromPath();
const SIDE_TITLES = { scouted: "Scouted team", other: "Their opponent in this film" };
const FIELDS = [
  { key: "jersey", label: "#", width: "jersey-input", maxlength: 3 },
  { key: "first_name", label: "First name" },
  { key: "last_name", label: "Last name" },
  { key: "fastscout_name", label: "FastScout name" },
  { key: "position", label: "Pos" },
  { key: "grade", label: "Gr" },
  { key: "height", label: "Ht" },
  { key: "notes", label: "Notes" },
];
const COLUMN_NAMES = {
  jersey: "Jersey", name: "Name", first_name: "First name", last_name: "Last name", position: "Position",
  grade: "Grade", height: "Height", notes: "Notes", fastscout_name: "FastScout name",
};
const METHOD_LABELS = {
  exact: "Exact read", fuzzy: "Close read", partial: "Partial read", manual: "Set by you", unrostered: "Not on roster", none: "No readable jersey",
};
const IMPORT_EXTENSIONS = [".csv", ".tsv", ".txt", ".xlsx"];
const MAX_IMPORT_BYTES = 2 * 1024 * 1024;
const IGNORE = "__ignore";
const UNKNOWN = "__none";

const state = { game: null, editors: {}, tracks: [], overrides: new Map(), pending: new Map() };

// ---------------------------------------------------------------------------
// Roster editor (one per team)
// ---------------------------------------------------------------------------

class RosterEditor {
  constructor(side) {
    this.side = side;
    this.rows = [];
    this.dirty = false;
    this.build();
  }

  build() {
    const headingId = `roster-heading-${this.side}`;
    this.teamInput = el("input", { maxlength: "120", autocomplete: "off", onInput: () => this.markDirty() });
    this.fileInput = el("input", { type: "file", class: "visually-hidden", accept: IMPORT_EXTENSIONS.join(",") });
    this.fileInput.addEventListener("change", () => {
      if (this.fileInput.files?.[0]) this.importFile(this.fileInput.files[0]);
      this.fileInput.value = "";
    });
    const modeName = `import-mode-${this.side}`;
    this.dropzone = el("div", { class: "dropzone roster-dropzone" },
      el("p", {}, el("strong", { text: "Drop a CSV or Excel roster here" })),
      el("label", { class: "btn btn-small" }, "Choose file", this.fileInput),
      el("fieldset", { class: "row" },
        el("legend", { class: "visually-hidden", text: "When importing" }),
        el("label", { class: "choice" }, el("input", { type: "radio", name: modeName, value: "replace", checked: true }), "Replace this roster"),
        el("label", { class: "choice" }, el("input", { type: "radio", name: modeName, value: "merge" }), "Merge (update matching jerseys)")));
    this.wireDrop();
    this.importResult = el("div", { "aria-live": "polite" });
    this.body = el("tbody", {});
    this.body.addEventListener("input", (e) => {
      const input = e.target.closest("input[data-key]");
      if (!input) return;
      this.rows[Number(input.dataset.i)][input.dataset.key] = input.value;
      input.removeAttribute("aria-invalid");
      this.markDirty();
    });
    this.body.addEventListener("click", (e) => {
      const button = e.target.closest("button[data-remove]");
      if (!button) return;
      this.rows.splice(Number(button.dataset.remove), 1);
      this.markDirty();
      this.renderRows();
    });
    this.status = el("span", { class: "unsaved", "aria-live": "polite" });
    this.error = el("div", { "aria-live": "assertive" });
    this.saveButton = el("button", { type: "button", class: "btn-primary", text: "Save roster", onClick: (e) => withBusy(e.currentTarget, "Saving…", () => this.save()) });
    this.root = el("section", { class: "card", "aria-labelledby": headingId },
      el("div", { class: "card-head" },
        el("h2", { id: headingId }, el("span", { class: `swatch chip-${this.side}`, "aria-hidden": "true" }), ` ${SIDE_TITLES[this.side]}`),
        this.status),
      el("label", { class: "field" }, "Team name", this.teamInput),
      el("div", { class: "section-sub" }, this.dropzone),
      this.importResult,
      el("div", { class: "table-wrap section-sub" }, el("table", { class: "table-compact" },
        el("caption", { class: "visually-hidden", text: `${SIDE_TITLES[this.side]} roster` }),
        el("thead", {}, el("tr", {}, FIELDS.map((f) => el("th", { scope: "col", text: f.label })), el("th", {}, el("span", { class: "visually-hidden", text: "Remove" })))),
        this.body)),
      el("div", { class: "row section-sub" },
        el("button", { type: "button", text: "+ Add player", onClick: () => this.addRow() }),
        el("span", { class: "spacer" }),
        this.saveButton),
      this.error);
  }

  wireDrop() {
    const zone = this.dropzone;
    for (const type of ["dragenter", "dragover"]) {
      zone.addEventListener(type, (e) => {
        e.preventDefault();
        zone.classList.add("dragover");
      });
    }
    for (const type of ["dragleave", "drop"]) zone.addEventListener(type, () => zone.classList.remove("dragover"));
    zone.addEventListener("drop", (e) => {
      e.preventDefault();
      const file = e.dataTransfer?.files?.[0];
      if (file) this.importFile(file);
    });
  }

  load(roster) {
    this.rows = roster.players.map((p) => ({ ...p }));
    this.teamInput.value = roster.team_name || "";
    this.dirty = false;
    this.status.textContent = "";
    this.renderRows();
  }

  markDirty() {
    this.dirty = true;
    this.status.textContent = "Unsaved changes";
  }

  addRow() {
    this.rows.push({ jersey: "", first_name: "", last_name: "" });
    this.markDirty();
    this.renderRows();
    this.body.lastElementChild?.querySelector("input")?.focus();
  }

  renderRows() {
    if (!this.rows.length) {
      setChildren(this.body, el("tr", {}, el("td", { colspan: String(FIELDS.length + 1), class: "muted", text: "No players yet. Import a file or add players." })));
      return;
    }
    setChildren(this.body, this.rows.map((row, i) => el("tr", {},
      FIELDS.map((f) => el("td", {}, el("input", {
        class: f.width || null,
        value: row[f.key] ?? "",
        maxlength: f.maxlength ? String(f.maxlength) : "120",
        "data-i": String(i),
        "data-key": f.key,
        "aria-label": `${f.label}, row ${i + 1}`,
      }))),
      el("td", {}, el("button", { type: "button", class: "btn-small btn-danger", "data-remove": String(i), "aria-label": `Remove row ${i + 1}`, text: "×" })))));
  }

  /** Clean rows for PUT; returns {players} or {problem, index} for the first invalid row. */
  collect() {
    const text = (v) => String(v ?? "").trim();
    const players = [];
    const seen = new Map();
    for (const [i, row] of this.rows.entries()) {
      const values = Object.fromEntries(FIELDS.map((f) => [f.key, text(row[f.key])]));
      if (!Object.values(values).some(Boolean)) continue;
      if (!values.jersey) return { problem: `Row ${i + 1} needs a jersey number.`, index: i };
      if (seen.has(values.jersey)) return { problem: `Jersey #${values.jersey} is listed twice (rows ${seen.get(values.jersey) + 1} and ${i + 1}).`, index: i };
      seen.set(values.jersey, i);
      players.push({
        ...(row.id ? { id: row.id } : {}),
        jersey: values.jersey,
        first_name: values.first_name,
        last_name: values.last_name,
        fastscout_name: values.fastscout_name || null,
        position: values.position || null,
        grade: values.grade || null,
        height: values.height || null,
        notes: values.notes || null,
      });
    }
    return { players };
  }

  /** PUT the roster. Returns true when saved. */
  async save() {
    clearError(this.error);
    const { players, problem, index } = this.collect();
    if (problem) {
      showError(this.error, { info: { title: "Check the roster", message: problem } });
      this.body.querySelector(`input[data-i="${index}"][data-key="jersey"]`)?.setAttribute("aria-invalid", "true");
      return false;
    }
    try {
      const roster = await api.put(gamePath(gameId, `/rosters/${this.side}`), { team_name: this.teamInput.value.trim(), players });
      this.load(roster);
      onRosterSaved();
      return true;
    } catch (err) {
      showError(this.error, err);
      return false;
    }
  }

  async importFile(file) {
    clearError(this.error);
    const name = file.name.toLowerCase();
    if (!IMPORT_EXTENSIONS.some((ext) => name.endsWith(ext))) {
      showError(this.error, { info: { title: "Unsupported roster file", message: `"${file.name}" is not a CSV or Excel (.xlsx) file.`, hint: "Save the roster as CSV or .xlsx and try again." } });
      return;
    }
    if (file.size > MAX_IMPORT_BYTES) {
      showError(this.error, { info: { title: "Roster file too large", message: `"${file.name}" is ${formatBytes(file.size)}; roster files must be under 2 MB.`, hint: "Remove extra sheets or columns and try again." } });
      return;
    }
    if (this.dirty && !window.confirm("Importing replaces your unsaved changes to this roster. Continue?")) return;
    const mode = this.root.querySelector("input[type=radio]:checked")?.value || "replace";
    const form = new FormData();
    form.append("file", file);
    form.append("mode", mode);
    setChildren(this.importResult, notice("info", null, `Reading ${file.name}…`));
    try {
      const result = await api.upload(gamePath(gameId, `/rosters/${this.side}/import?mode=${mode}`), form);
      this.load(result.roster);
      this.showImportResult(file.name, result);
      onRosterSaved();
    } catch (err) {
      this.importResult.replaceChildren();
      showError(this.error, err);
    }
  }

  showImportResult(filename, result) {
    const columns = Object.entries(result.detected_columns || {}).map(([field, header]) => `${COLUMN_NAMES[field] || field} ← "${header}"`);
    const skipped = result.skipped_rows || [];
    const warnings = result.warnings || [];
    setChildren(this.importResult, el("div", { class: "notice notice-success import-result", role: "status" },
      el("strong", { class: "notice-title", text: `Imported ${result.imported} player${result.imported === 1 ? "" : "s"} from ${filename}` }),
      columns.length ? el("p", { text: `Columns used: ${columns.join(", ")}` }) : null,
      skipped.length ? el("div", {}, el("p", { text: `${skipped.length} row${skipped.length === 1 ? " was" : "s were"} skipped:` }),
        el("ul", {}, skipped.map((s) => el("li", { text: `Row ${s.row ?? "?"}: ${s.reason ?? "not a player row"}` })))) : null,
      warnings.length ? el("div", {}, el("p", { text: "Please check:" }), el("ul", {}, warnings.map((w) => el("li", { text: w })))) : null));
  }
}

function onRosterSaved() {
  toast("Roster saved");
  if (state.game?.has_analysis) show(byId("rerun-banner"), true);
  renderTracks();
}

// ---------------------------------------------------------------------------
// Track assignments
// ---------------------------------------------------------------------------

function rosterPlayers(side) {
  const editor = state.editors[side];
  return editor ? editor.rows.filter((p) => p.id) : [];
}

function playerLabel(player) {
  const name = [player.first_name, player.last_name].filter(Boolean).join(" ");
  return name ? `#${player.jersey} ${name}` : `#${player.jersey}`;
}

function overrideValue(override) {
  if (!override) return "";
  if (override.ignore) return IGNORE;
  const side = ["scouted", "other"].find((s) => rosterPlayers(s).some((p) => p.id === override.player_id));
  // An override for a player who is no longer on a roster behaves like "unknown player".
  return override.player_id && side ? `${side}:${override.player_id}` : UNKNOWN;
}

function currentValue(trackId) {
  return state.pending.has(trackId) ? state.pending.get(trackId) : overrideValue(state.overrides.get(trackId));
}

/** One <select> with every choice; cloned for each row. */
function assignmentTemplate() {
  return el("select", {},
    el("option", { value: "", text: "Automatic (best jersey match)" }),
    el("option", { value: UNKNOWN, text: "Unknown player (keep team)" }),
    el("option", { value: IGNORE, text: "Not a player (referee, coach, fan…)" }),
    ["scouted", "other"].map((side) => el("optgroup", { label: state.editors[side]?.teamInput.value || SIDE_TITLES[side] },
      rosterPlayers(side).map((p) => el("option", { value: `${side}:${p.id}`, text: playerLabel(p) })))));
}

function votesText(votes) {
  const entries = Object.entries(votes || {});
  const total = entries.reduce((sum, [, v]) => sum + v, 0);
  if (!total) return "–";
  return entries.sort((a, b) => b[1] - a[1]).slice(0, 3).map(([jersey, v]) => `#${jersey} ${formatPct(v / total, 0)}`).join(", ");
}

function matchedText(a) {
  const player = a.side ? rosterPlayers(a.side).find((p) => p.id === a.player_id) : null;
  if (player) return playerLabel(player);
  return a.jersey ? `#${a.jersey} (not on roster)` : "–";
}

function sortedTracks() {
  const sideRank = { scouted: 0, other: 1 };
  return [...state.tracks].sort((a, b) =>
    (a.role === "player" ? 0 : 1) - (b.role === "player" ? 0 : 1)
    || (sideRank[a.side] ?? 2) - (sideRank[b.side] ?? 2)
    || b.frames - a.frames);
}

function trackVisible(a, filter) {
  const value = currentValue(a.track_id);
  if (filter === "attention") return a.role === "player" && !a.ignored && !a.player_id && value === "";
  if (filter === "ignored") return a.ignored || value === IGNORE;
  if (filter) return a.side === filter;
  return true;
}

function renderTracks() {
  if (!state.tracks.length) return;
  const filter = byId("tracks-filter").value;
  const template = assignmentTemplate();
  const rows = sortedTracks().filter((a) => trackVisible(a, filter)).map((a) => {
    const select = template.cloneNode(true);
    select.dataset.track = String(a.track_id);
    select.setAttribute("aria-label", `Assign track ${a.track_id}`);
    select.value = currentValue(a.track_id);
    return el("tr", { class: state.pending.has(a.track_id) ? "changed" : null, "data-track": String(a.track_id) },
      el("th", { scope: "row" }, `T${a.track_id}`, a.role !== "player" ? el("span", { class: "badge", text: a.role }) : null),
      el("td", {}, a.side ? el("span", { class: `chip chip-${a.side}`, text: state.editors[a.side]?.teamInput.value || a.side }) : "–"),
      el("td", { class: "num", text: String(a.frames) }),
      el("td", { text: a.best_read ? `#${a.best_read}` : "–" }),
      el("td", { class: "small", text: votesText(a.votes) }),
      el("td", { text: matchedText(a) }),
      el("td", { class: "num", text: a.method === "none" ? "–" : formatPct(a.match_score, 0) }),
      el("td", { class: "small" }, METHOD_LABELS[a.method] || a.method, a.ignored ? el("span", { class: "badge", text: "ignored" }) : null),
      el("td", {}, select));
  });
  setChildren(byId("tracks-body"), rows.length ? rows : el("tr", {}, el("td", { colspan: "9", class: "muted", text: "No tracks match this filter." })));
  byId("tracks-count").textContent = `${rows.length} of ${state.tracks.length} tracks`;
  updatePendingNote();
}

function updatePendingNote() {
  const n = state.pending.size;
  byId("tracks-unsaved").textContent = n ? `${n} unsaved change${n === 1 ? "" : "s"}` : "";
  byId("tracks-save").disabled = n === 0;
}

function onAssignmentChange(e) {
  const select = e.target.closest("select[data-track]");
  if (!select) return;
  const trackId = Number(select.dataset.track);
  if (select.value === overrideValue(state.overrides.get(trackId))) state.pending.delete(trackId);
  else state.pending.set(trackId, select.value);
  select.closest("tr").classList.toggle("changed", state.pending.has(trackId));
  updatePendingNote();
}

function overrideBody(trackId, value) {
  const assignment = state.tracks.find((a) => a.track_id === trackId);
  if (value === IGNORE) return { track_id: trackId, player_id: null, side: assignment?.side ?? null, ignore: true };
  if (value === UNKNOWN) return { track_id: trackId, player_id: null, side: assignment?.side ?? null, ignore: false };
  const [side, playerId] = value.split(":");
  return { track_id: trackId, player_id: playerId, side, ignore: false };
}

async function saveTracksAndRerun() {
  clearError(byId("tracks-error"));
  for (const editor of Object.values(state.editors)) {
    if (editor.dirty && !(await editor.save())) {
      showError(byId("tracks-error"), { info: { title: "Roster not saved", message: "Fix the roster problem above first, then save again." } });
      return;
    }
  }
  try {
    for (const [trackId, value] of state.pending) {
      const path = gamePath(gameId, `/tracks/${trackId}`);
      if (value === "") {
        if (state.overrides.has(trackId)) await api.del(path);
        state.overrides.delete(trackId);
      } else {
        state.overrides.set(trackId, await api.put(path, overrideBody(trackId, value)));
      }
      state.pending.delete(trackId);
    }
    updatePendingNote();
    await rerunAnalysis();
  } catch (err) {
    showError(byId("tracks-error"), err);
    renderTracks();
  }
}

async function rerunAnalysis() {
  const gameUrl = `/games/${encodeURIComponent(gameId)}`;
  try {
    await api.post(gamePath(gameId, "/jobs"), { kind: "reanalyze" });
    window.location.assign(gameUrl);
  } catch (err) {
    showError(byId("page-error"), err, [el("a", { class: "btn", href: gameUrl, text: "Open the game page" })]);
    byId("page-error").scrollIntoView({ block: "center" });
    toast("Your changes are saved, but the analysis did not start.", "error");
  }
}

async function loadTracks() {
  try {
    const data = await api.get(gamePath(gameId, "/tracks"));
    state.tracks = data.assignments || [];
    state.overrides = new Map((data.overrides || []).map((o) => [o.track_id, o]));
  } catch (err) {
    state.tracks = [];
    if (err.code !== "ANALYSIS_NOT_READY" && err.status !== 404) {
      show(byId("tracks"), true);
      showError(byId("tracks-error"), err);
    }
    return;
  }
  show(byId("tracks"), state.tracks.length > 0);
  renderTracks();
}

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

async function init() {
  if (!gameId) {
    showError(byId("page-error"), { info: { title: "Game not found", message: "This address doesn't point to a game.", hint: "Open a game from the games list." } });
    return;
  }
  const gameUrl = `/games/${encodeURIComponent(gameId)}`;
  byId("back-link").href = gameUrl;
  byId("nav-game").href = gameUrl;
  byId("tracks-filter").addEventListener("change", renderTracks);
  byId("tracks-body").addEventListener("change", onAssignmentChange);
  byId("tracks-save").addEventListener("click", (e) => withBusy(e.currentTarget, "Saving…", saveTracksAndRerun));
  byId("rerun-btn").addEventListener("click", (e) => withBusy(e.currentTarget, "Starting…", rerunAnalysis));
  window.addEventListener("beforeunload", (e) => {
    if (state.pending.size || Object.values(state.editors).some((ed) => ed.dirty)) {
      e.preventDefault();
      e.returnValue = "";
    }
  });

  try {
    const [game, rosters] = await Promise.all([api.get(gamePath(gameId)), api.get(gamePath(gameId, "/rosters"))]);
    state.game = game;
    applyTeamColors(game);
    document.title = `Roster - ${game.display_title} - Basketball Scout`;
    byId("roster-title").textContent = "Rosters & jerseys";
    byId("roster-subtitle").textContent = game.display_title;
    const columns = byId("roster-columns");
    for (const side of ["scouted", "other"]) {
      const editor = new RosterEditor(side);
      const roster = rosters[side] || { team_name: side === "scouted" ? game.scouted_team : game.other_team, players: [] };
      if (!roster.team_name) roster.team_name = side === "scouted" ? game.scouted_team : game.other_team;
      editor.load(roster);
      state.editors[side] = editor;
      columns.append(editor.root);
    }
    columns.setAttribute("aria-busy", "false");
  } catch (err) {
    showError(byId("page-error"), err, [el("a", { class: "btn", href: "/", text: "Back to games" })]);
    return;
  }
  if (state.game.has_analysis) await loadTracks();
  if (window.location.hash === "#tracks" && !byId("tracks").hidden) byId("tracks").scrollIntoView();
}

init();
