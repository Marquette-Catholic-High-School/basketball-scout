// Chronological event timeline with filters, possession indicator and "follow video".
// Rows are built in chunks with DocumentFragments so ~2000 events stay smooth.

import { EVENT_CATEGORY, EVENT_TYPE_LABELS, NOISY_EVENT_TYPES, PLAY_TYPE_LABELS, ZONE_LABELS, shortTeamName, teamAbbr } from "./labels.js";
import { PREROLL_S, lastIndexAtOrBefore } from "./player.js";
import { byId, debounce, el, formatClock, setChildren } from "./ui.js";

const CHUNK_ROWS = 250;
const ANY_PLAY = "__any";

/** Word placed before the secondary player, e.g. "3PT Make #3 Smith (ast. #5 Lee)". */
const SECONDARY_PREFIX = {
  shot_made: "ast.",
  shot_missed: "blk.",
  assist: "to",
  steal: "from",
  block: "on",
  turnover: "stolen by",
  foul: "on",
  pass: "to",
  screen: "for",
};

export function playerKey(ref) {
  if (!ref) return "";
  return `${ref.side || ""}|${ref.player_id || ref.label}`;
}

export function humanize(code) {
  return String(code || "").replaceAll("_", " ");
}

function zoneText(event) {
  if (!event.zone) return "";
  const label = ZONE_LABELS[event.zone] || event.zone;
  return event.subzone ? `${label} · ${humanize(event.subzone)}` : label;
}

export class Timeline {
  constructor({ player }) {
    this.player = player;
    this.body = byId("timeline-body");
    this.scroll = byId("timeline-scroll");
    this.events = [];
    this.filtered = [];
    this.rows = [];
    this.searchText = new Map();
    this.playsById = new Map();
    this.teamNames = {};
    this.currentIndex = -1;
    this.renderToken = 0;
    this.wire();
  }

  wire() {
    for (const id of ["filter-team", "filter-player", "filter-play", "filter-types"]) {
      byId(id).addEventListener("change", () => this.applyFilters());
    }
    byId("filter-search").addEventListener("input", debounce(() => this.applyFilters(), 200));
    byId("filter-reset").addEventListener("click", () => this.resetFilters());
    byId("follow-toggle").addEventListener("change", () => this.highlight(this.player.currentTime, true));
    this.body.addEventListener("click", (e) => {
      const row = e.target.closest("tr[data-i]");
      const event = row ? this.filtered[Number(row.dataset.i)] : null;
      if (event) this.player.seek(event.t - PREROLL_S, { reveal: true });
    });
    const typeMenu = byId("filter-types-wrap");
    document.addEventListener("click", (e) => {
      if (typeMenu.open && !typeMenu.contains(e.target)) typeMenu.open = false;
    });
    typeMenu.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        typeMenu.open = false;
        typeMenu.querySelector("summary").focus();
      }
    });
    this.player.onTime((t) => this.highlight(t));
  }

  render(analysis, teamNames) {
    this.events = [...analysis.timeline].sort((a, b) => a.t - b.t || a.frame - b.frame);
    this.playsById = new Map(analysis.plays.map((p) => [p.id, p]));
    this.teamNames = teamNames;
    this.searchText = new Map(this.events.map((e) => [e, this.textFor(e)]));
    this.buildFilterOptions();
    this.applyFilters();
  }

  textFor(e) {
    const play = this.playsById.get(e.play_id);
    return [e.label, e.description, e.player?.label, e.secondary_player?.label, zoneText(e), play ? PLAY_TYPE_LABELS[play.type] : ""]
      .filter(Boolean)
      .join(" ")
      .toLowerCase();
  }

  // ------------------------------------------------------------- filters
  buildFilterOptions() {
    const keep = (id) => byId(id).value;
    const restore = (select, value) => {
      if ([...select.options].some((o) => o.value === value)) select.value = value;
    };

    const team = byId("filter-team");
    const teamValue = keep("filter-team");
    setChildren(team,
      el("option", { value: "", text: "All teams" }),
      el("option", { value: "scouted", text: this.teamNames.scouted }),
      el("option", { value: "other", text: this.teamNames.other }));
    restore(team, teamValue);

    const checked = new Set([...byId("filter-types").querySelectorAll("input:checked")].map((i) => i.value));
    const present = new Set(this.events.map((e) => e.type));
    setChildren(byId("filter-types"), Object.entries(EVENT_TYPE_LABELS)
      .filter(([type]) => present.has(type))
      .map(([type, label]) => el("label", {},
        el("input", { type: "checkbox", value: type, checked: checked.has(type) }),
        el("span", { class: `ev-dot cat-${EVENT_CATEGORY[type] || "other"}`, "aria-hidden": "true" }),
        label)));

    const players = new Map();
    for (const e of this.events) {
      for (const ref of [e.player, e.secondary_player]) {
        if (ref && !players.has(playerKey(ref))) players.set(playerKey(ref), ref);
      }
    }
    const sorted = [...players.entries()].sort(([, a], [, b]) =>
      (a.side || "").localeCompare(b.side || "") || (Number(a.jersey) || 999) - (Number(b.jersey) || 999) || a.label.localeCompare(b.label));
    const player = byId("filter-player");
    const playerValue = keep("filter-player");
    setChildren(player, el("option", { value: "", text: "All players" }),
      sorted.map(([key, ref]) => el("option", { value: key, text: ref.side ? `${ref.label} (${this.teamNames[ref.side]})` : ref.label })));
    restore(player, playerValue);

    const playTypes = new Set(this.events.map((e) => this.playsById.get(e.play_id)?.type).filter(Boolean));
    const play = byId("filter-play");
    const playValue = keep("filter-play");
    setChildren(play, el("option", { value: "", text: "All plays" }),
      playTypes.size ? el("option", { value: ANY_PLAY, text: "Inside any recognised play" }) : null,
      [...playTypes].map((type) => el("option", { value: type, text: PLAY_TYPE_LABELS[type] || type })));
    restore(play, playValue);
  }

  resetFilters() {
    for (const id of ["filter-team", "filter-player", "filter-play", "filter-search"]) byId(id).value = "";
    for (const box of byId("filter-types").querySelectorAll("input")) box.checked = false;
    this.applyFilters();
  }

  applyFilters() {
    const team = byId("filter-team").value;
    const types = new Set([...byId("filter-types").querySelectorAll("input:checked")].map((i) => i.value));
    const player = byId("filter-player").value;
    const play = byId("filter-play").value;
    const query = byId("filter-search").value.trim().toLowerCase();
    const inPlay = (e) => {
      const p = this.playsById.get(e.play_id);
      return Boolean(p) && (play === ANY_PLAY || p.type === play);
    };
    this.filtered = this.events.filter((e) =>
      (!team || e.side === team)
      && (!types.size || types.has(e.type))
      && (!player || playerKey(e.player) === player || playerKey(e.secondary_player) === player)
      && (!play || inPlay(e))
      && (!query || this.searchText.get(e).includes(query)));

    byId("filter-types-summary").textContent = types.size ? `${types.size} event type${types.size > 1 ? "s" : ""}` : "All event types";
    byId("timeline-count").textContent = `${this.filtered.length} of ${this.events.length} events`;
    this.player.setMarkers(types.size ? this.filtered : this.filtered.filter((e) => !NOISY_EVENT_TYPES.has(e.type)));
    this.renderRows();
  }

  // ------------------------------------------------------------- rows
  renderRows() {
    const token = ++this.renderToken;
    this.body.replaceChildren();
    this.rows = new Array(this.filtered.length);
    this.currentIndex = -1;
    if (!this.filtered.length) {
      const text = this.events.length ? "No events match these filters." : "No events were detected in this film. The Data quality tab lists what the analysis could not do.";
      this.body.append(el("tr", {}, el("td", { colspan: "6", class: "muted", text })));
      return;
    }
    let start = 0;
    const step = () => {
      if (token !== this.renderToken) return;
      const fragment = document.createDocumentFragment();
      const end = Math.min(start + CHUNK_ROWS, this.filtered.length);
      for (let i = start; i < end; i += 1) {
        const row = this.row(this.filtered[i], i);
        this.rows[i] = row;
        fragment.append(row);
      }
      this.body.append(fragment);
      start = end;
      if (start < this.filtered.length) requestAnimationFrame(step);
      else this.highlight(this.player.currentTime, true);
    };
    step();
  }

  short(side) {
    return shortTeamName(this.teamNames[side] || side);
  }

  row(e, i) {
    const category = EVENT_CATEGORY[e.type] || "other";
    const secondary = e.secondary_player ? `(${SECONDARY_PREFIX[e.type] || "with"} ${e.secondary_player.label})` : null;
    const details = [e.player?.label, secondary, zoneText(e)].filter(Boolean).join(" ");
    return el("tr", { "data-i": String(i), class: e.confidence < 0.5 ? "low-conf" : null, title: e.description || null },
      el("td", {}, el("button", { type: "button", class: "time-btn", text: formatClock(e.t), "aria-label": `Play from ${formatClock(e.t)}` })),
      el("td", {},
        el("div", { class: "ev-label" }, el("span", { class: `ev-dot cat-${category}`, "aria-hidden": "true" }), e.label),
        details ? el("div", { class: "ev-detail", text: details }) : null),
      el("td", {}, e.side ? el("span", { class: `chip chip-${e.side}`, title: this.teamNames[e.side], text: this.short(e.side) }) : ""),
      el("td", {}, this.possessionChip(e)),
      el("td", { class: "num score-cell" },
        e.points ? el("span", { class: "pts-plus", text: `+${e.points} ` }) : null,
        `${e.score_scouted}-${e.score_other}`),
      el("td", { class: "num small", text: `${Math.round((e.confidence || 0) * 100)}%` }));
  }

  possessionChip(e) {
    if (!e.possession_side) return el("span", { class: "poss poss-none", text: "–" });
    const number = e.possession_id ?? "";
    return el("span", {
      class: `poss poss-${e.possession_side}`,
      title: `Possession ${number}: ${this.teamNames[e.possession_side]} has the ball`,
      "aria-label": `Possession ${number}, ${this.teamNames[e.possession_side]}`,
    }, `▸ ${teamAbbr(this.teamNames[e.possession_side])}${number !== "" ? ` ${number}` : ""}`);
  }

  // ------------------------------------------------------------- follow video
  highlight(t, force = false) {
    if (!this.filtered.length) return;
    const i = lastIndexAtOrBefore(this.filtered, t + 0.05);
    if (i === this.currentIndex && !force) return;
    this.rows[this.currentIndex]?.classList.remove("current");
    this.currentIndex = i;
    const row = this.rows[i];
    if (!row) return;
    row.classList.add("current");
    if (byId("follow-toggle").checked) this.scrollToRow(row);
  }

  /** Scroll only the timeline box (never the page) so the current row is visible. */
  scrollToRow(row) {
    const box = this.scroll.getBoundingClientRect();
    const rect = row.getBoundingClientRect();
    const header = this.scroll.querySelector("thead")?.getBoundingClientRect().height || 0;
    if (rect.top < box.top + header || rect.bottom > box.bottom) {
      this.scroll.scrollTop += rect.top - box.top - header - this.scroll.clientHeight / 3;
    }
  }
}
