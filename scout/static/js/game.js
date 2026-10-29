// Game results page: loads the game, its latest jobs and analysis, then hands the data
// to the video player, timeline, box score, shot chart, plays, report, exports,
// data-quality panel and court calibration.

import { api, gamePath, isJobActive, jobPath } from "./api.js";
import { BoxScore } from "./boxscore.js";
import { Calibration } from "./calibrate.js";
import { applyTeamColors, isLight, luminance, teamColor } from "./colors.js";
import { Exports } from "./exports.js";
import { JobPanel } from "./jobpanel.js";
import { STATUS_LABELS } from "./labels.js";
import { Player } from "./player.js";
import { Plays } from "./plays.js";
import { renderQuality } from "./quality.js";
import { Report } from "./report.js";
import { ShotChart } from "./shotchart.js";
import { Timeline } from "./timeline.js";
import {
  byId, clearError, el, errorBox, formatDate, gameIdFromPath, notice, setChildren, setupTabs, show, showError,
  storageGet, storageSet, toast, withBusy,
} from "./ui.js";

const TAB_KEY = "scout.gameTab";
const FULL_RUN_CONFIRM = "Send the film to the GPU again?\n\n"
  + "A full re-analysis takes about as long as the first run and costs another GPU run. "
  + "The current results stay on this page until it finishes.\n\n"
  + "(Re-run analysis only redoes the stats on this server.)";
const gameId = gameIdFromPath();
// filmRenewed: a GPU run finished while the page was open, so the annotated copy is a new file.
const state = { game: null, analysis: null, court: null, health: null, filmRenewed: false };
const parts = {};
let refreshes = 0; // only the newest refresh() may draw the page

/** Film the GPU can analyse: an uploaded file or a video link. */
const hasFilm = (game) => Boolean(game.has_video || game.video_url);

/** The GPU could not find free throws (no court positions); a GPU run with a calibration can. */
const freeThrowsMissing = (analysis) => Boolean(analysis?.data_quality?.warnings?.some((w) => w.code === "FREE_THROWS_NOT_DETECTED"));

/**
 * An ANALYZE job that got past the GPU installed a new annotated copy (same URL): it succeeded,
 * or failed afterwards (the server's rule for retrying it as a REANALYZE, which keeps that copy).
 */
const replacedAnnotatedCopy = (job) => job?.kind === "analyze"
  && (job.status === "succeeded" || (job.status === "failed" && ["analyzing", "reporting"].includes(job.stage)));

function teamNames(game, analysis) {
  const name = (side) => analysis?.teams?.find((t) => t.side === side)?.name;
  return {
    scouted: name("scouted") || game.scouted_team || "Scouted team",
    other: name("other") || game.other_team || "Opponent",
  };
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

async function loadAnalysis() {
  try {
    return await api.get(gamePath(gameId, "/analysis"));
  } catch (err) {
    if (err.code !== "ANALYSIS_NOT_READY") showError(byId("page-error"), err);
    return null;
  }
}

/** Newest jobs: {analysis: latest analyze/reanalyze job, report: active report job}. */
async function loadJobs(game) {
  try {
    const jobs = await api.get(gamePath(gameId, "/jobs"));
    return {
      analysis: jobs.find((j) => j.kind !== "report") || null,
      report: jobs.find((j) => j.kind === "report" && isJobActive(j)) || null,
    };
  } catch {
    const latest = game.latest_job_id ? await api.get(jobPath(game.latest_job_id)).catch(() => null) : null;
    return { analysis: latest?.kind === "report" ? null : latest, report: null };
  }
}

async function loadOnce(key, path) {
  if (!state[key]) state[key] = await api.get(path).catch(() => null);
  return state[key];
}

async function refresh() {
  // A slow refresh (a big analysis.json) must not repaint the page after a newer one,
  // e.g. "Queued" after the job it was started for has already finished.
  const token = ++refreshes;
  let game;
  try {
    game = await api.get(gamePath(gameId));
  } catch (err) {
    if (token !== refreshes) return;
    showError(byId("page-error"), err, [
      err.info?.retryable ? el("button", { type: "button", text: "Try again", onClick: refresh }) : null,
      el("a", { class: "btn", href: "/", text: "Back to games" }),
    ].filter(Boolean));
    return;
  }
  if (token !== refreshes) return;
  clearError(byId("page-error"));
  state.game = game;
  const [analysis, jobs, court, health] = await Promise.all([
    game.has_analysis ? loadAnalysis() : null,
    loadJobs(game),
    loadOnce("court", "/api/court/landmarks"),
    loadOnce("health", "/api/health"),
  ]);
  if (token !== refreshes) return;
  state.analysis = analysis;
  applyTeamColors(game, analysis?.teams || []);
  const names = teamNames(game, analysis);

  renderHeader(game, names);
  parts.jobPanel.show(jobs.analysis);
  if (jobs.analysis) showJobStatus(jobs.analysis);
  renderTeamBanner(game, analysis);
  renderPending(game, analysis);
  renderFilmState(game, analysis);
  show(byId("timeline-card"), Boolean(analysis));
  byId("game-layout").classList.toggle("solo", !analysis);
  show(byId("analysis-tabs-wrap"), Boolean(analysis));

  parts.player.load({ hasVideo: game.has_video, hasAnnotated: game.has_annotated_video, renewed: state.filmRenewed });
  state.filmRenewed = false;
  parts.calibration.setup({
    court: court?.court,
    landmarks: court?.landmarks,
    calibration: game.calibration,
    fullRunAdvised: hasFilm(game) && freeThrowsMissing(analysis),
  });
  if (analysis) renderAnalysis(game, analysis, names, court);
  else parts.player.setData({ teamNames: names });
  if (analysis) parts.report.load(game, { activeJob: jobs.report, claudeConfigured: health?.claude_configured });
}

function renderAnalysis(game, analysis, names, court) {
  parts.player.setData({
    events: analysis.timeline,
    plays: analysis.plays,
    possessions: analysis.possessions,
    teamNames: names,
    duration: analysis.video?.duration_s || 0,
  });
  parts.timeline.render(analysis, names);
  parts.boxScore.render(analysis);
  parts.shotChart.render(analysis, court?.court, names);
  parts.plays.render(analysis, names);
  parts.exports.render(names);
  if (byId("tabbtn-exports").getAttribute("aria-selected") === "true") parts.exports.activate();
  renderQualityTab();
}

function renderQualityTab() {
  const { game, analysis } = state;
  renderQuality({
    analysis,
    game,
    teamNames: teamNames(game, analysis),
    onCalibrate: () => parts.calibration.open(),
    onFullAnalysis: hasFilm(game) ? startFullAnalysis : null,
  });
}

/**
 * Film present -> player (a film added as a link still has the annotated copy the GPU
 * made); nothing stored on this server -> explain why it can't play.
 */
function renderFilmState(game, analysis) {
  const playable = game.has_video || game.has_annotated_video;
  show(byId("no-film"), !game.has_video && !analysis && !game.video_url);
  show(byId("game-layout"), playable || Boolean(analysis));
  show(byId("player-main"), playable);
  const missing = byId("player-missing");
  show(missing, !playable && Boolean(analysis));
  if (playable || !analysis) return;
  const why = game.video_url ? "It was analyzed from a video link and isn't stored on this server" : "The film isn't stored on this server";
  setChildren(missing, notice("info", "Film not available", `${why}, so it can't be played here. The stats below still work.`),
    el("a", { class: "btn", href: `/upload?game=${encodeURIComponent(game.id)}`, text: "Upload the film" }));
}

/** What to tell the coach while there is film but no analysis to show yet. */
function renderPending(game, analysis) {
  const box = byId("analysis-pending");
  show(box, hasFilm(game) && !analysis);
  if (!hasFilm(game) || analysis) return;
  if (game.status === "failed" && game.error && byId("job-panel").hidden) {
    setChildren(box, errorBox({ info: game.error }));
    return;
  }
  const messages = {
    uploaded: ["This film hasn't been analyzed yet.", "Click Analyze film to send it to the GPU."],
    queued: ["Results will appear here when the analysis finishes.", "Long games can take 30-60 minutes on the GPU."],
    processing: ["Results will appear here when the analysis finishes.", "Long games can take 30-60 minutes on the GPU."],
    failed: ["There are no results because the analysis failed.", "See the error above and use Retry once the problem is fixed."],
    ready: ["The analysis could not be loaded.", "Reload the page; if it keeps happening, re-run the analysis."],
  };
  const [message, hint] = messages[game.status] || messages.uploaded;
  setChildren(box, notice("info", null, message, hint));
}

const rerunKind = () => (state.game?.has_analysis ? "reanalyze" : "analyze");

// ---------------------------------------------------------------------------
// Header, team confirmation, analysis actions
// ---------------------------------------------------------------------------

function renderHeader(game, names) {
  document.title = `${game.display_title} - Basketball Scout`;
  byId("game-title").textContent = game.display_title;
  setChildren(byId("game-meta"),
    el("span", { class: "teams-line" },
      el("span", { class: "chip chip-scouted", text: names.scouted }),
      "vs",
      el("span", { class: "chip chip-other", text: names.other })),
    game.game_date ? el("span", { text: formatDate(game.game_date) }) : null,
    game.level ? el("span", { text: game.level }) : null,
    game.location ? el("span", { text: game.location }) : null,
    el("span", { id: "game-status", class: `badge badge-${game.status}`, text: STATUS_LABELS[game.status] || game.status }));
  const rosterUrl = `/games/${encodeURIComponent(game.id)}/roster`;
  byId("roster-link").href = rosterUrl;
  byId("nav-roster").href = rosterUrl;
  const film = byId("film-link");
  film.href = `/upload?game=${encodeURIComponent(game.id)}`;
  film.textContent = hasFilm(game) ? "Replace film" : "Add film";
  byId("no-film-link").href = film.href;
  const busy = game.status === "queued" || game.status === "processing";
  const rerun = byId("reanalyze-btn");
  rerun.textContent = game.has_analysis ? "Re-run analysis" : "Analyze film";
  rerun.disabled = busy || !(hasFilm(game) || game.has_analysis);
  rerun.title = busy ? "An analysis is already running" : game.has_analysis ? "Redo the stats on this server (about a minute, no GPU)" : "";
  const full = byId("full-analysis-btn");
  show(full, hasFilm(game) && game.has_analysis);
  full.disabled = busy;
  full.title = busy ? "An analysis is already running" : "Send the film to the GPU again";
}

/** Header badge while the analysis job runs (the whole page reloads when it ends). */
function showJobStatus(job) {
  const badge = document.getElementById("game-status");
  if (!badge || !isJobActive(job)) return;
  const status = job.status === "running" ? "processing" : "queued";
  const pct = Math.round(job.progress || 0);
  badge.className = `badge badge-${status}`;
  badge.textContent = status === "processing" && pct ? `${STATUS_LABELS.processing} · ${pct}%` : STATUS_LABELS[status];
  for (const id of ["reanalyze-btn", "full-analysis-btn"]) {
    const button = byId(id);
    button.disabled = true;
    button.title = "An analysis is already running";
  }
}

/** POST a new analyze / reanalyze job and start tracking it. */
async function startJob(kind, started = null) {
  try {
    const job = await api.post(gamePath(gameId, "/jobs"), { kind });
    toast(started || (kind === "reanalyze" ? "Re-running the analysis…" : "Analysis started"));
    parts.jobPanel.track(job);
    await refresh();
  } catch (err) {
    await refresh(); // shows the job that is already running, if that was the problem
    showError(byId("page-error"), err);
  }
}

/**
 * ANALYZE an analysed game again: the film goes back to the GPU, with the court
 * calibration (the only way to find free throws the first run missed). The old results
 * stay on the page until the new run finishes.
 */
async function startFullAnalysis(button) {
  if (!window.confirm(FULL_RUN_CONFIRM)) return;
  for (const b of [button, byId("reanalyze-btn"), byId("full-analysis-btn")]) if (b) b.disabled = true; // refresh() redraws them
  await startJob("analyze", "Full re-analysis started");
}

function colorWord(team) {
  if (team.color_name) return team.color_name.charAt(0).toUpperCase() + team.color_name.slice(1);
  return isLight(teamColor(team, "")) ? "Light" : "Dark";
}

/** "Navy jerseys" / "White jerseys"; two teams with the same colour word get "(lighter)" / "(darker)". */
function teamChoiceLabels(teams) {
  const words = teams.map(colorWord);
  if (words[0] !== words[1]) return words.map((word) => `${word} jerseys`);
  const shade = teams.map((team) => luminance(teamColor(team, "")));
  if (!(Math.abs(shade[0] - shade[1]) > 0.005)) return words.map((word, i) => `${word} jerseys (team ${i + 1})`);
  return words.map((word, i) => `${word} jerseys (${shade[i] > shade[1 - i] ? "lighter" : "darker"})`);
}

function renderTeamBanner(game, analysis) {
  const banner = byId("team-banner");
  const teams = (analysis?.teams || []).filter((t) => t.team_id !== null && t.team_id !== undefined && (t.color_rgb || t.color_name));
  const needed = teams.length === 2 && !Object.keys(game.team_id_map || {}).length;
  show(banner, needed);
  if (!needed) return;
  const labels = teamChoiceLabels(teams);
  setChildren(banner,
    el("h2", { text: `Which team is ${game.scouted_team}?` }),
    el("p", { class: "hint", text: "The analysis split the players by jersey colour. Pick the colour the scouted team wears in this film so every stat goes to the right team." }),
    el("div", { class: "row" }, teams.map((team, i) => el("button", {
      type: "button",
      class: "team-choice",
      onClick: (e) => confirmTeam(team, teams, e.currentTarget),
    }, el("span", { class: "swatch", style: { background: teamColor(team, "#888") }, "aria-hidden": "true" }), labels[i]))));
}

async function confirmTeam(chosen, teams, button) {
  const other = teams.find((t) => t !== chosen);
  const map = { [chosen.team_id]: "scouted", [other.team_id]: "other" };
  await withBusy(button, "Saving…", async () => {
    try {
      await api.patch(gamePath(gameId), { team_id_map: map });
      if (chosen.side === "scouted") {
        toast("Thanks - teams confirmed.");
        await refresh();
      } else {
        await startJob("reanalyze");
      }
    } catch (err) {
      showError(byId("page-error"), err);
    }
  });
}

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

function setupAnalysisTabs() {
  const saved = storageGet(TAB_KEY);
  const tabs = [...byId("analysis-tabs").querySelectorAll("[role=tab]")];
  if (tabs.some((t) => t.id === saved)) {
    for (const tab of tabs) tab.setAttribute("aria-selected", String(tab.id === saved));
  }
  setupTabs(byId("analysis-tabs"), (tab) => {
    storageSet(TAB_KEY, tab.id);
    if (tab.id === "tabbtn-exports" && state.analysis) parts.exports.activate();
  });
}

function init() {
  if (!gameId) {
    showError(byId("page-error"), { info: { title: "Game not found", message: "This address doesn't point to a game.", hint: "Open a game from the games list." } });
    return;
  }
  parts.player = new Player({ gameId });
  parts.timeline = new Timeline({ player: parts.player });
  parts.boxScore = new BoxScore();
  parts.shotChart = new ShotChart({ player: parts.player });
  parts.plays = new Plays({ player: parts.player });
  parts.report = new Report({ gameId });
  parts.exports = new Exports({ gameId });
  parts.jobPanel = new JobPanel({
    onChange: (job) => {
      // A finished GPU run replaced the annotated copy on the server: the player loads the new one.
      if (replacedAnnotatedCopy(job)) state.filmRenewed = true;
      refresh();
    },
    onUpdate: showJobStatus,
  });
  parts.calibration = new Calibration({
    player: parts.player,
    gameId,
    onReanalyze: () => startJob(rerunKind()),
    onFullAnalysis: startFullAnalysis,
    onChange: (calibration) => {
      // The Data quality tab shows the calibration and, with it, the Full re-analysis button.
      state.game = { ...state.game, calibration };
      if (state.analysis) renderQualityTab();
    },
  });
  byId("reanalyze-btn").addEventListener("click", (e) => {
    e.currentTarget.disabled = true; // refresh() re-enables it once the job state is known
    startJob(rerunKind());
  });
  byId("full-analysis-btn").addEventListener("click", (e) => startFullAnalysis(e.currentTarget));
  setupAnalysisTabs();
  refresh();
}

init();
