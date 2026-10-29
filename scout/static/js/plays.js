// Play recognition results: per-team offense/defense summaries and the list of plays.

import { PLAY_OUTCOME_LABELS, PLAY_TYPE_LABELS, ROLE_LABELS } from "./labels.js";
import { byId, el, formatClock, formatNumber, formatPct, setChildren } from "./ui.js";

const label = (type) => PLAY_TYPE_LABELS[type] || type;

/** "Zone Defense (2-3 ×4, 1-3-1 ×1)" from the individual zone plays' attrs.zone_shape. */
function zoneShapes(plays, side) {
  const counts = new Map();
  for (const play of plays) {
    if (play.side !== side || play.type !== "zone_defense" || !play.attrs?.zone_shape) continue;
    counts.set(play.attrs.zone_shape, (counts.get(play.attrs.zone_shape) || 0) + 1);
  }
  return [...counts.entries()].sort((a, b) => b[1] - a[1]).map(([shape, n]) => `${shape} ×${n}`).join(", ");
}

function playersText(play) {
  return Object.entries(play.players || {})
    .filter(([, ref]) => ref)
    .map(([role, ref]) => `${ROLE_LABELS[role] || role.replaceAll("_", " ")}: ${ref.label}`)
    .join(" · ");
}

export class Plays {
  constructor({ player }) {
    this.player = player;
    this.plays = [];
    this.listed = [];
    this.teamNames = {};
    byId("plays-filter-type").addEventListener("change", () => this.drawList());
    byId("plays-filter-side").addEventListener("change", () => this.drawList());
    byId("plays-body").addEventListener("click", (e) => {
      const row = e.target.closest("tr[data-i]");
      const play = row ? this.listed[Number(row.dataset.i)] : null;
      if (play) this.player.seek(Math.max(0, play.start_t - 1), { reveal: true });
    });
  }

  render(analysis, teamNames) {
    this.plays = [...(analysis.plays || [])].sort((a, b) => a.start_t - b.start_t);
    this.teamNames = teamNames;
    this.drawSummary(analysis.play_summary || []);
    this.buildFilters();
    this.drawList();
  }

  drawSummary(summary) {
    const blocks = ["scouted", "other"].map((side) => {
      const offense = summary.filter((s) => s.side === side && s.category === "offense").sort((a, b) => b.count - a.count);
      const defense = summary.filter((s) => s.side === side && s.category === "defense").sort((a, b) => b.count - a.count);
      if (!offense.length && !defense.length) return null;
      return el("div", {},
        el("h3", {}, el("span", { class: `swatch chip-${side}`, "aria-hidden": "true" }), ` ${this.teamNames[side]}`),
        offense.length ? this.summaryTable(`${this.teamNames[side]} offense`, "Offense", offense) : null,
        defense.length ? this.summaryTable(`${this.teamNames[side]} defense`, "Defense", defense, side) : null);
    }).filter(Boolean);
    setChildren(byId("plays-summary"), blocks.length
      ? el("div", { class: "grid-2" }, blocks)
      : el("p", { class: "muted", text: "No plays were recognised in this film." }));
  }

  summaryTable(caption, heading, rows, defenseSide = null) {
    const headers = [heading, "Count", "% Poss", "PTS", "PPP", "FG", "TO"];
    return el("div", { class: "table-wrap section-sub" }, el("table", { class: "table-compact" },
      el("caption", { class: "visually-hidden", text: caption }),
      el("thead", {}, el("tr", {}, headers.map((h, i) => el("th", { scope: "col", class: i ? "num" : null, text: h })))),
      el("tbody", {}, rows.map((s) => {
        const shapes = defenseSide && s.type === "zone_defense" ? zoneShapes(this.plays, defenseSide) : "";
        return el("tr", {},
          el("th", { scope: "row" }, label(s.type), shapes ? el("span", { class: "muted small", text: ` (${shapes})` }) : null),
          el("td", { class: "num", text: String(s.count) }),
          el("td", { class: "num", text: formatPct(s.possessions_pct, 0) }),
          el("td", { class: "num", text: String(s.points) }),
          el("td", { class: "num", text: formatNumber(s.ppp, 2) }),
          el("td", { class: "num", text: `${s.fgm}-${s.fga}` }),
          el("td", { class: "num", text: String(s.turnovers) }));
      }))));
  }

  buildFilters() {
    const typeSelect = byId("plays-filter-type");
    const current = typeSelect.value;
    const types = [...new Set(this.plays.map((p) => p.type))];
    setChildren(typeSelect, el("option", { value: "", text: "All play types" }), types.map((t) => el("option", { value: t, text: label(t) })));
    if (types.includes(current)) typeSelect.value = current;
    const sideSelect = byId("plays-filter-side");
    const side = sideSelect.value;
    setChildren(sideSelect,
      el("option", { value: "", text: "Both teams" }),
      el("option", { value: "scouted", text: this.teamNames.scouted }),
      el("option", { value: "other", text: this.teamNames.other }));
    sideSelect.value = side;
  }

  drawList() {
    const type = byId("plays-filter-type").value;
    const side = byId("plays-filter-side").value;
    this.listed = this.plays.filter((p) => (!type || p.type === type) && (!side || p.side === side));
    const rows = this.listed.map((play, i) => el("tr", { class: `play-row${play.confidence < 0.5 ? " low-conf" : ""}`, "data-i": String(i), title: play.description || null },
      el("td", {}, el("button", { type: "button", class: "time-btn", text: formatClock(play.start_t), "aria-label": `Watch play at ${formatClock(play.start_t)}` })),
      el("td", {}, label(play.type), play.attrs?.zone_shape ? ` (${play.attrs.zone_shape})` : ""),
      el("td", {}, play.side ? el("span", { class: `chip chip-${play.side}`, text: this.teamNames[play.side] }) : "–"),
      el("td", { class: "small", text: playersText(play) }),
      el("td", { text: PLAY_OUTCOME_LABELS[play.outcome] || play.outcome }),
      el("td", { class: "num", text: play.points ? String(play.points) : "" }),
      el("td", { class: "num small", text: `${Math.round((play.confidence || 0) * 100)}%` })));
    setChildren(byId("plays-body"), rows.length ? rows : el("tr", {}, el("td", { colspan: "7", class: "muted", text: "No plays match these filters." })));
    byId("plays-count").textContent = `${this.listed.length} of ${this.plays.length} plays`;
  }
}
