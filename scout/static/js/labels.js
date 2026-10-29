// Display names for the enums in scout/schemas.py (kept in sync by hand).

import { formatAgo } from "./ui.js";

export const EVENT_TYPE_LABELS = {
  shot_made: "Made shot",
  shot_missed: "Missed shot",
  ft_made: "Free throw made",
  ft_missed: "Free throw missed",
  oreb: "Offensive rebound",
  dreb: "Defensive rebound",
  assist: "Assist",
  steal: "Steal",
  block: "Block",
  turnover: "Turnover",
  foul: "Foul",
  screen: "Screen",
  pass: "Pass",
  jump_ball: "Jump ball",
  period_start: "Period start",
  period_end: "Period end",
  timeout: "Timeout",
  possession_change: "Possession change",
};

/** Marker / legend groups: event type -> category used for colours. */
export const EVENT_CATEGORY = {
  shot_made: "make",
  ft_made: "make",
  shot_missed: "miss",
  ft_missed: "miss",
  oreb: "rebound",
  dreb: "rebound",
  assist: "assist",
  steal: "defense",
  block: "defense",
  turnover: "turnover",
  foul: "foul",
  screen: "other",
  pass: "other",
  jump_ball: "game",
  period_start: "game",
  period_end: "game",
  timeout: "game",
  possession_change: "other",
};

export const CATEGORY_LABELS = {
  make: "Makes",
  miss: "Misses",
  rebound: "Rebounds",
  assist: "Assists",
  defense: "Steals / blocks",
  turnover: "Turnovers",
  foul: "Fouls",
  game: "Game events",
  other: "Other",
};

/** Event types left off the video marker strip unless the coach filters for them. */
export const NOISY_EVENT_TYPES = new Set(["pass", "possession_change", "screen"]);

export const PLAY_TYPE_LABELS = {
  pick_and_roll: "Pick & Roll",
  pick_and_pop: "Pick & Pop",
  isolation: "Isolation",
  fast_break: "Fast Break",
  post_up: "Post-Up",
  handoff: "Dribble Handoff",
  off_ball_screen: "Off-Ball Screen",
  spot_up: "Spot-Up",
  cut: "Cut",
  putback: "Putback",
  man_defense: "Man-to-Man Defense",
  zone_defense: "Zone Defense",
  press: "Full-Court Press",
};

export const PLAY_OUTCOME_LABELS = {
  made_fg: "Made FG",
  missed_fg: "Missed FG",
  turnover: "Turnover",
  foul: "Foul",
  no_shot: "No shot",
  unknown: "–",
};

export const ZONE_LABELS = {
  paint: "Paint",
  mid: "Mid-range",
  three: "3-point",
  unknown: "Unknown",
};

/** Play.players roles (scout/analysis/plays.py). */
export const ROLE_LABELS = {
  ball_handler: "Ball handler",
  screener: "Screener",
  post_player: "Post",
  cutter: "Cutter",
  shooter: "Shooter",
  passer: "Passer",
  receiver: "Receiver",
  defender: "Defender",
  rebounder: "Rebounder",
};

export const STATUS_LABELS = {
  draft: "No film",
  uploaded: "Film uploaded",
  queued: "Queued",
  processing: "Processing",
  ready: "Ready",
  failed: "Failed",
};

const STAGE_LABELS = {
  queued: "Waiting for the background worker",
  preparing: "Preparing the film",
  uploading_to_gpu: "Uploading film to the GPU",
  gpu_processing: "Analyzing on the GPU",
  downloading_results: "Downloading results from the GPU",
  analyzing: "Building box score",
  reporting: "Writing scouting report",
  done: "Finished",
};

const JOB_KIND_LABELS = { analyze: "Film analysis", reanalyze: "Re-analysis", report: "Scouting report" };

export function jobKindLabel(kind) {
  return JOB_KIND_LABELS[kind] || "Job";
}

/** Plain-English job stage, e.g. "Analyzing on the GPU (42%)". */
export function jobStageText(job) {
  if (!job) return "";
  if (job.status === "succeeded") return "Finished";
  if (job.status === "failed") return "Failed";
  if (job.status === "cancelled") return "Cancelled";
  if (job.cancel_requested) return "Cancelling…";
  if (job.kind === "report" && job.stage !== "queued") return STAGE_LABELS.reporting;
  const label = STAGE_LABELS[job.stage] || "Working";
  return job.stage === "gpu_processing" ? `${label} (${Math.round(job.progress || 0)}%)` : label;
}

/** A worker heartbeat older than this means the worker has probably stopped (as GET /api/health). */
export const WORKER_STALE_S = 120;

/**
 * [kind, message, hint] when the background worker is not running (h: HealthStatus), else
 * null. The games list and a game whose job waits in the queue show the same notice.
 */
export function workerWarning(h) {
  if (h.worker_last_seen_s === null || h.worker_last_seen_s === undefined) {
    return ["error", "The background worker is not running - start basketball-scout-worker.", "On the server: sudo systemctl start basketball-scout-worker (or run python -m scout.worker). Film will wait in the queue until it runs."];
  }
  if (h.worker_last_seen_s > WORKER_STALE_S) {
    return ["error", `The background worker was last seen ${formatAgo(h.worker_last_seen_s)} - it may have stopped.`, "Check it with: sudo systemctl status basketball-scout-worker"];
  }
  return null;
}

/** Short team name for chips: "North Bay" stays, "Central Catholic" -> "Central", "St. Mary's Prep" -> "SMP". */
export function shortTeamName(name, max = 12) {
  const text = String(name || "").trim();
  if (text.length <= max) return text;
  const words = text.split(/\s+/);
  const first = words[0].replace(/[^\w'-]/g, "");
  if (first.length >= 4 && first.length <= max) return first;
  return words.map((w) => w[0]).join("").toUpperCase().slice(0, 4);
}

/** Two or three letter abbreviation: "Central Catholic" -> "CC", "Lincoln" -> "LIN". */
export function teamAbbr(name) {
  const words = String(name || "").replace(/[^\w\s]/g, "").split(/\s+/).filter(Boolean);
  if (!words.length) return "?";
  return (words.length > 1 ? words.map((w) => w[0]).join("") : words[0].slice(0, 3)).toUpperCase().slice(0, 3);
}

/** Friendly name for a court landmark key such as "left_ft_line_near". */
const LANDMARK_PARTS = {
  baseline_near_corner: "baseline, near corner",
  baseline_far_corner: "baseline, far corner",
  lane_baseline_near: "lane meets baseline (near side)",
  lane_baseline_far: "lane meets baseline (far side)",
  ft_line_near: "free-throw line, near elbow",
  ft_line_far: "free-throw line, far elbow",
  ft_circle_top: "top of the free-throw circle",
  three_corner_near: "3-point line meets baseline (near corner)",
  three_corner_far: "3-point line meets baseline (far corner)",
  three_top: "top of the 3-point arc",
  midcourt_near: "Half-court line at the near sideline",
  midcourt_far: "Half-court line at the far sideline",
  center: "Center of the court",
  center_circle_near: "Center circle, near side",
  center_circle_far: "Center circle, far side",
};

export function landmarkLabel(name) {
  const end = name.startsWith("left_") ? "Left end" : name.startsWith("right_") ? "Right end" : null;
  const key = end ? name.replace(/^(left|right)_/, "") : name;
  const part = LANDMARK_PARTS[key] || key.replaceAll("_", " ");
  return end ? `${end}: ${part}` : part;
}
