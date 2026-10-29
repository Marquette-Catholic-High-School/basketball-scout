// Roster page: per-team roster import (CSV/XLSX) and editing, plus manual fixes for the
// film's jersey-to-player assignments (track overrides) and "Save & re-run analysis".

import { api, gamePath, isJobActive, jobPath, pollJob } from "./api.js";
import { applyTeamColors } from "./colors.js";
import { byId, clearError, el, formatBytes, formatPct, gameIdFromPath, notice, setChildren, show, showError, toast, withBusy } from "./ui.js";

const gameId = gameIdFromPath();
const SIDE_TITLES = { scouted: "Scouted team", other: "Their opponent in this film" };
const FIELDS = [
  { key: "jersey", label: "#", width: "jersey-input", maxlength: 3 },
  { key: "first_name", label: "First name", width: "name-input" },
  { key: "last_name", label: "Last name", width: "name-input" },
  { key: "fastscout_name", label: "FastScout name", width: "name-input" },
  { key: "position", label: "Pos", width: "short-input" },
  { key: "grade", label: "Gr", width: "short-input" },
  { key: "height", label: "Ht", width: "short-input" },
  { key: "notes", label: "Notes", width: "name-input" },
];
const JERSEY_RE = /^\d{1,2}$/; // RosterPlayer.jersey on the server
const COLUMN_NAMES = {
  jersey: "Jersey", name: "Name", first_name: "First name", last_name: "Last name", position: "Position",
  grade: "Grade", height: "Height", notes: "Notes", fastscout_name: "FastScout name",
};
const METHOD_LABELS = {
  exact: "Exact read", fuzzy: "Close read", partial: "Partial read", manual: "Set by you", unrostered: "Not on roster", none: "No readable jersey",
};
// "unrostered" with no jersey: the best read is a roster number, but the server never shows it
// on a track that is not that player (another track is, the reads were too split, or a track
// with no team read a number that is on both rosters).
const UNCLEAR_MATCH = "Unclear match";
const UNCLEAR_MATCH_TITLE = "Its best read is a roster number, but another track was matched to that player, "
  + "the readings were too split to be sure, or both rosters have that number and the track has no team. "
  + "Assign it yourself if you know who it is.";
const IMPORT_EXTENSIONS = [".csv", ".tsv", ".txt", ".xlsx"];
const MAX_IMPORT_BYTES = 2 * 1024 * 1024;
const IGNORE = "__ignore";
const UNKNOWN = "__none";
const ANALYSIS_POLL_MS = 5000; // while a full analysis runs, check this often whether it has finished
const WAIT_TITLE = "Wait for the film analysis to finish";

// analyzing: the ANALYZE job queued or running. It numbers the tracks again and clears their
// assignments, so the server takes none meanwhile (409) and the page locks them.
const state = { game: null, editors: {}, tracks: [], overrides: new Map(), pending: new Map(), analyzing: null };

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
    this.savedIds = new Set(roster.players.map((p) => p.id)); // the roster on the server, before any unsaved edit
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
      const jersey = values.jersey.replace(/^#\s*/, "");
      if (!jersey) return { problem: `Row ${i + 1} needs a jersey number.`, index: i };
      if (!JERSEY_RE.test(jersey)) return { problem: `Row ${i + 1}: a jersey number is one or two digits (0-99), not "${values.jersey}".`, index: i };
      if (seen.has(jersey)) return { problem: `Jersey #${jersey} is listed twice (rows ${seen.get(jersey) + 1} and ${i + 1}).`, index: i };
      seen.set(jersey, i);
      players.push({
        ...(row.id ? { id: row.id } : {}),
        jersey,
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

function teamName(side) {
  return state.editors[side]?.teamInput.value || SIDE_TITLES[side];
}

/**
 * The choice an override stands for: "scouted:" is the scouted team's unknown player; UNKNOWN (keep team)
 * is one that names no side, as "keep team" sends for a track the table shows with no team.
 */
function overrideValue(override) {
  if (!override) return "";
  if (override.ignore) return IGNORE;
  if (!override.player_id) return override.side ? `${override.side}:` : UNKNOWN;
  // Saving the roster drops an override whose player left it; the server then matches the track automatically.
  // Until then (a player removed but not saved yet) the override still holds, so look in the saved rosters.
  const side = ["scouted", "other"].find((s) => state.editors[s]?.savedIds.has(override.player_id));
  return side ? `${side}:${override.player_id}` : "";
}

function currentValue(trackId) {
  return state.pending.has(trackId) ? state.pending.get(trackId) : overrideValue(state.overrides.get(trackId));
}

/** Saving this choice would change nothing: it is the saved choice, or it sends the override already saved. */
function unchanged(trackId, value) {
  const saved = state.overrides.get(trackId);
  if (value === overrideValue(saved)) return true;
  if (!saved || value === "") return false;
  const body = overrideBody(trackId, value); // e.g. "keep team" for a track saved as its team's unknown player
  return body.ignore === Boolean(saved.ignore) && body.player_id === (saved.player_id ?? null) && body.side === (saved.side ?? null);
}

/** One <select> with every choice; cloned for each row. Each team starts with its unknown player. */
function assignmentTemplate() {
  return el("select", {},
    el("option", { value: "", text: "Automatic (best jersey match)" }),
    el("option", { value: UNKNOWN, text: "Unknown player (keep team)" }),
    el("option", { value: IGNORE, text: "Not a player (referee, coach, fan…)" }),
    ["scouted", "other"].map((side) => el("optgroup", { label: teamName(side) },
      el("option", { value: `${side}:`, text: `Unknown player (${teamName(side)})` }),
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

/** Match score; none for a track without reads or one you set without naming a player (e.g. a referee made a player). */
function scoreText(a) {
  return a.method === "none" || (a.method === "manual" && !a.player_id) ? "–" : formatPct(a.match_score, 0);
}

/** No roster player, yet its best read is a roster number, so it has no jersey (see UNCLEAR_MATCH). */
const unclearMatch = (a) => a.method === "unrostered" && !a.jersey && Boolean(a.best_read);

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
    select.disabled = Boolean(state.analyzing);
    return el("tr", { class: state.pending.has(a.track_id) ? "changed" : null, "data-track": String(a.track_id) },
      el("th", { scope: "row" }, `T${a.track_id}`, a.role !== "player" ? el("span", { class: "badge", text: a.role }) : null),
      el("td", {}, a.side ? el("span", { class: `chip chip-${a.side}`, text: state.editors[a.side]?.teamInput.value || a.side }) : "–"),
      el("td", { class: "num", text: String(a.frames) }),
      el("td", { text: a.best_read ? `#${a.best_read}` : "–" }),
      el("td", { class: "small", text: votesText(a.votes) }),
      el("td", { text: matchedText(a) }),
      el("td", { class: "num", text: scoreText(a) }),
      el("td", { class: "small", title: unclearMatch(a) ? UNCLEAR_MATCH_TITLE : null },
        unclearMatch(a) ? UNCLEAR_MATCH : METHOD_LABELS[a.method] || a.method, a.ignored ? el("span", { class: "badge", text: "ignored" }) : null),
      el("td", {}, select));
  });
  setChildren(byId("tracks-body"), rows.length ? rows : el("tr", {}, el("td", { colspan: "9", class: "muted", text: "No tracks match this filter." })));
  byId("tracks-count").textContent = `${rows.length} of ${state.tracks.length} tracks`;
  updatePendingNote();
}

function updatePendingNote() {
  const n = state.pending.size;
  const save = byId("tracks-save");
  byId("tracks-unsaved").textContent = n ? `${n} unsaved change${n === 1 ? "" : "s"}` : "";
  // Not while it runs (its roster save redraws the table; withBusy enables it when done) or a full analysis does.
  save.disabled = n === 0 || Boolean(state.analyzing) || save.getAttribute("aria-busy") === "true";
}

function onAssignmentChange(e) {
  const select = e.target.closest("select[data-track]");
  if (!select) return;
  const trackId = Number(select.dataset.track);
  if (unchanged(trackId, select.value)) state.pending.delete(trackId);
  else state.pending.set(trackId, select.value);
  select.closest("tr").classList.toggle("changed", state.pending.has(trackId));
  updatePendingNote();
}

function overrideBody(trackId, value) {
  const assignment = state.tracks.find((a) => a.track_id === trackId);
  const shownSide = assignment?.side ?? null; // the team the table shows (none for a referee)
  if (value === IGNORE) return { track_id: trackId, player_id: null, side: shownSide, ignore: true };
  // "Keep team" keeps the team the table shows. With no side the server takes the tracker's team,
  // which a jersey match or an earlier choice may have changed.
  if (value === UNKNOWN) return { track_id: trackId, player_id: null, side: shownSide, ignore: false };
  const [side, playerId] = value.split(":");
  return { track_id: trackId, player_id: playerId || null, side, ignore: false }; // "other:" = their unknown player
}

async function saveTracksAndRerun() {
  clearError(byId("tracks-error"));
  for (const editor of Object.values(state.editors)) {
    if (editor.dirty && !(await editor.save())) {
      showError(byId("tracks-error"), { info: { title: "Roster not saved", message: "Fix the roster problem above first, then save again." } });
      return;
    }
  }
  // The choices are for the tracks the table shows: read them again first. A Full re-analysis since the page loaded
  // (from another tab) numbers them again, and the server would put the choices on the new tracks: other players.
  let data;
  try {
    data = await api.get(gamePath(gameId, "/tracks"));
  } catch (err) {
    showError(byId("tracks-error"), err); // nothing sent: the choices stay pending
    return;
  }
  if (!sameTracking(data.assignments || [])) {
    await tracksNumberedAgain(data);
    return;
  }
  state.overrides = overridesById(data.overrides); // another tab may have saved some since: the changes go against them
  try {
    for (const [trackId, value] of state.pending) {
      const path = gamePath(gameId, `/tracks/${trackId}`);
      if (value === "") {
        // 404: saving the roster above already dropped it (its player was removed).
        if (state.overrides.has(trackId)) await api.del(path).catch((err) => { if (err.status !== 404) throw err; });
        state.overrides.delete(trackId);
      } else {
        state.overrides.set(trackId, await api.put(path, overrideBody(trackId, value)));
      }
      state.pending.delete(trackId);
    }
    renderTracks(); // saved: the rows no longer show them as changes, also if the re-run does not start
    await rerunAnalysis();
  } catch (err) {
    showError(byId("tracks-error"), err);
    renderTracks(); // the choices not saved yet stay pending
    if (err.status === 409) checkForAnalysis(); // a full analysis started after the page loaded
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
    if (err.status === 409) checkForAnalysis(); // an analysis is running: a full one clears the assignments
  }
}

/**
 * withBusy enables its button again when the action ends; not while a full analysis runs (it may have just started),
 * nor Save & re-run with nothing left to save.
 */
async function busyUnlessAnalyzing(button, label, action) {
  await withBusy(button, label, action);
  if (state.analyzing) button.disabled = true;
  updatePendingNote();
}

// ---------------------------------------------------------------------------
// The film analysed again since the page loaded
// ---------------------------------------------------------------------------

/** What a track has from the GPU run alone (its id, samples, team id and jersey reads); a REANALYZE never changes it. */
const trackingKey = (a) => JSON.stringify([a.track_id, a.frames, a.team_id ?? null, a.best_read ?? null]);

/** These are the tracks the table shows: no full analysis has numbered them again since they were loaded. */
function sameTracking(assignments) {
  const keys = (list) => list.map(trackingKey).sort().join("\n");
  return keys(assignments) === keys(state.tracks);
}

/**
 * Save & re-run found other tracks than the table shows, so it sends none of the choices. While the full analysis
 * still runs, wait for it (its end drops them); otherwise drop them now and show the new table, or none.
 */
async function tracksNumberedAgain(data) {
  let game;
  try {
    game = await api.get(gamePath(gameId));
  } catch (err) {
    showError(byId("tracks-error"), err); // nothing sent: the choices stay pending
    return;
  }
  const job = game.latest_job_id ? await api.get(jobPath(game.latest_job_id)).catch(() => null) : null;
  if (isFullAnalysis(job)) {
    waitForAnalysis(job); // polls until the analysis ends
    return;
  }
  state.game = game;
  dropTracks();
  setTracks(data);
  updatePendingNote();
  sayNumberedAgain();
  if (byId("tracks").hidden) byId("tracks-gone").scrollIntoView({ block: "nearest" }); // the table, and the button clicked, went
}

/** The choices went because the tracks were numbered again since the page loaded: say so by the new table, or where it was. */
function sayNumberedAgain() {
  const message = "The players' tracks were numbered again since this page was opened (for example by a full analysis "
    + "from another tab), so your unsaved track choices were dropped.";
  showByTracks(byId("tracks").hidden
    ? gamePageNotice("Film analysed again", message, "There are no tracks to assign now: see the game page.")
    : notice("warning", "Film analysed again", message, "Make them again in the new table."));
}

/** The earlier run's track ids are gone, with their assignments and the choices not saved yet (true when there were some). */
function dropTracks() {
  const dropped = state.pending.size > 0;
  state.pending.clear();
  state.tracks = [];
  state.overrides = new Map();
  setChildren(byId("tracks-body"));
  show(byId("tracks"), false);
  return dropped;
}

/** Say so by the tracks table, or where it was when there is none (its card is hidden); null clears it. */
function showByTracks(box) {
  const table = !byId("tracks").hidden;
  setChildren(byId("tracks-wait"), table ? box : null);
  show(byId("tracks-wait"), table && Boolean(box));
  setChildren(byId("tracks-gone"), table ? null : box);
}

/** A notice that sends the coach to the game page, which says how the analysis went. */
function gamePageNotice(title, message, hint) {
  const box = notice("warning", title, message, hint);
  box.append(el("div", { class: "notice-actions" }, el("a", { class: "btn", href: `/games/${encodeURIComponent(gameId)}`, text: "Open the game page" })));
  return box;
}

// ---------------------------------------------------------------------------
// A full analysis (ANALYZE) running
// ---------------------------------------------------------------------------

/** An ANALYZE queued or running: its new run numbers the tracks again and clears their assignments. */
const isFullAnalysis = (job) => job?.kind === "analyze" && isJobActive(job);

/** The ANALYZE put its new tracking in place (succeeded, or failed after that: the server's rule for its retry). */
const tracksRenumbered = (job) => job.kind === "analyze"
  && (job.status === "succeeded" || (job.status === "failed" && ["analyzing", "reporting"].includes(job.stage)));

/** Lock the assignment selects, Save & re-run and Re-run analysis while a full analysis runs. */
function lockAssignments() {
  const locked = Boolean(state.analyzing);
  for (const select of byId("tracks-body").querySelectorAll("select[data-track]")) select.disabled = locked;
  byId("rerun-btn").disabled = locked;
  for (const id of ["tracks-save", "rerun-btn"]) {
    if (locked) byId(id).title = WAIT_TITLE;
    else byId(id).removeAttribute("title");
  }
  updatePendingNote(); // Save & re-run: enabled again when there are unsaved choices
}

/**
 * Track assignments wait for a full analysis: say so by the tracks table, lock them and poll the job.
 * When it ends, load the game and its tracks again (after a first analysis the table appears).
 * Rosters can be edited and saved meanwhile.
 */
async function waitForAnalysis(job) {
  if (state.analyzing) return;
  state.analyzing = job;
  const wait = byId("tracks-wait");
  setChildren(wait, notice("info", "Film analysis in progress",
    "Track assignments can be made once it has finished: a full analysis numbers the players' tracks again and clears their assignments.",
    "You can keep editing the rosters. This table updates when the analysis is done."));
  show(wait, true);
  lockAssignments();
  let final;
  try {
    final = await pollJob(job.id, null, { intervalMs: ANALYSIS_POLL_MS });
  } catch {
    const box = notice("warning", "Stopped checking the film analysis",
      "The page could not find out whether the analysis has finished, so track assignments stay locked.", "Reload the page to check again.");
    box.append(el("div", { class: "notice-actions" }, el("button", { type: "button", text: "Reload the page", onClick: () => window.location.reload() })));
    setChildren(wait, box);
    return;
  }
  const game = await api.get(gamePath(gameId)).catch(() => null);
  const tableShown = !byId("tracks").hidden;
  let dropped = false;
  // Installing the new run deletes the earlier run's analysis first, so a game left without one has none of the
  // earlier run's tracks to show, also when the job failed before its stage said it had installed.
  if (tracksRenumbered(final) || (game && !game.has_analysis)) dropped = dropTracks();
  if (game) state.game = game;
  state.analyzing = null;
  clearError(byId("tracks-error")); // the 409 that started the wait, if one did
  clearError(byId("page-error")); // a refused Re-run analysis, if one started it
  showByTracks(null);
  lockAssignments();
  // Choices still kept are for the tracks the table showed, which a full analysis before this one may have numbered again.
  if (state.game.has_analysis && (await loadTracks())) {
    sayNumberedAgain();
    return;
  }
  // With no new table (the analysis failed after installing its run) its card stays hidden: say so where it was,
  // also when no choices went (the wait said this table would update).
  const tableWent = tableShown && byId("tracks").hidden;
  if (!dropped && !tableWent) return;
  showByTracks(byId("tracks").hidden
    ? gamePageNotice("Film analysis finished without results", dropped
      ? "A full analysis numbers the players' tracks again, so your unsaved track choices were dropped."
      : "There are no tracks to assign now.", "See the game page for what went wrong.")
    : notice("info", "Film analysis finished",
      "It numbered the players' tracks again, so your unsaved track choices were dropped. Make them again in the new table."));
}

/** A track change or the re-run was refused (409): if a full analysis started after the page loaded, wait for it. */
async function checkForAnalysis() {
  const game = await api.get(gamePath(gameId)).catch(() => null);
  const job = game?.latest_job_id ? await api.get(jobPath(game.latest_job_id)).catch(() => null) : null;
  if (isFullAnalysis(job)) await waitForAnalysis(job);
}

const overridesById = (overrides) => new Map((overrides || []).map((o) => [o.track_id, o]));

/** Show the tracks GET /tracks answered; the card stays hidden when there are none. */
function setTracks(data) {
  state.tracks = data.assignments || [];
  state.overrides = overridesById(data.overrides);
  show(byId("tracks"), state.tracks.length > 0);
  renderTracks();
}

/** Load the game's tracks; true when the choices kept for the table shown were dropped (the server's tracks are others now). */
async function loadTracks() {
  let data;
  try {
    data = await api.get(gamePath(gameId, "/tracks"));
  } catch (err) {
    // The table the page shows stays (after a full analysis that kept the earlier run, its tracks are the server's).
    if (err.code !== "ANALYSIS_NOT_READY" && err.status !== 404) {
      show(byId("tracks"), true);
      showError(byId("tracks-error"), err);
    }
    return false;
  }
  // Numbered again since the choices were made: on the new tracks with those numbers they would name other players.
  const dropped = state.pending.size > 0 && !sameTracking(data.assignments || []) && dropTracks();
  setTracks(data);
  return dropped;
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
  byId("tracks-save").addEventListener("click", (e) => busyUnlessAnalyzing(e.currentTarget, "Saving…", saveTracksAndRerun));
  byId("rerun-btn").addEventListener("click", (e) => busyUnlessAnalyzing(e.currentTarget, "Starting…", rerunAnalysis));
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
  // A full analysis running numbers the tracks again: assignments wait until it has finished.
  const latest = state.game.latest_job_id ? api.get(jobPath(state.game.latest_job_id)).catch(() => null) : null;
  if (state.game.has_analysis) await loadTracks();
  const job = await latest;
  if (isFullAnalysis(job)) waitForAnalysis(job); // polls until the analysis ends
  if (window.location.hash === "#tracks" && !byId("tracks").hidden) byId("tracks").scrollIntoView();
}

init();
