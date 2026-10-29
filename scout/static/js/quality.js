// Data quality panel: how much to trust the numbers (court mapping, jersey matching,
// ball tracking, pipeline warnings) and where to fix things.

import { byId, el, formatDuration, formatNumber, formatPct, setChildren } from "./ui.js";

const SEVERITY_KIND = { info: "info", warning: "warning", error: "error" };

function fact(label, value) {
  return el("li", {}, el("span", { text: label }), el("strong", { text: value }));
}

/** "scouted:#14" -> "Central #14". */
function unmatchedLabel(code, teamNames) {
  const [side, jersey] = String(code).split(":");
  return teamNames[side] ? `${teamNames[side]} ${jersey || ""}`.trim() : code;
}

/**
 * Free throws are found on the GPU, so Re-run analysis can't add them: once the court is
 * calibrated, a full re-analysis (the film goes to the GPU again) can. The warning's own
 * message says what to do; this is the button for it.
 */
function fullRunAction(game, onFullAnalysis) {
  if (!game.calibration || !onFullAnalysis) return null; // calibrate first / no film to send
  const busy = game.status === "queued" || game.status === "processing";
  return el("div", { class: "notice-actions" }, el("button", {
    type: "button",
    class: "btn-primary",
    text: "Full re-analysis",
    disabled: busy,
    title: busy ? "An analysis is already running" : "Send the film to the GPU again",
    onClick: (e) => onFullAnalysis(e.currentTarget),
  }));
}

export function renderQuality({ analysis, game, teamNames, onCalibrate, onFullAnalysis = null }) {
  const q = analysis.data_quality || {};
  const video = analysis.video || {};
  const pipeline = analysis.pipeline || {};
  const rosterUrl = `/games/${encodeURIComponent(game.id)}/roster#tracks`;
  const calibration = game.calibration
    ? `Manual calibration saved (average error ${formatNumber(game.calibration.reprojection_error_ft, 1)} ft)`
    : null;

  const facts = el("ul", { class: "status-list" },
    fact("Court mapped", q.homography_available ? "Yes" : "No (zones are estimates)"),
    fact("Coordinates", q.coord_mode === "court" ? "Court feet" : "Video pixels only"),
    fact("Jersey match rate", formatPct(q.jersey_match_rate, 0)),
    fact("Tracks assigned", `${q.tracks_assigned ?? 0} of ${q.tracks_total ?? 0}`),
    fact("Ball visible", `${formatPct(q.ball_coverage, 0)} of frames`),
    fact("Average event confidence", formatPct(q.event_confidence_mean, 0)),
    fact("Film", video.width ? `${video.width}×${video.height}, ${formatNumber(video.fps, 0)} fps, ${formatDuration(video.duration_s)}` : "–"),
    fact("Pipeline", [pipeline.name || "?", pipeline.version, pipeline.gpu ? `on ${pipeline.gpu}` : null].filter(Boolean).join(" ")));

  const unmatched = q.unmatched_jerseys || [];
  const warnings = q.warnings || [];
  setChildren(byId("quality-body"),
    facts,
    calibration ? el("p", { class: "small", text: calibration }) : null,
    q.homography_available ? null : el("div", { class: "notice notice-info" },
      el("strong", { class: "notice-title", text: "The court was not mapped" }),
      el("p", { text: "Shot locations and zones are approximate. If the camera does not move (a fixed gym camera), you can map the court yourself." }),
      el("div", { class: "notice-actions" }, el("button", { type: "button", text: "Calibrate court", onClick: onCalibrate }))),
    el("h3", { class: "section-sub", text: "Jerseys not on a roster" }),
    unmatched.length
      ? el("div", {},
        el("p", { class: "row" }, unmatched.map((code) => el("span", { class: `chip chip-${String(code).split(":")[0]}`, text: unmatchedLabel(code, teamNames) }))),
        el("p", {}, el("a", { href: rosterUrl, text: "Add these players or fix jersey assignments on the roster page" })))
      : el("p", { class: "muted", text: "Every jersey read matched a roster player." }),
    el("h3", { class: "section-sub", text: "Warnings from the analysis" }),
    warnings.length
      ? warnings.map((w) => el("div", { class: `notice notice-${SEVERITY_KIND[w.severity] || "warning"}`, role: "status" },
        el("strong", { class: "notice-title", text: w.message }),
        el("p", { class: "notice-hint", text: w.code }),
        w.code === "FREE_THROWS_NOT_DETECTED" ? fullRunAction(game, onFullAnalysis) : null))
      : el("p", { class: "muted", text: "No warnings." }));
}
