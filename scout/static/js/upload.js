// New game form + chunked, resumable film upload (or a direct video link).
//
// Upload protocol (docs/ARCHITECTURE.md): POST /api/games/{id}/uploads -> session;
// PUT /api/uploads/{uid}/chunk?offset=N for each slice; 409 means "resume from
// upload.received"; POST .../complete starts the analysis.

import { ApiError, api, gamePath, putChunk } from "./api.js";
import {
  byId, el, setChildren, show, showError, clearError, notice, formatBytes, formatDuration,
  sleep, storageGet, storageSet, withBusy,
} from "./ui.js";

const VIDEO_EXTENSIONS = [".mp4", ".mov", ".m4v"];
const MAX_RETRIES = 8;
const SPEED_WINDOW_MS = 8000;
/**
 * A chunk with no upload progress for this long went to a connection that died silently:
 * it is aborted and the upload resumes from what the server has. (The server drops a
 * chunk that sends nothing for 120 s and answers 409 UPLOAD_INCOMPLETE.)
 */
const STALL_MS = 60000;
/** Timers of the stall watchdog; tests replace them to run it without waiting a minute. */
export const watchdogTimers = {
  set: (fn, ms) => setTimeout(fn, ms),
  clear: (id) => clearTimeout(id),
};
/**
 * Errors after which this upload session can't go on: the server refused the film itself...
 * (not UPLOAD_TOO_LARGE: on a chunk that is a proxy limit, and the upload resumes once it is raised)
 */
const FILM_REFUSED = new Set(["VIDEO_INVALID", "VIDEO_DECODE_FAILED", "VIDEO_TOO_LONG"]);
/** ...or no longer has the part already sent (the same file can be sent again from the start). */
const SESSION_GONE = new Set(["UPLOAD_NOT_FOUND"]);

const state = {
  game: null,
  file: null,
  session: null,
  received: 0,
  inflight: 0,
  controller: null,
  paused: false,
  running: false,
  done: false,
  samples: [],
};

const storageKey = (gameId) => `scout.upload.${gameId}`;
let maxUploadBytes = null; // from /api/health; the server re-checks when the upload starts

// ---------------------------------------------------------------------------
// Step 1: game details
// ---------------------------------------------------------------------------

function colorValue(form) {
  const mode = form.querySelector("input[name=color_mode]:checked")?.value || "dark";
  return mode === "pick" ? byId("f-color").value : mode;
}

function readForm() {
  const form = byId("game-form");
  const text = (id) => byId(id).value.trim();
  return {
    scouted_team: text("f-scouted"),
    other_team: text("f-other"),
    game_date: byId("f-date").value || null,
    location: text("f-location") || null,
    level: text("f-level") || null,
    notes: text("f-notes") || null,
    scouted_color: colorValue(form),
  };
}

async function createGame(event) {
  event.preventDefault();
  const errorBox = byId("form-error");
  clearError(errorBox);
  const body = readForm();
  const scouted = byId("f-scouted");
  if (!body.scouted_team) {
    scouted.setAttribute("aria-invalid", "true");
    showError(errorBox, { info: { title: "Team name needed", message: "Enter the name of the team you are scouting." } });
    scouted.focus();
    return;
  }
  scouted.removeAttribute("aria-invalid");
  await withBusy(byId("create-btn"), "Creating…", async () => {
    try {
      const game = await api.post("/api/games", body);
      window.history.replaceState(null, "", `/upload?game=${encodeURIComponent(game.id)}`);
      showFilmStep(game);
    } catch (err) {
      showError(errorBox, err);
    }
  });
}

function setupColorPicker() {
  const picker = byId("f-color");
  byId("game-form").addEventListener("change", (e) => {
    if (e.target.name === "color_mode") picker.disabled = e.target.value !== "pick";
  });
}

// ---------------------------------------------------------------------------
// Step 2: film
// ---------------------------------------------------------------------------

function showFilmStep(game) {
  state.game = game;
  show(byId("game-form-section"), false);
  show(byId("film-section"), true);
  const hasFilm = game.has_video || Boolean(game.video_url); // a file, or a link the GPU downloads
  byId("upload-title").textContent = hasFilm ? "Replace film" : "Add film";
  byId("upload-subtitle").textContent = game.display_title;
  byId("film-game-name").textContent = `Game: ${game.display_title}`;
  document.title = `Film for ${game.display_title} - Basketball Scout`;
  const notices = [];
  if (hasFilm) {
    const current = game.has_video ? game.video_filename || "the current film" : "the film from the video link";
    notices.push(notice("warning", "This game already has film", `New film replaces ${current} and runs the analysis again.`));
  }
  const pending = storageGet(storageKey(game.id));
  if (pending) {
    notices.push(notice("info", "An earlier upload was interrupted", `Choose ${pending.name} again to continue where it stopped.`));
  }
  setChildren(byId("film-notices"), notices);
  byId("film-heading").focus();
}

/** The drop zone, "or" divider and video-link form are hidden while a file uploads. */
function showChoices(visible) {
  for (const id of ["dropzone", "film-divider", "url-form"]) show(byId(id), visible);
}

function validateFile(file) {
  const name = file.name.toLowerCase();
  if (!VIDEO_EXTENSIONS.some((ext) => name.endsWith(ext))) {
    return { title: "Not a video file", message: `"${file.name}" is not an MP4, MOV or M4V video.`, hint: "Export the film as MP4 (Hudl: Download > MP4) and try again." };
  }
  if (file.size === 0) {
    return { title: "Empty file", message: `"${file.name}" is empty.`, hint: "Pick the full game film file." };
  }
  if (maxUploadBytes && file.size > maxUploadBytes) {
    return {
      title: "File too large",
      message: `"${file.name}" is ${formatBytes(file.size)}; this server accepts films up to ${formatBytes(maxUploadBytes)}.`,
      hint: "Trim or compress the film, or ask IT to raise SCOUT_MAX_UPLOAD_GB.",
    };
  }
  return null;
}

function setupDropzone() {
  const zone = byId("dropzone");
  const input = byId("file-input");
  zone.addEventListener("click", (e) => {
    if (e.target === zone || e.target.closest("p, .dropzone-icon")) input.click();
  });
  for (const type of ["dragenter", "dragover"]) {
    zone.addEventListener(type, (e) => {
      e.preventDefault();
      zone.classList.add("dragover");
    });
  }
  for (const type of ["dragleave", "drop"]) zone.addEventListener(type, () => zone.classList.remove("dragover"));
  zone.addEventListener("drop", (e) => {
    e.preventDefault();
    const file = e.dataTransfer?.files?.[0];
    if (file) chooseFile(file);
  });
  // A file dropped next to the zone must not navigate away from the page.
  window.addEventListener("dragover", (e) => e.preventDefault());
  window.addEventListener("drop", (e) => e.preventDefault());
  input.addEventListener("change", () => {
    if (input.files?.[0]) chooseFile(input.files[0]);
    input.value = "";
  });
}

async function chooseFile(file) {
  if (state.running || state.session) return;
  const errorBox = byId("upload-error");
  clearError(errorBox);
  const problem = validateFile(file);
  if (problem) {
    showError(errorBox, { info: problem });
    return;
  }
  state.file = file;
  state.samples = [];
  showChoices(false);
  show(byId("upload-panel"), true);
  byId("upload-filename").textContent = file.name;
  byId("upload-filesize").textContent = formatBytes(file.size);
  setStatus("Starting upload…");
  try {
    const session = await openSession(file);
    if (state.file !== file) return await discardSession(session); // cancelled while it was starting
    state.session = session;
    state.received = session.received || 0;
    renderProgress();
    await runUpload();
  } catch (err) {
    if (state.file === file) failUpload(err);
  }
}

/** Resume the stored session for this exact file, or start a new one. */
async function openSession(file) {
  const key = storageKey(state.game.id);
  const stored = storageGet(key);
  if (stored && stored.name === file.name && stored.size === file.size && stored.lastModified === file.lastModified) {
    try {
      const session = await api.get(`/api/uploads/${encodeURIComponent(stored.uploadId)}`);
      if (session.status === "open" && session.size === file.size) return session;
    } catch {
      // Expired or unknown session: fall through and start again.
    }
  }
  const session = await api.post(gamePath(state.game.id, "/uploads"), { filename: file.name, size: file.size, content_type: file.type || null });
  storageSet(key, { uploadId: session.id, name: file.name, size: file.size, lastModified: file.lastModified });
  return session;
}

const isTransient = (err) => err.code === "NETWORK_ERROR" || err.status >= 500 || Boolean(err.info?.retryable);

/** received offset carried by a 409 conflict response, if any. */
function conflictOffset(err) {
  const body = err.body || {};
  const received = body.upload?.received ?? body.received;
  return Number.isInteger(received) ? received : null;
}

async function runUpload() {
  state.running = true;
  setPausedUI(state.paused); // Pause pressed while the upload was starting: offer Resume
  let failures = 0;
  try {
    while (state.received < state.file.size) {
      if (state.paused || !state.session) return;
      const offset = state.received;
      const end = Math.min(offset + state.session.chunk_size, state.file.size);
      state.controller = new AbortController();
      setStatus(failures ? "Reconnected - uploading…" : "Uploading…");
      try {
        const session = await putChunk(state.session.id, offset, state.file.slice(offset, end), {
          signal: state.controller.signal,
          stall: { ms: STALL_MS, timers: watchdogTimers },
          onProgress: (loaded) => {
            state.inflight = loaded;
            renderProgress();
          },
        });
        state.received = session.received;
        state.inflight = 0;
        failures = 0;
        renderProgress();
      } catch (err) {
        state.inflight = 0;
        if (err.name === "AbortError") return;
        const resumeAt = err.status === 409 ? conflictOffset(err) : null;
        if (resumeAt !== null) {
          state.received = resumeAt;
          continue;
        }
        if (!isTransient(err) || failures >= MAX_RETRIES) throw err;
        failures += 1;
        await backoff(failures);
      }
    }
    await completeUpload();
  } finally {
    state.running = false;
  }
}

/** Wait 1, 2, 4 … 30 s, then ask the server how much it really has. */
async function backoff(attempt) {
  const delay = Math.min(30000, 1000 * 2 ** (attempt - 1));
  setStatus(`Connection problem - retrying in ${Math.round(delay / 1000)} s (attempt ${attempt} of ${MAX_RETRIES})`);
  await sleep(delay, state.controller.signal);
  try {
    const session = await api.get(`/api/uploads/${encodeURIComponent(state.session.id)}`);
    state.received = session.received;
  } catch {
    // Still offline; the next chunk attempt will fail and back off again.
  }
}

async function completeUpload() {
  setStatus("Finishing upload…");
  const result = await api.post(`/api/uploads/${encodeURIComponent(state.session.id)}/complete?auto_start=true`);
  state.done = true;
  storageSet(storageKey(state.game.id), null);
  setStatus("Upload complete - opening the game…");
  window.location.assign(`/games/${encodeURIComponent(result.game.id)}`);
}

function failUpload(err) {
  if (err.name === "AbortError") return; // paused or cancelled on purpose
  setStatus("Stopped");
  const code = err.info?.code;
  if (FILM_REFUSED.has(code) || SESSION_GONE.has(code)) forgetSession();
  const anotherFile = el("button", { type: "button", text: "Choose another file", onClick: resetUpload });
  let actions = [anotherFile];
  if (state.session) actions = [el("button", { type: "button", class: "btn-primary", text: "Resume upload", onClick: resumeUpload })];
  else if (SESSION_GONE.has(code) && state.file) actions = [el("button", { type: "button", class: "btn-primary", text: "Upload this file again", onClick: uploadAgain }), anotherFile];
  showError(byId("upload-error"), err, actions);
  if (state.session) {
    state.paused = true;
    setPausedUI(true);
  } else {
    for (const id of ["pause-btn", "resume-btn"]) show(byId(id), false);
  }
}

/** The server can't continue this session: don't offer to resume it (here or after a reload). */
function forgetSession() {
  state.session = null;
  storageSet(storageKey(state.game.id), null);
}

/** Send the same file again in a new session. */
function uploadAgain() {
  const file = state.file;
  resetUpload();
  chooseFile(file);
}

function pauseUpload() {
  state.paused = true;
  state.controller?.abort();
  setPausedUI(true);
  setStatus("Paused");
}

async function resumeUpload() {
  if (state.running || !state.session) return;
  const current = state.session;
  clearError(byId("upload-error"));
  state.paused = false;
  state.samples = [];
  setStatus("Checking what the server already has…");
  try {
    const session = await api.get(`/api/uploads/${encodeURIComponent(current.id)}`);
    if (state.session !== current) return; // cancelled while checking
    if (session.status === "aborted") {
      // E.g. the film was refused while the connection was down: this session is over.
      throw new ApiError({
        code: "UPLOAD_NOT_FOUND",
        title: "This upload can't be resumed",
        message: "The server stopped this upload, so it has to start again from the beginning.",
        hint: "Upload the file again, or choose another file.",
      }, 409);
    }
    state.received = session.received;
    renderProgress();
    await runUpload();
  } catch (err) {
    if (state.session === current) failUpload(err);
  }
}

async function cancelUpload() {
  if (!window.confirm("Cancel this upload? The part already sent will be discarded.")) return;
  const session = state.session;
  state.paused = true;
  state.controller?.abort();
  state.session = null;
  storageSet(storageKey(state.game.id), null);
  if (session) await discardSession(session);
  resetUpload();
}

/** Delete an upload session on the server; forget it here too if it is the stored one. */
async function discardSession(session) {
  const key = storageKey(state.game.id);
  if (storageGet(key)?.uploadId === session.id) storageSet(key, null);
  try {
    await api.del(`/api/uploads/${encodeURIComponent(session.id)}`);
  } catch {
    // Already gone; nothing else to clean up.
  }
}

function resetUpload() {
  Object.assign(state, { file: null, session: null, received: 0, inflight: 0, paused: false, samples: [] });
  clearError(byId("upload-error"));
  show(byId("upload-panel"), false);
  showChoices(true);
  renderProgress();
}

// ---------------------------------------------------------------------------
// Progress display
// ---------------------------------------------------------------------------

function setPausedUI(paused) {
  show(byId("pause-btn"), !paused);
  show(byId("resume-btn"), paused);
}

/** Status line (a live region: only real changes are written, so they are read out once). */
function setStatus(text) {
  const status = byId("upload-state");
  if (status.textContent !== text) status.textContent = text;
}

function currentSpeed(total) {
  const now = performance.now();
  state.samples.push([now, total]);
  while (state.samples.length > 2 && now - state.samples[0][0] > SPEED_WINDOW_MS) state.samples.shift();
  const [t0, b0] = state.samples[0];
  const seconds = (now - t0) / 1000;
  return seconds > 0.5 ? (total - b0) / seconds : null;
}

function renderProgress() {
  const size = state.file?.size || 0;
  const total = Math.min(size, state.received + state.inflight);
  const pct = size ? (total / size) * 100 : 0;
  byId("upload-bar").style.width = `${pct.toFixed(1)}%`;
  byId("upload-progress").setAttribute("aria-valuenow", String(Math.floor(pct)));
  byId("upload-pct").textContent = `${pct.toFixed(1)}%`;
  const speed = size && state.running ? currentSpeed(total) : null;
  byId("upload-speed").textContent = speed ? `${(speed / 1024 / 1024).toFixed(1)} MB/s` : "";
  byId("upload-eta").textContent = speed && speed > 0 ? `about ${formatDuration((size - total) / speed)} left` : "";
}

// ---------------------------------------------------------------------------
// Video link
// ---------------------------------------------------------------------------

function filenameFromUrl(url) {
  try {
    return decodeURIComponent(new URL(url).pathname.split("/").pop() || "") || null;
  } catch {
    return null;
  }
}

async function submitVideoUrl(event) {
  event.preventDefault();
  const errorBox = byId("url-error");
  clearError(errorBox);
  const url = byId("f-url").value.trim();
  if (!/^https?:\/\/\S+$/i.test(url)) {
    showError(errorBox, { info: { title: "Check the link", message: "Enter the full link, including the http or https part at the start.", hint: "It must point straight at the .mp4 file." } });
    byId("f-url").focus();
    return;
  }
  const filename = filenameFromUrl(url);
  await withBusy(byId("url-btn"), "Saving…", async () => {
    try {
      const result = await api.post(gamePath(state.game.id, "/video-url?auto_start=true"), { url, filename });
      state.done = true;
      window.location.assign(`/games/${encodeURIComponent(result.game.id)}`);
    } catch (err) {
      showError(errorBox, err);
    }
  });
}

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

async function init() {
  setupColorPicker();
  setupDropzone();
  byId("game-form").addEventListener("submit", createGame);
  byId("url-form").addEventListener("submit", submitVideoUrl);
  byId("pause-btn").addEventListener("click", pauseUpload);
  byId("resume-btn").addEventListener("click", resumeUpload);
  byId("cancel-btn").addEventListener("click", cancelUpload);
  window.addEventListener("beforeunload", (e) => {
    if (state.session && !state.done) {
      e.preventDefault();
      e.returnValue = "";
    }
  });

  api.get("/api/health").then((health) => { maxUploadBytes = health.max_upload_bytes || null; }).catch(() => {});

  const gameId = new URLSearchParams(window.location.search).get("game");
  if (!gameId) {
    byId("f-scouted").focus();
    return;
  }
  try {
    showFilmStep(await api.get(gamePath(gameId)));
  } catch (err) {
    show(byId("game-form-section"), false);
    showError(byId("page-error"), err, [el("a", { class: "btn", href: "/", text: "Back to games" })]);
  }
}

init();
