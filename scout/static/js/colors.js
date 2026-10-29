// Team colour helpers: turn "dark" / "light" / "#1a2b3c" / "navy" / [r, g, b] into CSS
// colours and pick readable text on top of them.

const PRESETS = { dark: "#1f2937", light: "#f3f4f6" };
const FALLBACK_SCOUTED = "#1f3a93";
const FALLBACK_OTHER = "#d1d5db";

let probe = null;

/** Normalise any CSS colour name to "#rrggbb" using a 1x1 canvas (null when invalid). */
function normalise(value) {
  probe = probe || document.createElement("canvas").getContext("2d");
  if (!probe) return null;
  probe.fillStyle = "#010203";
  probe.fillStyle = value;
  const result = probe.fillStyle;
  return result === "#010203" && value.toLowerCase() !== "#010203" ? null : result;
}

/** CSS colour for a scouted_color hint or colour word; null when unusable. */
export function resolveColor(value) {
  if (!value) return null;
  const text = String(value).trim().toLowerCase();
  if (PRESETS[text]) return PRESETS[text];
  if (/^#[0-9a-f]{3}([0-9a-f]{3})?$/.test(text) || /^[a-z]{3,24}$/.test(text)) return normalise(text);
  return null;
}

function rgbToCss(rgb) {
  if (!Array.isArray(rgb) || rgb.length < 3) return null;
  return `#${rgb.slice(0, 3).map((v) => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, "0")).join("")}`;
}

function luminance(hex) {
  const n = parseInt(hex.slice(1), 16);
  const channel = (c) => {
    const s = c / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel((n >> 16) & 255) + 0.7152 * channel((n >> 8) & 255) + 0.0722 * channel(n & 255);
}

/** True for light colours ("#rrggbb" only), which need dark text on top. */
export function isLight(hex) {
  return Boolean(hex && /^#[0-9a-f]{6}$/i.test(hex) && luminance(hex) > 0.4);
}

/** Black or white text, whichever reads better on the colour. */
function inkFor(hex) {
  return isLight(hex) ? "#111827" : "#ffffff";
}

/** Colour for one TeamSummary (jersey colour from the film) with a fallback. */
export function teamColor(team, fallback) {
  return rgbToCss(team?.color_rgb) || resolveColor(team?.color_name) || fallback;
}

/**
 * Set --scouted / --other (and their -ink text colours) on the page from the game's
 * colour hint and, when an analysis exists, the detected jersey colours.
 */
export function applyTeamColors(game, teams = []) {
  const scoutedTeam = teams.find((t) => t.side === "scouted");
  const otherTeam = teams.find((t) => t.side === "other");
  const hint = resolveColor(game?.scouted_color);
  const scouted = teamColor(scoutedTeam, hint || FALLBACK_SCOUTED);
  let other = teamColor(otherTeam, null);
  if (!other) other = isLight(scouted) ? "#1f2937" : FALLBACK_OTHER;
  const root = document.documentElement.style;
  root.setProperty("--scouted", scouted);
  root.setProperty("--scouted-ink", inkFor(scouted));
  root.setProperty("--other", other);
  root.setProperty("--other-ink", inkFor(other));
  return { scouted, other };
}
