// Court geometry for drawing (mirrors scout/analysis/geometry.py, NFHS defaults).
// Court feet: x along the length from the LEFT baseline, y across from the NEAR sideline.
// Lines are returned as polylines {points: [[x, y], ...], dashed?: true}.

import { el } from "./ui.js";

const DEFAULT_COURT = {
  length_ft: 84,
  width_ft: 50,
  basket_from_baseline_ft: 5.25,
  lane_width_ft: 12,
  ft_line_from_baseline_ft: 19,
  three_pt_radius_ft: 19.75,
  three_pt_corner_lateral_ft: 19.75,
  restricted_radius_ft: 4,
  ft_circle_radius_ft: 6,
  center_circle_radius_ft: 6,
  corner_three_max_depth_ft: 10,
};

/** Merge the server's court config over the defaults (missing keys keep NFHS values). */
export function courtConfig(raw) {
  const cfg = { ...DEFAULT_COURT };
  for (const key of Object.keys(DEFAULT_COURT)) {
    const value = Number(raw?.[key]);
    if (Number.isFinite(value) && value > 0) cfg[key] = value;
  }
  return cfg;
}

function arc(cx, cy, r, fromDeg, toDeg, stepDeg = 4) {
  const points = [];
  const steps = Math.max(2, Math.ceil(Math.abs(toDeg - fromDeg) / stepDeg));
  for (let i = 0; i <= steps; i += 1) {
    const a = ((fromDeg + ((toDeg - fromDeg) * i) / steps) * Math.PI) / 180;
    points.push([cx + r * Math.cos(a), cy + r * Math.sin(a)]);
  }
  return points;
}

/** Distance from the baseline where the straight corner 3-point segment meets the arc. */
export function cornerDepth(cfg) {
  const r = cfg.three_pt_radius_ft;
  const lat = cfg.three_pt_corner_lateral_ft;
  return cfg.basket_from_baseline_ft + Math.sqrt(Math.max(0, r * r - lat * lat));
}

/** Lines for the LEFT half of the court (the half-court chart uses the same frame). */
export function halfCourtLines(cfg) {
  const mid = cfg.width_ft / 2;
  const half = cfg.length_ft / 2;
  const lane = cfg.lane_width_ft / 2;
  const ft = cfg.ft_line_from_baseline_ft;
  const b = cfg.basket_from_baseline_ft;
  const r3 = cfg.three_pt_radius_ft;
  const lat = cfg.three_pt_corner_lateral_ft;
  const depth = cornerDepth(cfg);
  const arcAngle = (Math.asin(Math.min(1, lat / r3)) * 180) / Math.PI;
  return [
    { points: [[0, 0], [half, 0], [half, cfg.width_ft], [0, cfg.width_ft], [0, 0]] },
    { points: [[0, mid - lane], [ft, mid - lane], [ft, mid + lane], [0, mid + lane]] },
    { points: arc(ft, mid, cfg.ft_circle_radius_ft, -90, 90) },
    { points: arc(ft, mid, cfg.ft_circle_radius_ft, 90, 270), dashed: true },
    { points: [[0, mid - lat], [depth, mid - lat], ...arc(b, mid, r3, -arcAngle, arcAngle), [depth, mid + lat], [0, mid + lat]] },
    { points: arc(b, mid, cfg.restricted_radius_ft, -90, 90) },
    { points: [[4, mid - 3], [4, mid + 3]] },
    { points: arc(b, mid, 0.75, 0, 360, 30) },
    { points: arc(half, mid, cfg.center_circle_radius_ft, 90, 270) },
  ];
}

/** Both halves plus the centre circle, in full-court feet. */
export function fullCourtLines(cfg) {
  const left = halfCourtLines(cfg);
  const mirror = (line) => ({ ...line, points: line.points.map(([x, y]) => [cfg.length_ft - x, y]) });
  return [...left, ...left.map(mirror)];
}

/** SVG path data for a polyline through a mapping (feet -> SVG units). */
function pathData(line, map) {
  return line.points
    .map(([x, y], i) => {
      const [sx, sy] = map(x, y);
      return `${i ? "L" : "M"}${sx.toFixed(2)} ${sy.toFixed(2)}`;
    })
    .join(" ");
}

/** Append court lines to an SVG group. */
export function drawLines(group, lines, map, className = "court-line") {
  for (const line of lines) {
    group.append(el("path", { d: pathData(line, map), class: line.dashed ? `${className} court-line-dashed` : className }));
  }
}

// ---------------------------------------------------------------------------
// 3x3 matrix helpers (homographies)
// ---------------------------------------------------------------------------

/** Inverse of a 3x3 matrix (null when singular), normalised so m[2][2] = 1 when possible. */
export function invert3(m) {
  const [[a, b, c], [d, e, f], [g, h, i]] = m;
  const A = e * i - f * h;
  const B = -(d * i - f * g);
  const C = d * h - e * g;
  const det = a * A + b * B + c * C;
  if (!Number.isFinite(det) || Math.abs(det) < 1e-12) return null;
  const inv = [
    [A / det, -(b * i - c * h) / det, (b * f - c * e) / det],
    [B / det, (a * i - c * g) / det, -(a * f - c * d) / det],
    [C / det, -(a * h - b * g) / det, (a * e - b * d) / det],
  ];
  const s = inv[2][2];
  return Math.abs(s) > 1e-12 ? inv.map((row) => row.map((v) => v / s)) : inv;
}

/** Map a point through a homography; null when it lands at/behind the horizon. */
export function applyHomography(m, x, y) {
  const w = m[2][0] * x + m[2][1] * y + m[2][2];
  if (!Number.isFinite(w) || w <= 1e-9) return null;
  return [(m[0][0] * x + m[0][1] * y + m[0][2]) / w, (m[1][0] * x + m[1][1] * y + m[1][2]) / w];
}
