// Game time on the game page: the coach marks where the game is on the film (game starts,
// halftime starts and ends, game ends). Only that time counts in the stats, and a film analysed
// after the marks are set sends only that time to the GPU (scout/analysis/game_time.py).

import { api, gamePath } from "./api.js";
import { byId, el, errorBox, formatClock, setChildren, show, toast, withBusy } from "./ui.js";

const MARKS = [
  ["start", "Game starts", "Tip-off"],
  ["halfStart", "Halftime starts", "Optional"],
  ["halfEnd", "Halftime ends", "Optional"],
  ["end", "Game ends", "Final horn"],
];

/** "12:30", "1:02:05" or plain seconds -> seconds; null for anything else (also for ""). */
export function parseClock(text) {
  const value = String(text ?? "").trim();
  if (!/^\d+(:\d{1,2}){0,2}$/.test(value)) return null;
  return value.split(":").reduce((total, part) => total * 60 + Number(part), 0);
}

/** The saved stretches as the four marks (one stretch: no halftime). */
export function marksFromRanges(ranges) {
  const list = ranges || [];
  if (!list.length) return { start: null, halfStart: null, halfEnd: null, end: null };
  const last = list[list.length - 1];
  return {
    start: list[0].start_s,
    halfStart: list.length > 1 ? list[0].end_s : null,
    halfEnd: list.length > 1 ? last.start_s : null,
    end: last.end_s,
  };
}

/** The four marks as stretches, or a sentence saying what is wrong with them. */
export function rangesFromMarks({ start, halfStart, halfEnd, end }, filmSeconds) {
  const first = start ?? 0;
  const last = end ?? (filmSeconds > 0 ? Math.floor(filmSeconds) : null);
  if (last === null) return "Set when the game ends.";
  if ((halfStart === null) !== (halfEnd === null)) return "Set both ends of halftime, or neither.";
  if (halfStart === null) return last > first ? [{ start_s: first, end_s: last }] : "The game must end after it starts.";
  if (!(first < halfStart && halfStart < halfEnd && halfEnd < last)) return "The marks must be in order: game starts, halftime starts, halftime ends, game ends.";
  return [{ start_s: first, end_s: halfStart }, { start_s: halfEnd, end_s: last }];
}

export class GameTime {
  /** player: its currentTime and video.duration; onSaved(game, changed) when the marks were saved or cleared. */
  constructor({ gameId, player, onSaved }) {
    this.gameId = gameId;
    this.player = player;
    this.onSaved = onSaved;
    this.box = byId("game-time");
    this.inputs = {};
  }

  /** Shown for a game whose film can be played here (the marks are made on it); not for a live game. */
  render(game, { busy = false, hidden = false } = {}) {
    show(this.box, !hidden);
    if (hidden) return;
    const marks = marksFromRanges(game.play_ranges);
    const marked = Boolean(game.play_ranges?.length);
    this.error = el("div", { "aria-live": "assertive" });
    const rows = MARKS.map(([key, label, hint]) => {
      const input = el("input", { type: "text", inputmode: "numeric", placeholder: hint, value: marks[key] === null ? "" : formatClock(marks[key]), "aria-label": `${label} (minutes:seconds on the film)` });
      this.inputs[key] = input;
      return el("div", { class: "game-time-row" },
        el("span", { class: "game-time-label", text: label }),
        input,
        el("button", { type: "button", class: "btn-small", text: "Use film time", title: "Take the time the film player is at", onClick: () => { input.value = formatClock(this.player.currentTime); } }));
    });
    const save = el("button", { type: "button", class: "btn-primary", text: marked ? "Save game time" : "Set game time", disabled: busy, onClick: (e) => this.save(e.currentTarget, game) });
    const clear = marked ? el("button", { type: "button", text: "Count the whole film", disabled: busy, onClick: (e) => this.send(e.currentTarget, game, null) }) : null;
    setChildren(this.box,
      el("details", { open: !game.has_analysis || marked ? "" : null },
        el("summary", {}, el("strong", { text: "Game time" }), el("span", { class: "small muted", text: marked ? `  Only ${game.play_ranges.map((r) => `${formatClock(r.start_s)}-${formatClock(r.end_s)}`).join(" and ")} counts` : "  The whole film counts, warm-ups included" })),
        el("p", { class: "hint", text: "Mark where the game is on the film so warm-ups and halftime are left out of the stats. Play the film to the moment and click Use film time, or type minutes:seconds. Set before the analysis, only the game goes to the GPU, which is faster." }),
        el("div", { class: "game-time-grid" }, rows),
        this.error,
        el("div", { class: "row" }, save, clear)));
  }

  async save(button, game) {
    const marks = {};
    for (const [key, label] of MARKS) {
      const text = this.inputs[key].value.trim();
      marks[key] = text ? parseClock(text) : null;
      if (text && marks[key] === null) {
        setChildren(this.error, errorBox({ info: { title: "Check the time", message: `"${label}" is not a time. Type minutes:seconds, for example 12:30.` } }));
        return;
      }
    }
    const ranges = rangesFromMarks(marks, this.player.video?.duration);
    if (typeof ranges === "string") {
      setChildren(this.error, errorBox({ info: { title: "Check the marks", message: ranges } }));
      return;
    }
    await this.send(button, game, ranges);
  }

  async send(button, game, ranges) {
    await withBusy(button, "Saving…", async () => {
      try {
        const saved = await api.patch(gamePath(this.gameId), { play_ranges: ranges });
        toast(ranges ? "Game time saved" : "The whole film counts again");
        await this.onSaved(saved);
      } catch (err) {
        setChildren(this.error, errorBox(err));
      }
    });
  }
}
