// Shot chart: SVG half court (basket at the top) with made (dot) / missed (x) shots
// from ShotRecord.half_court_xy = [feet from the attacked baseline, feet from the
// offense's left sideline]. Hover for details, click to watch the shot.

import { courtConfig, drawLines, halfCourtLines } from "./court.js";
import { ZONE_LABELS } from "./labels.js";
import { PREROLL_S } from "./player.js";
import { humanize, playerKey } from "./timeline.js";
import { byId, el, formatClock, formatPct, notice, setChildren } from "./ui.js";

const ZONES = ["paint", "mid", "three", "unknown"];
/** Depth (feet from the baseline) of each zone's FG% label, centred across the court. */
const LABEL_DEPTH = { paint: 11, mid: 22.5, three: 31 };

function zoneSplit(shots) {
  const split = Object.fromEntries(ZONES.map((z) => [z, { made: 0, attempts: 0 }]));
  for (const shot of shots) {
    const zone = split[shot.zone] ? shot.zone : "unknown";
    split[zone].attempts += 1;
    if (shot.made) split[zone].made += 1;
  }
  return split;
}

const pct = (s) => (s.attempts ? s.made / s.attempts : null);

export class ShotChart {
  constructor({ player }) {
    this.player = player;
    this.chart = byId("shot-chart");
    this.tip = byId("shot-tip");
    this.shots = [];
    this.visible = [];
    this.teamNames = {};
    this.cfg = courtConfig(null);
    byId("shot-team").addEventListener("change", () => {
      this.buildPlayerOptions();
      this.draw();
    });
    byId("shot-player").addEventListener("change", () => this.draw());
    byId("shot-result").addEventListener("change", () => this.draw());
    this.chart.addEventListener("mouseover", (e) => this.onHover(e));
    this.chart.addEventListener("mouseout", (e) => {
      if (e.target.classList?.contains("shot-hit")) this.tip.hidden = true;
    });
    this.chart.addEventListener("click", (e) => {
      const shot = this.shotFor(e.target);
      if (shot) this.player.seek(shot.t - PREROLL_S, { reveal: true });
    });
  }

  render(analysis, court, teamNames) {
    this.cfg = courtConfig(court);
    this.shots = analysis.shots || [];
    this.teamNames = teamNames;
    this.courtMapped = Boolean(analysis.data_quality?.homography_available);
    const team = byId("shot-team");
    const current = team.value || "scouted";
    setChildren(team,
      el("option", { value: "scouted", text: teamNames.scouted }),
      el("option", { value: "other", text: teamNames.other }),
      el("option", { value: "", text: "Both teams" }));
    team.value = current;
    this.buildPlayerOptions();
    this.draw();
  }

  teamShots() {
    const side = byId("shot-team").value;
    return side ? this.shots.filter((s) => s.side === side) : this.shots;
  }

  buildPlayerOptions() {
    const select = byId("shot-player");
    const current = select.value;
    const players = new Map();
    for (const shot of this.teamShots()) if (shot.player) players.set(playerKey(shot.player), shot.player);
    const sorted = [...players.entries()].sort(([, a], [, b]) => (Number(a.jersey) || 999) - (Number(b.jersey) || 999));
    setChildren(select, el("option", { value: "", text: "All players" }), sorted.map(([key, ref]) => el("option", { value: key, text: ref.label })));
    if (players.has(current)) select.value = current;
  }

  draw() {
    const player = byId("shot-player").value;
    const result = byId("shot-result").value;
    const pool = this.teamShots().filter((s) => !player || playerKey(s.player) === player);
    this.visible = pool.filter((s) => (result === "made" ? s.made : result === "missed" ? !s.made : true));
    const located = this.visible.filter((s) => Array.isArray(s.half_court_xy));
    const split = zoneSplit(pool);
    setChildren(this.chart, this.svg(located, split));
    this.renderZoneTable(split, pool.length);
    const missing = this.visible.length - located.length;
    const note = byId("shot-note");
    if (!this.shots.length) {
      setChildren(note, "No shots were detected in this film.");
    } else if (!located.length && this.visible.length) {
      setChildren(note, notice("info", "No shot locations", "The court wasn't mapped in this film, so shots can't be placed on the chart.", "For a fixed camera, use Calibrate court under the video and re-run the analysis."));
    } else {
      setChildren(note, missing ? `${missing} shot${missing === 1 ? "" : "s"} without a court location ${missing === 1 ? "is" : "are"} not drawn.` : "");
    }
  }

  svg(shots, split) {
    const cfg = this.cfg;
    const half = cfg.length_ft / 2;
    const width = cfg.width_ft;
    const mid = width / 2;
    const map = (x, y) => [y, x];
    const made = shots.filter((s) => s.made).length;
    const svg = el("svg", {
      viewBox: `-1 -1 ${width + 2} ${half + 2}`,
      role: "img",
      "aria-label": `Shot chart: ${shots.length} shots drawn, ${made} made. The zone table lists the same numbers.`,
    });
    const lines = el("g", {});
    drawLines(lines, halfCourtLines(cfg), map);
    svg.append(lines);

    const marks = el("g", {});
    shots.forEach((shot) => {
      const hx = Math.max(0, Math.min(half + 0.5, shot.half_court_xy[0]));
      const hy = Math.max(0, Math.min(width, shot.half_court_xy[1]));
      const [x, y] = map(hx, hy);
      const r = 0.55;
      const mark = shot.made
        ? el("circle", { class: "shot-mark shot-made", cx: x, cy: y, r: 0.65 })
        : el("path", { class: "shot-mark shot-missed", d: `M${x - r} ${y - r}L${x + r} ${y + r}M${x - r} ${y + r}L${x + r} ${y - r}` });
      marks.append(mark, el("circle", { class: "shot-hit", cx: x, cy: y, r: 1.2, "data-i": String(this.visible.indexOf(shot)) }));
    });
    svg.append(marks);

    // Zone labels go on top of the marks (they ignore the mouse so shots stay clickable).
    for (const zone of ["paint", "mid", "three"]) {
      const s = split[zone];
      const hx = LABEL_DEPTH[zone];
      const text = `${ZONE_LABELS[zone]} ${s.made}/${s.attempts}${s.attempts ? ` · ${formatPct(pct(s), 0)}` : ""}`;
      const labelWidth = text.length * 0.85 + 1;
      svg.append(el("g", { class: "zone-label", "aria-hidden": "true" },
        el("rect", { x: mid - labelWidth / 2, y: hx - 1.2, width: labelWidth, height: 2.4, rx: 0.6 }),
        el("text", { x: mid, y: hx + 0.1, text })));
    }
    return svg;
  }

  renderZoneTable(split, total) {
    const rows = ZONES.map((zone) => {
      const s = split[zone];
      return el("tr", {},
        el("th", { scope: "row", text: zone === "unknown" ? "Unknown zone" : ZONE_LABELS[zone] }),
        el("td", { class: "num", text: `${s.made}-${s.attempts}` }),
        el("td", { class: "num", text: formatPct(pct(s)) }),
        el("td", { class: "num", text: total ? formatPct(s.attempts / total, 0) : "–" }));
    });
    const all = ZONES.reduce((acc, z) => ({ made: acc.made + split[z].made, attempts: acc.attempts + split[z].attempts }), { made: 0, attempts: 0 });
    setChildren(byId("shot-zones"), el("table", { class: "table-compact" },
      el("thead", {}, el("tr", {}, ["Zone", "FG", "FG%", "Share"].map((h, i) => el("th", { scope: "col", class: i ? "num" : null, text: h })))),
      el("tbody", {}, rows),
      el("tfoot", {}, el("tr", {},
        el("th", { scope: "row", text: "All shots" }),
        el("td", { class: "num", text: `${all.made}-${all.attempts}` }),
        el("td", { class: "num", text: formatPct(pct(all)) }),
        el("td", { class: "num", text: total ? "100%" : "–" })))));
  }

  shotFor(target) {
    if (!target.classList?.contains("shot-hit")) return null;
    return this.visible[Number(target.getAttribute("data-i"))] || null;
  }

  onHover(e) {
    const shot = this.shotFor(e.target);
    if (!shot) return;
    const wrap = this.chart.parentElement.getBoundingClientRect();
    const dot = e.target.getBoundingClientRect();
    const kind = `${shot.is_three ? "3PT" : "2PT"} ${shot.made ? "make" : "miss"}`;
    const extras = [shot.subzone ? humanize(shot.subzone) : ZONE_LABELS[shot.zone], shot.assisted ? "assisted" : null, shot.blocked ? "blocked" : null];
    this.tip.textContent = [shot.player?.label || "Unknown player", kind, formatClock(shot.t), ...extras].filter(Boolean).join(" · ");
    this.tip.style.left = `${dot.left + dot.width / 2 - wrap.left}px`;
    this.tip.style.top = `${dot.top - wrap.top}px`;
    this.tip.hidden = false;
  }
}
