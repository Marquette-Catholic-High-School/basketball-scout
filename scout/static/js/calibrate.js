// Manual court calibration for FIXED cameras: click known court landmarks on a paused
// frame, save (PUT /api/games/{id}/calibration), then check the fit by drawing the
// court lines projected back onto the frame with the inverse homography.

import { api, gamePath } from "./api.js";
import { applyHomography, courtConfig, drawLines, fullCourtLines, invert3 } from "./court.js";
import { landmarkLabel } from "./labels.js";
import { byId, clearError, el, notice, prepareCanvas, setChildren, show, showError, toast, withBusy } from "./ui.js";

const MIN_POINTS = 4;
/** The result's button for the job the game page's re-run starts (game.js rerunKind). */
const RERUN_LABELS = { analyze: "Analyze film", reanalyze: "Re-run analysis" };

/** Plain-English verdict for the mean reprojection error (feet). */
function calibrationQuality(errorFt) {
  if (errorFt <= 1) return ["success", "Excellent fit"];
  if (errorFt <= 2.5) return ["success", "Good fit"];
  if (errorFt <= 5) return ["warning", "Fair fit - double-check the points"];
  return ["error", "Poor fit - some points are probably on the wrong landmark"];
}

function landmarkGroup(name) {
  if (name.startsWith("left_")) return "Left end (as the camera sees it)";
  if (name.startsWith("right_")) return "Right end (as the camera sees it)";
  return "Middle of the court";
}

export class Calibration {
  /**
   * onReanalyze() / onFullAnalysis(button) start a re-run / a full re-analysis;
   * onChange(calibration) runs after the calibration was saved (or removed: null).
   */
  constructor({ player, gameId, onReanalyze, onFullAnalysis = null, onChange = null }) {
    this.player = player;
    this.gameId = gameId;
    this.onReanalyze = onReanalyze;
    this.onFullAnalysis = onFullAnalysis;
    this.onChange = onChange;
    this.panel = byId("calibration-panel");
    this.layer = byId("calibration-layer");
    this.select = byId("cal-landmark");
    this.cfg = courtConfig(null);
    this.landmarks = {};
    this.points = [];
    this.frameSize = null; // {width, height} of the copy the points and matrix are measured on
    this.saved = null;
    this.matrix = null;
    this.fullRunAdvised = false;
    this.rerunKind = "reanalyze";
    this.rerunButton = null; // the result's Re-run analysis / Analyze film button
    this.fullButton = null; // and its Full re-analysis button, when it offers one
    this.busy = false; // an analysis job runs: the server would refuse another
    this.isOpen = false;

    byId("calibrate-btn").addEventListener("click", () => (this.isOpen ? this.close() : this.open()));
    byId("cal-close").addEventListener("click", () => this.close());
    byId("cal-undo").addEventListener("click", () => this.changePoints(this.points.slice(0, -1)));
    byId("cal-clear").addEventListener("click", () => this.changePoints([]));
    byId("cal-save").addEventListener("click", (e) => withBusy(e.currentTarget, "Saving…", () => this.save()));
    byId("cal-delete").addEventListener("click", (e) => withBusy(e.currentTarget, "Removing…", () => this.remove()));
    byId("cal-points").addEventListener("click", (e) => {
      const button = e.target.closest("button[data-landmark]");
      if (button) this.changePoints(this.points.filter((p) => p.landmark !== button.dataset.landmark));
    });
    this.select.addEventListener("change", () => this.drawDiagram());
    this.layer.addEventListener("click", (e) => this.onFrameClick(e));
    new ResizeObserver(() => this.drawLayer()).observe(this.layer);
    this.player.video.addEventListener("seeked", () => this.drawLayer());
    this.player.video.addEventListener("loadedmetadata", () => {
      if (!this.isOpen) return;
      this.fitToVideo(); // e.g. the original won't play here and the annotated copy took over
      this.update();
    });
  }

  /**
   * court: CourtConfig dict; landmarks: {name: [x, y]}; calibration: saved CourtCalibration
   * or null; fullRunAdvised: the GPU found no free throws, so after saving the panel offers
   * a full re-analysis; rerunKind: the job onReanalyze() starts, "reanalyze" (Re-run
   * analysis) or "analyze" (Analyze film, for a game without GPU results: game.js rerunKind);
   * busy: an analysis job is queued or running, so the result's buttons wait, as the header's.
   */
  setup({ court, landmarks, calibration, fullRunAdvised = false, rerunKind = "reanalyze", busy = false }) {
    this.cfg = courtConfig(court);
    this.landmarks = landmarks || {};
    this.saved = calibration || null;
    this.fullRunAdvised = Boolean(fullRunAdvised);
    this.rerunKind = rerunKind;
    this.busy = Boolean(busy);
    // A result on show names the job its button starts now (the first analysis may have finished since).
    // Only a new name is written: the result is a live region, which would read the same name out again.
    const label = RERUN_LABELS[rerunKind];
    if (this.rerunButton && this.rerunButton.textContent !== label) this.rerunButton.textContent = label;
    this.followBusy();
    const groups = new Map();
    for (const name of Object.keys(this.landmarks)) {
      const group = landmarkGroup(name);
      if (!groups.has(group)) groups.set(group, []);
      groups.get(group).push(name);
    }
    const current = this.select.value;
    setChildren(this.select, [...groups.entries()].map(([group, names]) =>
      el("optgroup", { label: group }, names.map((name) => el("option", { value: name, text: landmarkLabel(name) })))));
    if (this.landmarks[current]) this.select.value = current;
    const button = byId("calibrate-btn");
    button.disabled = !Object.keys(this.landmarks).length;
    button.title = button.disabled ? "Court landmarks could not be loaded" : "Map the court for a fixed camera";
  }

  async open() {
    if (!this.player.video.currentSrc) {
      toast("Add film to this game before calibrating the court.");
      return;
    }
    this.isOpen = true;
    show(this.panel, true);
    show(this.layer, true);
    byId("calibrate-btn").setAttribute("aria-expanded", "true");
    await this.player.setCalibrating(true);
    if (this.saved && !this.points.length) {
      const video = this.player.video;
      this.points = this.saved.points.map((p) => ({ landmark: p.landmark, px: [...p.px] }));
      this.matrix = this.saved.matrix;
      this.frameSize = {
        width: this.saved.video_width || video.videoWidth,
        height: this.saved.video_height || video.videoHeight,
      };
      this.showResult(this.saved);
    }
    this.fitToVideo();
    this.update();
    this.select.focus();
  }

  close() {
    this.isOpen = false;
    show(this.panel, false);
    show(this.layer, false);
    byId("calibrate-btn").setAttribute("aria-expanded", "false");
    this.player.setCalibrating(false);
  }

  /** Click on the frame -> ORIGINAL video pixels (undoing object-fit letterboxing). */
  toVideoPixels(event) {
    const rect = this.layer.getBoundingClientRect();
    const box = this.player.contentRect();
    const video = this.player.video;
    const x = (event.clientX - rect.left - box.x) / box.scale;
    const y = (event.clientY - rect.top - box.y) / box.scale;
    if (!video.videoWidth || x < 0 || y < 0 || x > video.videoWidth || y > video.videoHeight) return null;
    return [Math.round(x * 10) / 10, Math.round(y * 10) / 10];
  }

  /**
   * Measure the points and the matrix in the pixels of the copy now loaded. A calibration
   * saved on another copy (the 720p annotated one where the original won't play, the
   * full-size original in Safari) would be drawn at the wrong scale, and new clicks would
   * mix the two sizes. matrix · diag(1/sx, 1/sy, 1): new pixels -> saved pixels -> feet.
   */
  fitToVideo() {
    const { videoWidth: width, videoHeight: height } = this.player.video;
    const from = this.frameSize;
    if (!width || !height || !from?.width || !from?.height || (from.width === width && from.height === height)) return;
    const sx = width / from.width;
    const sy = height / from.height;
    const round = (v) => Math.round(v * 10) / 10;
    this.points = this.points.map((p) => ({ landmark: p.landmark, px: [round(p.px[0] * sx), round(p.px[1] * sy)] }));
    if (this.matrix) this.matrix = this.matrix.map((row) => [row[0] / sx, row[1] / sy, row[2]]);
    this.frameSize = { width, height };
  }

  onFrameClick(event) {
    const px = this.toVideoPixels(event);
    const landmark = this.select.value;
    if (!px || !landmark) {
      toast("Click inside the picture, on the selected landmark.");
      return;
    }
    this.fitToVideo(); // the points so far in the same pixels as this click
    this.frameSize = { width: this.player.video.videoWidth, height: this.player.video.videoHeight };
    this.changePoints([...this.points.filter((p) => p.landmark !== landmark), { landmark, px }]);
    const names = Object.keys(this.landmarks);
    const next = names.find((name) => !this.points.some((p) => p.landmark === name));
    if (next) this.select.value = next;
    this.drawDiagram();
  }

  changePoints(points) {
    this.points = points;
    this.matrix = null;
    setChildren(byId("cal-result"));
    this.update();
  }

  update() {
    const n = this.points.length;
    byId("cal-count").textContent = n >= MIN_POINTS
      ? `${n} points - ready to save (more points spread over the court make it more accurate).`
      : `${n} of at least ${MIN_POINTS} points. Spread them over the court; don't put them all on one line.`;
    setChildren(byId("cal-points"), this.points.map((p, i) => el("li", {},
      el("span", {}, `${i + 1}. ${landmarkLabel(p.landmark)} `, el("span", { class: "muted mono", text: `(${Math.round(p.px[0])}, ${Math.round(p.px[1])})` })),
      el("button", { type: "button", class: "btn-small", "data-landmark": p.landmark, "aria-label": `Remove point ${i + 1}`, text: "Remove" }))));
    byId("cal-save").disabled = n < MIN_POINTS;
    byId("cal-undo").disabled = n === 0;
    byId("cal-clear").disabled = n === 0;
    show(byId("cal-delete"), Boolean(this.saved));
    this.drawDiagram();
    this.drawLayer();
  }

  async save() {
    const video = this.player.video;
    // The server scales the points from this size to the film's own resolution.
    const size = this.frameSize || { width: video.videoWidth, height: video.videoHeight };
    clearError(byId("cal-result"));
    try {
      const calibration = await api.put(gamePath(this.gameId, "/calibration"), {
        points: this.points,
        frame_t: video.currentTime,
        video_width: size.width || null,
        video_height: size.height || null,
      });
      this.saved = calibration;
      this.matrix = calibration.matrix;
      this.update();
      this.showResult(calibration);
      this.onChange?.(calibration);
    } catch (err) {
      showError(byId("cal-result"), err);
    }
  }

  showResult(calibration) {
    const error = Number(calibration.reprojection_error_ft);
    const [kind, verdict] = calibrationQuality(error);
    // No free throws from the first run: only a GPU run with this calibration finds them.
    const full = this.fullRunAdvised && this.onFullAnalysis;
    this.rerunButton = el("button", {
      type: "button", class: full ? null : "btn-primary", text: RERUN_LABELS[this.rerunKind], onClick: (e) => this.rerun(e.currentTarget),
    });
    this.fullButton = full
      ? el("button", { type: "button", class: "btn-primary", text: "Full re-analysis", onClick: (e) => this.onFullAnalysis(e.currentTarget) })
      : null;
    setChildren(byId("cal-result"),
      notice(kind, `${verdict} (average error ${error.toFixed(1)} ft)`,
        "Check that the orange court lines drawn on the frame sit on the real lines. If they don't, move or remove points and save again.",
        full
          ? "The new mapping is used the next time the analysis runs. Free throws need a full re-analysis: it sends the film to the GPU again."
          : "The new mapping is used the next time the analysis runs."),
      el("div", { class: "row" }, this.rerunButton, this.fullButton));
    this.followBusy();
  }

  /** Busy until the page has started the job: a double click would post a second one, which the server refuses. */
  async rerun(button) {
    button.disabled = true;
    try {
      await this.onReanalyze();
    } finally {
      button.disabled = this.busy; // the job it started runs: setup() enables it again when that has ended
    }
  }

  /**
   * The result's buttons wait while an analysis runs, as the header's do; setup() enables them again once it
   * has ended, also after the page's Full re-analysis disabled its button for a start the server refused.
   */
  followBusy() {
    for (const button of [this.rerunButton, this.fullButton]) {
      if (!button) continue;
      button.disabled = this.busy;
      if (this.busy) button.title = "An analysis is already running";
      else button.removeAttribute("title");
    }
  }

  async remove() {
    if (!window.confirm("Remove the saved court calibration for this game?")) return;
    try {
      await api.del(gamePath(this.gameId, "/calibration"));
      this.saved = null;
      this.changePoints([]);
      setChildren(byId("cal-result"), notice("info", null, this.rerunKind === "analyze"
        ? "Calibration removed. The analysis will use automatic court detection."
        : "Calibration removed. Re-run the analysis to go back to automatic court detection."));
      this.onChange?.(null);
    } catch (err) {
      showError(byId("cal-result"), err);
    }
  }

  // ------------------------------------------------------------- drawing
  drawLayer() {
    if (!this.isOpen) return;
    const { ctx } = prepareCanvas(this.layer);
    const box = this.player.contentRect();
    const toScreen = ([x, y]) => [box.x + x * box.scale, box.y + y * box.scale];
    ctx.save();
    ctx.beginPath();
    ctx.rect(box.x, box.y, box.width, box.height);
    ctx.clip();
    const inverse = this.matrix ? invert3(this.matrix) : null;
    if (inverse) {
      ctx.strokeStyle = "#f97316";
      ctx.lineWidth = 2;
      for (const line of fullCourtLines(this.cfg)) {
        ctx.beginPath();
        let drawing = false;
        for (const [x, y] of line.points) {
          const px = applyHomography(inverse, x, y);
          if (!px) {
            drawing = false;
            continue;
          }
          const [sx, sy] = toScreen(px);
          if (drawing) ctx.lineTo(sx, sy);
          else ctx.moveTo(sx, sy);
          drawing = true;
        }
        ctx.stroke();
      }
    }
    ctx.font = "600 13px system-ui, sans-serif";
    ctx.textBaseline = "middle";
    this.points.forEach((point, i) => {
      const [sx, sy] = toScreen(point.px);
      ctx.strokeStyle = "#000";
      ctx.lineWidth = 4;
      ctx.beginPath();
      ctx.moveTo(sx - 9, sy);
      ctx.lineTo(sx + 9, sy);
      ctx.moveTo(sx, sy - 9);
      ctx.lineTo(sx, sy + 9);
      ctx.stroke();
      ctx.strokeStyle = "#facc15";
      ctx.lineWidth = 2;
      ctx.stroke();
      ctx.fillStyle = "rgba(0, 0, 0, 0.75)";
      ctx.fillRect(sx + 8, sy - 18, 22, 18);
      ctx.fillStyle = "#facc15";
      ctx.fillText(String(i + 1), sx + 13, sy - 9);
    });
    ctx.restore();
  }

  /** Small full-court diagram (near sideline at the bottom, like the camera view). */
  drawDiagram() {
    const cfg = this.cfg;
    const map = (x, y) => [x, cfg.width_ft - y];
    const svg = el("svg", { viewBox: `-3 -4 ${cfg.length_ft + 6} ${cfg.width_ft + 8}`, role: "img", "aria-label": `Court diagram. Selected landmark: ${landmarkLabel(this.select.value || "")}` });
    const lines = el("g", {});
    drawLines(lines, fullCourtLines(cfg), map);
    svg.append(lines,
      el("text", { x: cfg.length_ft / 2, y: -1.2, class: "diagram-label", text: "Far sideline" }),
      el("text", { x: cfg.length_ft / 2, y: cfg.width_ft + 3, class: "diagram-label", text: "Near sideline (camera side)" }));
    const placed = new Set(this.points.map((p) => p.landmark));
    for (const [name, [x, y]] of Object.entries(this.landmarks)) {
      const [cx, cy] = map(x, y);
      const classes = ["lm-dot", placed.has(name) ? "done" : "", name === this.select.value ? "selected" : ""].filter(Boolean).join(" ");
      const dot = el("circle", { cx, cy, r: name === this.select.value ? 1.8 : 1.1, class: classes, "data-landmark": name },
        el("title", { text: landmarkLabel(name) }));
      dot.addEventListener("click", () => {
        this.select.value = name;
        this.drawDiagram();
      });
      svg.append(dot);
    }
    setChildren(byId("cal-diagram"), svg);
  }
}
