// "Check these shots" on the game page: only the shots a second check doubts (the ball was or was
// not seen going through the rim, against the GPU's call) and the ones the coach already called.
// Each row jumps the film to the shot; Made / Missed saves the coach's call
// (PUT /api/games/{id}/shots/{event_id}); "Update the box score" re-runs the analysis with them.

import { api, gamePath } from "./api.js";
import { byId, el, errorBox, formatClock, setChildren, show, toast, withBusy } from "./ui.js";

const PREROLL_S = 3; // start the film a moment before the release

const call = (made) => (made === true ? "Made" : made === false ? "Missed" : "Not sure");

export class ShotCheck {
  /** player: the film player (seek); onRerun(): start the re-analysis. */
  constructor({ gameId, player, onRerun }) {
    this.gameId = gameId;
    this.player = player;
    this.onRerun = onRerun;
    this.box = byId("shot-check");
    this.calls = {}; // event id -> made, as saved
    this.changed = 0; // calls saved since this analysis was built
  }

  render(game, analysis, names, { busy = false } = {}) {
    const shots = (analysis?.shots || []).filter((s) => s.needs_review || s.coach_made !== null && s.coach_made !== undefined);
    show(this.box, shots.length > 0);
    if (!shots.length) return;
    this.calls = { ...(game.shot_calls || {}) };
    this.busy = busy;
    this.changed = Object.entries(this.calls).filter(([id, made]) => (analysis.shots.find((s) => s.event_id === id)?.coach_made ?? null) !== made).length;
    const open = shots.filter((s) => s.needs_review).length;
    this.error = el("div", { "aria-live": "assertive" });
    this.rerun = el("button", { type: "button", class: "btn-primary", disabled: busy, onClick: (e) => this.update(e.currentTarget) });
    const rows = shots.sort((a, b) => a.t - b.t).map((shot) => this.row(shot, names, busy));
    setChildren(this.box,
      el("details", { open: open ? "" : null },
        el("summary", {},
          el("strong", { text: "Check these shots" }),
          el("span", { class: "small muted", text: open ? `  ${open} of ${analysis.shots.length} shots may be called wrong` : "  All checked" })),
        el("p", { class: "hint", text: "A second look at the ball and the rim disagrees with the GPU on these. Click the time to watch the shot, then say what happened. Only these need checking; the GPU and the second look agree on the rest." }),
        el("table", { class: "table-compact shot-check-table" },
          el("thead", {}, el("tr", {},
            ["Time", "Team", "Shooter", "GPU says", "Why check", "What happened"].map((h) => el("th", { scope: "col", text: h })))),
          el("tbody", {}, rows)),
        this.error,
        el("div", { class: "row" }, this.rerun)));
    this.updateButton();
  }

  row(shot, names, busy) {
    const status = el("span", { class: "small" });
    const choose = (made) => el("button", { type: "button", class: "btn-small", disabled: busy, "aria-pressed": "false", text: made ? "Made" : "Missed", onClick: (e) => this.save(shot, made, e.currentTarget, buttons, status) });
    const buttons = [choose(true), choose(false)];
    const current = this.calls[shot.event_id];
    this.mark(buttons, status, current);
    const kind = shot.is_three ? "3PT" : "2PT";
    return el("tr", { "data-shot": shot.event_id },
      el("td", {}, el("button", { type: "button", class: "btn-link", text: formatClock(shot.t), title: "Watch this shot", onClick: () => this.player.seek(Math.max(0, shot.t - PREROLL_S), { reveal: true }) })),
      el("td", {}, shot.side ? el("span", { class: `chip chip-${shot.side}`, text: names[shot.side] || shot.side }) : "–"),
      el("td", { text: `${shot.player?.label || "Unknown player"} · ${kind}` }),
      el("td", { text: call(shot.gpu_made) }),
      el("td", { class: "small muted", text: shot.review_reason || "" }),
      el("td", {}, el("div", { class: "btn-group" }, buttons), status));
  }

  mark(buttons, status, made) {
    buttons[0].setAttribute("aria-pressed", String(made === true));
    buttons[1].setAttribute("aria-pressed", String(made === false));
    status.textContent = made === undefined ? "" : ` You: ${call(made)}`;
  }

  async save(shot, made, button, buttons, status) {
    const path = gamePath(this.gameId, `/shots/${encodeURIComponent(shot.event_id)}`);
    const again = this.calls[shot.event_id] === made; // a second click on the same answer takes it back
    await withBusy(button, "…", async () => {
      try {
        const game = again ? await api.del(path) : await api.put(path, { made });
        this.calls = { ...(game.shot_calls || {}) };
        this.changed += 1;
        this.mark(buttons, status, this.calls[shot.event_id]);
        this.updateButton();
      } catch (err) {
        setChildren(this.error, errorBox(err));
      }
    });
    button.textContent = made ? "Made" : "Missed";
  }

  updateButton() {
    this.rerun.textContent = this.changed ? `Update the box score (${this.changed} ${this.changed === 1 ? "change" : "changes"})` : "Update the box score";
    this.rerun.disabled = this.busy || !this.changed;
  }

  async update(button) {
    await withBusy(button, "Starting…", async () => {
      await this.onRerun();
      toast("Updating the box score with your calls…");
    });
  }
}
