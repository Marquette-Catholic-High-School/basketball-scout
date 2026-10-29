// Games list + system status (GET /api/games, GET /api/health).

import { api, gamePath, jobPath } from "./api.js";
import { resolveColor } from "./colors.js";
import { STATUS_LABELS, WORKER_STALE_S, jobStageText, workerWarning } from "./labels.js";
import { byId, el, setChildren, showError, clearError, formatDate, formatAgo, toast, withBusy } from "./ui.js";

const REFRESH_MS = 5000;
let refreshTimer = null;

const isGameActive = (game) => game.status === "queued" || game.status === "processing";

async function loadGames() {
  clearTimeout(refreshTimer);
  const list = byId("games-list");
  try {
    const games = await api.get("/api/games");
    const jobs = await loadActiveJobs(games);
    renderGames(games, jobs);
    clearError(byId("page-error"));
    const active = games.some(isGameActive);
    byId("games-refresh-note").textContent = active ? "Updating every 5 seconds while film is processing" : "";
    if (active) refreshTimer = setTimeout(loadGames, REFRESH_MS);
  } catch (err) {
    showError(byId("page-error"), err, [el("button", { type: "button", text: "Try again", onClick: loadGames })]);
    if (err.info?.retryable) refreshTimer = setTimeout(loadGames, REFRESH_MS * 2);
  } finally {
    list.setAttribute("aria-busy", "false");
  }
}

/** Latest job for every game that is queued/processing, keyed by game id. */
async function loadActiveJobs(games) {
  const active = games.filter((g) => isGameActive(g) && g.latest_job_id);
  const results = await Promise.allSettled(active.map((g) => api.get(jobPath(g.latest_job_id))));
  const jobs = new Map();
  results.forEach((result, i) => {
    if (result.status === "fulfilled") jobs.set(active[i].id, result.value);
  });
  return jobs;
}

function renderGames(games, jobs) {
  const list = byId("games-list");
  if (!games.length) {
    setChildren(
      list,
      el("div", { class: "empty-state" },
        el("p", { text: "No games yet." }),
        el("a", { class: "btn btn-primary", href: "/upload", text: "Scout your first opponent" })),
    );
    return;
  }
  setChildren(list, games.map((game) => gameCard(game, jobs.get(game.id))));
}

function gameCard(game, job) {
  const url = `/games/${encodeURIComponent(game.id)}`;
  const color = resolveColor(game.scouted_color);
  const meta = [
    game.game_date ? el("span", { text: formatDate(game.game_date) }) : null,
    game.level ? el("span", { text: game.level }) : null,
    game.location ? el("span", { text: game.location }) : null,
    game.video_filename ? el("span", { text: `Film: ${game.video_filename}` }) : null,
  ];
  return el(
    "article",
    { class: "card game-card", style: color ? { "--game-color": color } : null, "aria-label": game.display_title },
    el("div", {},
      el("h3", {}, el("a", { href: url, text: game.display_title })),
      el("div", { class: "game-meta" },
        el("span", { class: `badge badge-${game.status}`, text: STATUS_LABELS[game.status] || game.status }),
        game.error ? el("span", { class: "badge badge-failed", text: game.error.title }) : null,
        meta),
      game.error ? el("p", { class: "small muted", text: [game.error.message, game.error.hint].filter(Boolean).join(" ") }) : null),
    el("div", { class: "game-actions" },
      el("a", { class: "btn btn-small", href: url, text: "Open" }),
      el("a", { class: "btn btn-small", href: `${url}/roster`, text: "Roster" }),
      game.has_video || game.video_url ? null : el("a", { class: "btn btn-small", href: `/upload?game=${encodeURIComponent(game.id)}`, text: "Add film" }),
      el("button", { type: "button", class: "btn-small btn-danger", text: "Delete", onClick: (e) => deleteGame(game, e.currentTarget) })),
    isGameActive(game) ? progressBlock(job) : null,
  );
}

function progressBlock(job) {
  const pct = job ? Math.round(job.progress || 0) : 0;
  const bar = el("div", { class: `progress${job ? "" : " progress-indeterminate"}`, role: "progressbar", "aria-valuemin": "0", "aria-valuemax": "100", "aria-valuenow": String(pct), "aria-label": "Processing progress" },
    el("span", { style: { width: `${pct}%` } }));
  return el("div", { class: "game-progress" },
    el("div", { class: "progress-text", text: job ? `${jobStageText(job)} · ${pct}%${job.message ? ` · ${job.message}` : ""}` : "Waiting for the worker…" }),
    bar);
}

async function deleteGame(game, button) {
  const ok = window.confirm(`Delete "${game.display_title}"?\n\nThis removes the film, analysis, rosters and reports for this game. It cannot be undone.`);
  if (!ok) return;
  await withBusy(button, "Deleting…", async () => {
    try {
      await api.del(gamePath(game.id));
      toast(`Deleted ${game.display_title}`);
      await loadGames();
    } catch (err) {
      showError(byId("page-error"), err);
    }
  });
}

// ---------------------------------------------------------------------------
// System status
// ---------------------------------------------------------------------------

function statusItem(label, value, ok) {
  return el("li", {},
    el("span", { text: label }),
    el("span", { class: ok === undefined ? "" : ok ? "status-ok" : "status-bad", text: value }));
}

/** Plain-English warnings for the coach / IT person: [kind, message, hint]. */
function healthWarnings(h) {
  const warnings = [workerWarning(h)].filter(Boolean);
  if (!h.queue_ok) warnings.push(["error", `The job queue (${h.queue_backend}) is not reachable.`, "Start Redis (sudo systemctl start redis-server) or set SCOUT_QUEUE_BACKEND=sqlite in .env."]);
  if (h.processor === "modal" && !h.modal_configured) warnings.push(["error", "Modal (the GPU service) is not configured, so film cannot be analyzed.", "Run modal token new on the server (or set MODAL_TOKEN_ID / MODAL_TOKEN_SECRET in .env), then restart the worker."]);
  if (h.processor === "mock") warnings.push(["info", "Demo mode: SCOUT_PROCESSOR=mock creates made-up results instead of analyzing the film.", "Set SCOUT_PROCESSOR=modal in .env for real analysis."]);
  if (!h.claude_configured) warnings.push(["warning", "Claude is not configured, so scouting reports can't be written.", "Add ANTHROPIC_API_KEY to .env and restart the worker. Stats and exports still work."]);
  if (!h.ffmpeg_available) warnings.push(["warning", "ffmpeg is not installed on the server, so uploaded film can't be checked before processing.", "Install it with: sudo apt install ffmpeg"]);
  return warnings;
}

async function loadHealth() {
  const list = byId("health-list");
  const warningsBox = byId("health-warnings");
  try {
    const h = await api.get("/api/health");
    setChildren(list,
      statusItem("Overall", h.status === "ok" ? "OK" : "Needs attention", h.status === "ok"),
      statusItem("Version", h.version),
      statusItem("Video processor", h.processor),
      statusItem("Job queue", `${h.queue_backend} ${h.queue_ok ? "OK" : "down"}`, h.queue_ok),
      statusItem("Modal (GPU)", h.modal_configured ? "Configured" : "Not configured", h.processor !== "modal" || h.modal_configured),
      statusItem("Claude reports", h.claude_configured ? "Configured" : "Not configured", h.claude_configured),
      statusItem("Worker last seen", formatAgo(h.worker_last_seen_s), h.worker_last_seen_s !== null && h.worker_last_seen_s <= WORKER_STALE_S),
      statusItem("ffmpeg", h.ffmpeg_available ? "Installed" : "Missing", h.ffmpeg_available));
    setChildren(warningsBox, healthWarnings(h).map(([kind, message, hint]) => el("div", { class: `notice notice-${kind}`, role: kind === "error" ? "alert" : "status" },
      el("strong", { class: "notice-title", text: message }),
      el("p", { class: "notice-hint", text: hint }))));
  } catch (err) {
    list.replaceChildren();
    showError(warningsBox, err);
  }
}

byId("health-refresh").addEventListener("click", (e) => withBusy(e.currentTarget, "Checking…", loadHealth));
loadGames();
loadHealth();
