// Box score: one sortable table per team plus shooting splits by zone.

import { byId, el, formatNumber, formatPct, setChildren } from "./ui.js";

const made = (m, a) => `${m}-${a}`;
const signed = (v) => (v === null || v === undefined ? "–" : v > 0 ? `+${v}` : String(v));
/** Numeric jersey order where "0" sorts before "00" (they are different numbers). */
function jerseyValue(line) {
  const jersey = line.player.jersey || "";
  const number = Number(jersey);
  return jersey && Number.isFinite(number) ? number * 10 + jersey.length : Infinity;
}

/** Column: key, label, value (for sorting), show (cell text), text (sort as text). */
const COLUMNS = [
  { key: "jersey", label: "#", value: jerseyValue, show: (l) => l.player.jersey ?? "", asc: true },
  { key: "player", label: "Player", value: (l) => (l.player.name || l.player.label || "").toLowerCase(), show: (l) => l.player.name || l.player.label, text: true },
  { key: "min", label: "MIN", value: (l) => l.minutes_est ?? -1, show: (l) => formatNumber(l.minutes_est, 1), title: "Approximate on-floor video minutes" },
  { key: "pts", label: "PTS", value: (l) => l.pts },
  { key: "fg", label: "FG", value: (l) => l.fgm, show: (l) => made(l.fgm, l.fga) },
  { key: "fg_pct", label: "FG%", value: (l) => l.fg_pct ?? -1, show: (l) => formatPct(l.fg_pct) },
  { key: "tp", label: "3PT", value: (l) => l.tpm, show: (l) => made(l.tpm, l.tpa) },
  { key: "tp_pct", label: "3P%", value: (l) => l.tp_pct ?? -1, show: (l) => formatPct(l.tp_pct) },
  { key: "ft", label: "FT", value: (l) => l.ftm, show: (l) => made(l.ftm, l.fta) },
  { key: "ft_pct", label: "FT%", value: (l) => l.ft_pct ?? -1, show: (l) => formatPct(l.ft_pct) },
  { key: "oreb", label: "OREB", value: (l) => l.oreb },
  { key: "dreb", label: "DREB", value: (l) => l.dreb },
  { key: "reb", label: "REB", value: (l) => l.reb ?? l.oreb + l.dreb },
  { key: "ast", label: "AST", value: (l) => l.ast },
  { key: "stl", label: "STL", value: (l) => l.stl },
  { key: "blk", label: "BLK", value: (l) => l.blk },
  { key: "tov", label: "TO", value: (l) => l.tov },
  { key: "pf", label: "PF", value: (l) => l.pf },
  { key: "plus_minus", label: "+/-", value: (l) => l.plus_minus ?? -Infinity, show: (l) => signed(l.plus_minus) },
];

const cellText = (column, line) => String(column.show ? column.show(line) : column.value(line));

/** Players sorted by a column (null key keeps the server order). */
export function sortLines(lines, key, direction) {
  const column = COLUMNS.find((c) => c.key === key);
  if (!column) return [...lines];
  const factor = direction === "asc" ? 1 : -1;
  return [...lines].sort((a, b) => {
    const va = column.value(a);
    const vb = column.value(b);
    if (column.text) return factor * String(va).localeCompare(String(vb));
    return factor * ((va > vb) - (va < vb));
  });
}

export class BoxScore {
  constructor() {
    this.content = byId("box-content");
    this.switcher = byId("box-team-switch");
    this.boxes = [];
    this.side = "scouted";
    this.sort = { key: null, direction: "desc" };
    this.switcher.addEventListener("click", (e) => {
      const button = e.target.closest("button[data-side]");
      if (!button) return;
      this.side = button.dataset.side;
      this.draw();
    });
  }

  render(analysis) {
    this.boxes = analysis.box_scores || [];
    if (!this.boxes.some((b) => b.side === this.side) && this.boxes.length) this.side = this.boxes[0].side;
    this.draw();
  }

  draw() {
    setChildren(this.switcher, this.boxes.map((box) => el("button", {
      type: "button",
      "data-side": box.side,
      "aria-pressed": String(box.side === this.side),
    }, el("span", { class: `swatch chip-${box.side}`, "aria-hidden": "true" }), ` ${box.team_name}`)));
    const box = this.boxes.find((b) => b.side === this.side);
    if (!box) {
      setChildren(this.content, el("p", { class: "muted", text: "No box score in this analysis." }));
      return;
    }
    setChildren(this.content,
      el("div", { class: "table-wrap" }, this.table(box)),
      el("div", { class: "summary-line" },
        el("span", {}, "Points: ", el("strong", { text: String(box.totals.pts) })),
        el("span", {}, "Possessions: ", el("strong", { text: String(box.possessions) })),
        el("span", {}, "Points per possession: ", el("strong", { text: formatNumber(box.points_per_possession, 2) }))),
      el("h3", { class: "section-sub", text: "Shooting by zone" }),
      el("div", { class: "table-wrap" }, this.zoneTable(box)));
  }

  table(box) {
    const head = el("tr", {}, COLUMNS.map((column) => {
      const active = this.sort.key === column.key;
      return el("th", {
        scope: "col",
        class: `sortable${column.text || column.key === "jersey" ? "" : " num"}`,
        "aria-sort": active ? (this.sort.direction === "asc" ? "ascending" : "descending") : "none",
        title: column.title || null,
      }, el("button", { type: "button", text: column.label, onClick: () => this.sortBy(column) }));
    }));
    const rows = sortLines(box.players, this.sort.key, this.sort.direction).map((line) => this.line(line));
    const team = this.line({ ...box.team_unattributed, player: { ...box.team_unattributed.player, jersey: "", name: "Team / unidentified" } }, "team-row");
    const totals = this.line({ ...box.totals, player: { ...box.totals.player, jersey: "", name: "Totals" } }, "total-row");
    return el("table", { class: "boxscore-table" },
      el("caption", { class: "visually-hidden", text: `${box.team_name} box score` }),
      el("thead", {}, head),
      el("tbody", {}, rows.length ? rows : el("tr", {}, el("td", { colspan: String(COLUMNS.length), class: "muted", text: "No identified players yet - match jerseys on the roster page." })), team),
      el("tfoot", {}, totals));
  }

  line(line, className = null) {
    return el("tr", { class: className }, COLUMNS.map((column) =>
      el(column.key === "player" ? "th" : "td", {
        scope: column.key === "player" ? "row" : null,
        class: column.text || column.key === "jersey" ? null : "num",
        text: cellText(column, line),
      })));
  }

  sortBy(column) {
    if (this.sort.key === column.key) this.sort.direction = this.sort.direction === "asc" ? "desc" : "asc";
    else this.sort = { key: column.key, direction: column.text || column.asc ? "asc" : "desc" };
    this.draw();
  }

  zoneTable(box) {
    const zones = [["paint", "Paint"], ["mid", "Mid-range"], ["three", "3-point"], ["unknown", "No location"]];
    const split = (s) => (s && s.attempts ? `${s.made}-${s.attempts} (${formatPct(s.pct, 0)})` : "–");
    const row = (line, name, className = null) => el("tr", { class: className },
      el("th", { scope: "row", text: name }),
      zones.map(([key]) => el("td", { class: "num", text: split(line.zones?.[key]) })));
    return el("table", { class: "table-compact" },
      el("caption", { class: "visually-hidden", text: `${box.team_name} shooting by zone` }),
      el("thead", {}, el("tr", {}, el("th", { scope: "col", text: "Player" }), zones.map(([, label]) => el("th", { scope: "col", class: "num", text: label })))),
      el("tbody", {}, box.players.map((line) => row(line, line.player.label)), row(box.team_unattributed, "Team / unidentified", "team-row")),
      el("tfoot", {}, row(box.totals, "Totals", "total-row")));
  }
}
