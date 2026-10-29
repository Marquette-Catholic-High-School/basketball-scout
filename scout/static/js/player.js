// Video player: annotated/original film, speed, keyboard shortcuts, a canvas overlay
// (current event caption, current play banner, score) and the event marker strip.

import { gamePath } from "./api.js";
import { CATEGORY_LABELS, EVENT_CATEGORY, NOISY_EVENT_TYPES, PLAY_TYPE_LABELS, shortTeamName } from "./labels.js";
import { byId, el, formatClock, isTypingTarget, notice, placeTip, prepareCanvas, setChildren } from "./ui.js";

export const PREROLL_S = 3;
const CAPTION_S = 3.5;
const CONTROLS_ALLOWANCE_PX = 48;

/** Index of the last item whose key is <= t (items sorted by key), or -1. */
export function lastIndexAtOrBefore(items, t, key = (item) => item.t) {
  let lo = 0;
  let hi = items.length - 1;
  let found = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (key(items[mid]) <= t) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return found;
}

/** "Pick & Roll - #3 Smith / #22 Jones" (defenses: "Zone Defense (2-3)"). */
export function playBannerText(play) {
  const label = PLAY_TYPE_LABELS[play.type] || play.type;
  const shape = play.attrs?.zone_shape ? ` (${play.attrs.zone_shape})` : "";
  const names = [...new Set(Object.values(play.players || {}).map((p) => p?.label).filter(Boolean))];
  return names.length ? `${label}${shape} - ${names.join(" / ")}` : `${label}${shape}`;
}

function cssVar(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

function fitText(ctx, text, maxWidth) {
  if (ctx.measureText(text).width <= maxWidth) return text;
  let cut = text;
  while (cut.length > 1 && ctx.measureText(`${cut}…`).width > maxWidth) cut = cut.slice(0, -1);
  return `${cut}…`;
}

export class Player {
  constructor({ gameId }) {
    this.gameId = gameId;
    this.video = byId("video");
    this.stage = byId("player-stage");
    this.overlay = byId("overlay");
    this.strip = byId("marker-strip");
    this.tip = byId("marker-tip");
    this.errorBox = byId("video-error");
    this.events = [];
    this.captionEvents = [];
    this.markers = [];
    this.plays = [];
    this.possessions = [];
    this.teamNames = {};
    this.duration = 0;
    this.variant = null;
    this.hasOriginal = false;
    this.hasAnnotated = false;
    this.annotatedListed = false; // the game had an annotated copy at the last load()
    this.chosen = false; // the coach picked a version with the Annotated / Original buttons
    this.rate = 1;
    this.captions = true;
    this.calibrating = false;
    this.clickedButton = null;
    this.listeners = new Set();
    this.raf = null;
    this.lastPlayheadX = -1;
    this.wire();
  }

  // ------------------------------------------------------------- setup
  wire() {
    const v = this.video;
    v.addEventListener("play", () => this.startLoop());
    for (const type of ["pause", "ended", "emptied"]) v.addEventListener(type, () => this.stopLoop());
    for (const type of ["timeupdate", "seeked"]) v.addEventListener(type, () => this.tick());
    v.addEventListener("loadedmetadata", () => {
      v.playbackRate = this.rate;
      this.redraw();
    });
    v.addEventListener("error", () => this.onVideoError());

    byId("variant-annotated").addEventListener("click", () => this.chooseVariant("annotated"));
    byId("variant-original").addEventListener("click", () => this.chooseVariant("original"));
    byId("speed-select").addEventListener("change", (e) => {
      this.rate = Number(e.target.value) || 1;
      v.defaultPlaybackRate = this.rate;
      v.playbackRate = this.rate;
    });
    byId("overlay-toggle").addEventListener("change", (e) => {
      this.captions = e.target.checked;
      this.redraw();
    });
    byId("prev-event").addEventListener("click", () => this.prevEvent());
    byId("next-event").addEventListener("click", () => this.nextEvent());
    byId("fullscreen-btn").addEventListener("click", () => this.toggleFullscreen());

    this.strip.addEventListener("click", (e) => this.onStripClick(e));
    this.strip.addEventListener("mousemove", (e) => this.onStripHover(e));
    this.strip.addEventListener("mouseleave", () => {
      this.tip.hidden = true;
    });
    // A button clicked with the mouse keeps focus (an event time, "Event ▶"...); Space would
    // click it again instead of playing. Shortcuts win on that button until Tab moves on.
    document.addEventListener("mousedown", (e) => {
      this.clickedButton = e.target instanceof Element ? e.target.closest("button") : null;
    });
    document.addEventListener("keydown", (e) => this.onKey(e));
    new ResizeObserver(() => this.redraw()).observe(this.stage);
    window.addEventListener("resize", () => this.redraw());
    window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => this.refreshColors());
  }

  /** Forget cached colours (theme or team colours changed). */
  refreshColors() {
    this.colors = null;
    this.redraw();
  }

  /**
   * Point the player at the game's film (annotated when available). A film added as a
   * link has no original on this server, but the annotated copy made by the GPU plays.
   * When the first analysis finishes on an open page, the player moves to its annotated
   * copy unless the coach chose a version. renewed: a new GPU run replaced the annotated
   * copy on the server (same URL), so it is loaded again.
   */
  load({ hasVideo, hasAnnotated, renewed = false }) {
    const arrived = Boolean(hasAnnotated) && !this.annotatedListed;
    this.annotatedListed = Boolean(hasAnnotated);
    this.hasOriginal = Boolean(hasVideo);
    this.hasAnnotated = Boolean(hasAnnotated);
    const annotatedBtn = byId("variant-annotated");
    annotatedBtn.disabled = !this.hasAnnotated;
    annotatedBtn.title = this.hasAnnotated ? "Film with tracking overlays" : "No annotated video for this game";
    const originalBtn = byId("variant-original");
    originalBtn.disabled = !this.hasOriginal;
    originalBtn.title = this.hasOriginal ? "" : "The original film isn't stored on this server (it was added as a link)";
    if (!this.hasOriginal && !this.hasAnnotated) return Promise.resolve(false);
    if (!this.variant) return this.setVariant(this.hasAnnotated ? "annotated" : "original", { keepTime: false });
    if (this.calibrating) return Promise.resolve(true); // calibration needs the frame it is on
    if (arrived && this.variant === "original" && !this.chosen) return this.setVariant("annotated");
    if (renewed && this.variant === "annotated") return this.setVariant("annotated", { reload: true });
    return Promise.resolve(true);
  }

  /** The coach picked a version: the player stays on it when the analysis adds an annotated copy. */
  chooseVariant(variant) {
    this.chosen = true;
    return this.setVariant(variant);
  }

  /** Data from the analysis. events: TimelineEvent[], plays: Play[], possessions: Possession[]. */
  setData({ events = [], plays = [], possessions = [], teamNames = {}, duration = 0 }) {
    this.events = [...events].sort((a, b) => a.t - b.t);
    this.captionEvents = this.events.filter((e) => !NOISY_EVENT_TYPES.has(e.type));
    this.plays = [...plays].sort((a, b) => a.start_t - b.start_t);
    this.possessions = possessions;
    this.teamNames = teamNames;
    this.duration = duration;
    this.refreshColors();
  }

  /** Events drawn on the marker strip and used by previous/next event. */
  setMarkers(events) {
    this.markers = events;
    this.renderLegend();
    this.redraw();
  }

  onTime(listener) {
    this.listeners.add(listener);
  }

  get currentTime() {
    return this.video.currentTime || 0;
  }

  // ------------------------------------------------------------- playback
  setVariant(variant, { keepTime = true, reload = false } = {}) {
    const target = (variant === "annotated" && this.hasAnnotated) || !this.hasOriginal ? "annotated" : "original";
    byId("variant-annotated").setAttribute("aria-pressed", String(target === "annotated"));
    byId("variant-original").setAttribute("aria-pressed", String(target === "original"));
    if (target === this.variant && this.video.currentSrc && !reload) return Promise.resolve(true);
    const v = this.video;
    const time = keepTime ? v.currentTime || 0 : 0;
    const wasPlaying = !v.paused;
    this.variant = target;
    this.errorBox.replaceChildren();
    v.src = gamePath(this.gameId, `/video?variant=${target}`);
    return new Promise((resolve) => {
      const done = (ok) => {
        v.removeEventListener("loadedmetadata", onMeta);
        v.removeEventListener("error", onError);
        resolve(ok);
      };
      const onMeta = () => {
        if (time) v.currentTime = time;
        if (wasPlaying) v.play().catch(() => {});
        done(true);
      };
      const onError = () => done(false);
      v.addEventListener("loadedmetadata", onMeta);
      v.addEventListener("error", onError);
    });
  }

  onVideoError() {
    if (this.variant === "annotated" && this.hasOriginal) {
      this.hasAnnotated = false;
      byId("variant-annotated").disabled = true;
      this.setVariant("original");
      setChildren(this.errorBox, notice("info", null, "The annotated video isn't available, so the original film is shown."));
      return;
    }
    if (this.variant === "original" && this.hasAnnotated) {
      // The annotated copy is always H.264, so it plays where an HEVC/MOV original can't.
      this.hasOriginal = false;
      byId("variant-original").disabled = true;
      this.setVariant("annotated");
      setChildren(this.errorBox, notice("info", null, "The original film can't be played in this browser (MOV and HEVC files often can't), so the annotated copy is shown."));
      return;
    }
    setChildren(this.errorBox, notice("warning", "The film can't be played in this browser",
      "The analysis is not affected. MOV or HEVC (H.265) files often don't play in Chrome or Firefox.",
      "Re-export the film as H.264 MP4 to watch it here, or use Safari."));
  }

  seek(t, { reveal = false } = {}) {
    if (!this.video.currentSrc) return;
    const max = Number.isFinite(this.video.duration) ? this.video.duration : this.duration || t;
    this.video.currentTime = Math.max(0, Math.min(max, t));
    if (reveal) {
      const rect = this.stage.getBoundingClientRect();
      if (rect.top < 0 || rect.bottom > window.innerHeight) {
        const smooth = !window.matchMedia("(prefers-reduced-motion: reduce)").matches;
        this.stage.scrollIntoView({ block: "center", behavior: smooth ? "smooth" : "auto" });
      }
    }
  }

  nudge(seconds) {
    this.seek(this.currentTime + seconds);
  }

  togglePlay() {
    if (this.video.paused) this.video.play().catch(() => {});
    else this.video.pause();
  }

  nextEvent() {
    const now = this.currentTime;
    const next = this.markers.find((e) => e.t - PREROLL_S > now + 0.25);
    if (next) this.seek(next.t - PREROLL_S);
  }

  prevEvent() {
    const now = this.currentTime;
    const i = lastIndexAtOrBefore(this.markers, now - 0.25, (e) => e.t - PREROLL_S);
    if (i >= 0) this.seek(this.markers[i].t - PREROLL_S);
  }

  toggleFullscreen() {
    if (document.fullscreenElement) document.exitFullscreen();
    else if (this.stage.requestFullscreen) this.stage.requestFullscreen().catch(() => {});
    else this.video.webkitEnterFullscreen?.(); // iPhone: the film alone, without the captions overlay
  }

  onKey(e) {
    if (e.key === "Tab") this.clickedButton = null;
    if (e.defaultPrevented || e.ctrlKey || e.metaKey || e.altKey || !this.video.currentSrc) return; // e.g. arrows in the tab list
    if (e.target !== this.video && e.target !== this.clickedButton && isTypingTarget(e.target)) return;
    const step = e.shiftKey ? 1 : 5;
    const actions = {
      " ": () => this.togglePlay(),
      ArrowLeft: () => this.nudge(-step),
      ArrowRight: () => this.nudge(step),
      "[": () => this.prevEvent(),
      "]": () => this.nextEvent(),
    };
    const action = actions[e.key];
    if (!action) return;
    e.preventDefault();
    action();
  }

  /** Calibration mode: original film, paused, no native controls, no captions. */
  async setCalibrating(on) {
    this.calibrating = on;
    if (on) {
      this.video.pause();
      await this.setVariant("original");
      this.video.pause();
    }
    this.video.controls = !on;
    this.redraw();
  }

  /** Where the picture sits inside the <video> box (object-fit: contain letterboxing). */
  contentRect() {
    const width = this.video.clientWidth;
    const height = this.video.clientHeight;
    const vw = this.video.videoWidth || 16;
    const vh = this.video.videoHeight || 9;
    const scale = Math.min(width / vw, height / vh);
    return { x: (width - vw * scale) / 2, y: (height - vh * scale) / 2, width: vw * scale, height: vh * scale, scale };
  }

  // ------------------------------------------------------------- drawing
  startLoop() {
    const frame = () => {
      this.drawOverlay();
      this.raf = requestAnimationFrame(frame);
    };
    cancelAnimationFrame(this.raf);
    this.raf = requestAnimationFrame(frame);
  }

  stopLoop() {
    cancelAnimationFrame(this.raf);
    this.raf = null;
    this.redraw();
  }

  tick() {
    const t = this.currentTime;
    for (const listener of this.listeners) listener(t);
    if (!this.raf) this.drawOverlay();
    const width = this.strip.clientWidth;
    const x = this.timelineDuration() ? Math.round((t / this.timelineDuration()) * width) : -1;
    if (x !== this.lastPlayheadX) this.drawStrip();
  }

  redraw() {
    this.drawOverlay();
    this.drawStrip();
  }

  palette() {
    if (!this.colors) {
      this.colors = { scouted: cssVar("--scouted") || "#1f3a93", other: cssVar("--other") || "#d1d5db" };
      for (const category of Object.keys(CATEGORY_LABELS)) this.colors[category] = cssVar(`--c-${category}`) || "#888";
    }
    return this.colors;
  }

  timelineDuration() {
    return Number.isFinite(this.video.duration) && this.video.duration > 0 ? this.video.duration : this.duration;
  }

  currentCaption(t) {
    const i = lastIndexAtOrBefore(this.captionEvents, t);
    const event = i >= 0 ? this.captionEvents[i] : null;
    return event && t - event.t <= CAPTION_S ? event : null;
  }

  currentPlay(t) {
    const i = lastIndexAtOrBefore(this.plays, t, (p) => p.start_t);
    let fallback = null;
    for (let j = i; j >= 0 && j > i - 12; j -= 1) {
      const play = this.plays[j];
      if (play.end_t < t) continue;
      if (play.category === "offense") return play;
      fallback = fallback || play;
    }
    return fallback;
  }

  drawOverlay() {
    const { ctx } = prepareCanvas(this.overlay);
    if (!this.captions || this.calibrating || !this.events.length || !this.video.currentSrc) return;
    const t = this.currentTime;
    const box = this.contentRect();
    const colors = this.palette();
    const size = Math.max(12, Math.min(22, box.height * 0.04));
    const pad = size * 0.6;
    ctx.font = `600 ${size}px system-ui, sans-serif`;
    ctx.textBaseline = "middle";

    const play = this.currentPlay(t);
    if (play) this.drawLabel(ctx, playBannerText(play), box.x + pad, box.y + pad, colors[play.side] || colors.other, size, box.width * 0.62);

    const event = this.currentCaption(t);
    if (event) {
      const who = event.player?.label ? ` · ${event.player.label}` : "";
      const bottom = box.y + box.height - pad - size * 1.6 - (this.video.controls ? CONTROLS_ALLOWANCE_PX : 0);
      this.drawLabel(ctx, `${formatClock(event.t)}  ${event.label}${who}`, box.x + pad, Math.max(box.y + pad, bottom), colors[event.side] || colors.game, size, box.width - pad * 2);
    }

    const i = lastIndexAtOrBefore(this.events, t);
    if (i >= 0) this.drawScore(ctx, this.events[i], box, size, pad, colors);
  }

  drawLabel(ctx, text, x, y, accent, size, maxWidth) {
    const label = fitText(ctx, text, maxWidth - size * 1.4);
    const width = ctx.measureText(label).width + size * 1.4;
    const height = size * 1.6;
    ctx.fillStyle = "rgba(0, 0, 0, 0.72)";
    ctx.beginPath();
    ctx.roundRect(x, y, width, height, size * 0.3);
    ctx.fill();
    ctx.fillStyle = accent;
    ctx.fillRect(x, y, size * 0.3, height);
    ctx.fillStyle = "#ffffff";
    ctx.fillText(label, x + size * 0.8, y + height / 2);
  }

  drawScore(ctx, event, box, size, pad, colors) {
    const short = (side) => shortTeamName(this.teamNames[side] || side);
    const arrow = (side) => (event.possession_side === side ? "▸ " : "");
    const text = `${arrow("scouted")}${short("scouted")} ${event.score_scouted}  –  ${event.score_other} ${short("other")}${event.possession_side === "other" ? " ◂" : ""}`;
    ctx.font = `700 ${size * 0.9}px system-ui, sans-serif`;
    const width = ctx.measureText(text).width + size;
    const x = box.x + box.width - pad - width;
    const height = size * 1.5;
    ctx.fillStyle = "rgba(0, 0, 0, 0.72)";
    ctx.beginPath();
    ctx.roundRect(x, box.y + pad, width, height, size * 0.3);
    ctx.fill();
    ctx.fillStyle = colors.scouted;
    ctx.fillRect(x, box.y + pad + height - 3, width / 2, 3);
    ctx.fillStyle = colors.other;
    ctx.fillRect(x + width / 2, box.y + pad + height - 3, width / 2, 3);
    ctx.fillStyle = "#ffffff";
    ctx.fillText(text, x + size / 2, box.y + pad + height / 2);
  }

  drawStrip() {
    const { ctx, width, height } = prepareCanvas(this.strip);
    const duration = this.timelineDuration();
    if (!duration || !width) return;
    const colors = this.palette();
    const band = 5;
    for (const p of this.possessions) {
      if (!p.side) continue;
      ctx.fillStyle = colors[p.side];
      const x0 = (p.start_t / duration) * width;
      ctx.fillRect(x0, height - band, Math.max(1, ((p.end_t - p.start_t) / duration) * width), band);
    }
    const lane = (height - band - 2) / 2;
    for (const event of this.markers) {
      const x = (event.t / duration) * width;
      const top = event.side === "other" ? 1 + lane : 1;
      ctx.fillStyle = colors[EVENT_CATEGORY[event.type]] || colors.other;
      ctx.fillRect(x - 1, top, 2, event.side ? lane : lane * 2);
    }
    const playhead = Math.round((this.currentTime / duration) * width);
    ctx.fillStyle = cssVar("--text") || "#000";
    ctx.fillRect(playhead - 1, 0, 2, height);
    this.lastPlayheadX = playhead;
  }

  renderLegend() {
    const present = new Set(this.markers.map((e) => EVENT_CATEGORY[e.type] || "other"));
    const items = Object.entries(CATEGORY_LABELS)
      .filter(([category]) => present.has(category))
      .map(([category, label]) => el("span", { class: "legend-item" }, el("span", { class: `legend-dot cat-${category}`, "aria-hidden": "true" }), label));
    const teams = [
      el("span", { class: "legend-item" }, "Top row: ", this.teamNames.scouted || "scouted team"),
      el("span", { class: "legend-item" }, "Bottom row: ", this.teamNames.other || "opponent"),
      el("span", { class: "legend-item" }, "Bottom band: possession"),
    ];
    setChildren(byId("marker-legend"), items, this.markers.length ? teams : null);
  }

  nearestMarker(clientX) {
    const rect = this.strip.getBoundingClientRect();
    const duration = this.timelineDuration();
    if (!duration) return { time: 0, marker: null, x: 0 };
    const x = clientX - rect.left;
    const time = (x / rect.width) * duration;
    const tolerance = (6 / rect.width) * duration;
    const i = lastIndexAtOrBefore(this.markers, time);
    let marker = null;
    for (const candidate of [this.markers[i], this.markers[i + 1]]) {
      if (candidate && Math.abs(candidate.t - time) <= tolerance && (!marker || Math.abs(candidate.t - time) < Math.abs(marker.t - time))) marker = candidate;
    }
    return { time, marker, x };
  }

  onStripClick(e) {
    const { time, marker } = this.nearestMarker(e.clientX);
    this.seek(marker ? marker.t - PREROLL_S : time);
  }

  onStripHover(e) {
    const { time, marker, x } = this.nearestMarker(e.clientX);
    this.tip.hidden = false;
    this.tip.textContent = marker
      ? `${formatClock(marker.t)} ${marker.label}${marker.player?.label ? ` · ${marker.player.label}` : ""}`
      : formatClock(time);
    placeTip(this.tip, x, this.strip.clientWidth);
  }
}
