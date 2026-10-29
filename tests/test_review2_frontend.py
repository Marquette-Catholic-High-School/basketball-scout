"""Regression tests from the second frontend review round.

They reuse the node fake-DOM harness of ``tests/test_review_frontend.py``: the real page
scripts run against the real HTML, ``fetch`` / ``XMLHttpRequest`` are answered by fake
routes, and timers are shortened to 1 ms.
"""

from __future__ import annotations

import json

import pytest

from tests.test_review_frontend import UPLOAD_ROUTES_JS, run_page

# Fixtures and probes for the game-page tests.
GAME_JS = """
const event = { id: "e1", t: 30, frame: 900, type: "shot_made", label: "2PT Make", side: "scouted",
  player: player("3", "Smith"), secondary_player: null, possession_side: "scouted", possession_id: 1, points: 2,
  zone: "paint", subzone: null, confidence: 0.9, play_id: null, score_scouted: 2, score_other: 0, description: "" };
const calibration = { points: [], matrix: [[0.05, 0, 0], [0, -0.05, 54], [0, 0, 1]], reprojection_error_ft: 0.8,
  frame_t: 12, video_width: 1280, video_height: 720, created_at: null };
const freeThrows = { code: "FREE_THROWS_NOT_DETECTED", message: "Free throws could not be detected", severity: "warning" };
const quality = (warnings) => ({ homography_available: true, coord_mode: "court", warnings, unmatched_jerseys: [] });
const freeThrowWarning = () => $$("#quality-body .notice").find((n) => textOf(n).includes("FREE_THROWS_NOT_DETECTED"));
const confirms = [];
page.window.confirm = (message) => { confirms.push(message); return globalThis.confirmAnswer ?? true; };
const posts = [];
/** Every src the <video> element is given. */
const srcs = [];
const video = byId("video");
const srcProp = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(video), "src");
Object.defineProperty(video, "src", {
  get() { return srcProp.get.call(this); },
  set(value) { srcs.push(String(value)); srcProp.set.call(this, value); },
});
"""

# Court landmarks (feet) and a canvas context that records what the calibration layer draws.
CALIBRATION_JS = """
const landmarks = { left_baseline_near_corner: [0, 0], right_baseline_near_corner: [84, 0],
  left_baseline_far_corner: [0, 50], right_baseline_far_corner: [84, 50], center: [42, 25] };
const drawCalls = [];
const recorder = {};
for (const name of ["setTransform", "clearRect", "fillRect", "beginPath", "rect", "clip", "save", "restore",
  "stroke", "moveTo", "lineTo", "fillText"]) {
  recorder[name] = (...args) => drawCalls.push([name, ...args]);
}
/** The calls of the latest drawing of the calibration layer. */
const lastDrawing = () => drawCalls.slice(drawCalls.map((c) => c[0]).lastIndexOf("clearRect"));
const round1 = (v) => Math.round(v * 10) / 10;
/** Show the film at 640x360 on the page and open the calibration panel. */
async function openCalibration() {
  for (const id of ["video", "calibration-layer"]) byId(id).rect = { left: 0, top: 0, width: 640, height: 360 };
  byId("calibration-layer").getContext = () => recorder;
  byId("calibrate-btn").click();
  await settle();
}
const clickFrame = (x, y) => fire(byId("calibration-layer"), "click", { clientX: x, clientY: y });
"""


# ---------------------------------------------------------------------------
# 1. Full re-analysis
# ---------------------------------------------------------------------------


def test_full_reanalysis_sends_the_film_to_the_gpu_again_and_keeps_the_results(tmp_path):
    """README: after calibrating, "choose Full re-analysis (it sends the film to the GPU
    again, with your calibration)". The game page only had Re-run analysis (REANALYZE)."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + """
let started = false;
let status = "queued";
gamePageRoutes(route, json, {
  gameBody: () => game(started ? { status: status === "succeeded" ? "ready" : "processing", latest_job_id: "j_2" } : {}),
  analysisBody: analysis({ timeline: [event] }),
});
route("GET", "/api/games/g_1/jobs", () => json(started ? [job({ id: "j_2", status })] : []));
route("POST", "/api/games/g_1/jobs", (req) => { posts.push(req.body); started = true; return json(job({ id: "j_2" }), 201); });
route("GET", "/api/jobs/j_2", () => json(job({ id: "j_2", status, stage: status === "succeeded" ? "done" : "gpu_processing",
  progress: status === "succeeded" ? 100 : 12 })));
await import("./js/game.js");
await settle();
const full = byId("full-analysis-btn");
const before = { shown: !full.hidden, disabled: full.disabled, rerun: textOf(byId("reanalyze-btn")) };
full.click();
status = "running";
await settle();
const during = {
  panel: textOf($("#job-panel h2")),
  rows: $$("#timeline-body tr[data-i]").length,
  tabsShown: !byId("analysis-tabs-wrap").hidden,
  rerunDisabled: byId("reanalyze-btn").disabled,
  fullDisabled: full.disabled,
};
status = "succeeded";
await settle();
const after = { panelShown: !byId("job-panel").hidden, rerunDisabled: byId("reanalyze-btn").disabled,
  fullDisabled: full.disabled, badge: textOf($("#game-meta .badge")) };
console.log(JSON.stringify({ before, posts, confirms, during, after }));
""",
    )
    assert out["before"] == {"shown": True, "disabled": False, "rerun": "Re-run analysis"}
    assert out["posts"] == [{"kind": "analyze"}]
    [message] = out["confirms"]
    assert "GPU again" in message
    assert "about as long as the first run" in message
    assert "another GPU run" in message
    # The old results stay while the GPU works, and the job panel tracks the run.
    assert out["during"] == {
        "panel": "Film analysis in progress",
        "rows": 1,
        "tabsShown": True,
        "rerunDisabled": True,
        "fullDisabled": True,
    }
    assert out["after"] == {"panelShown": False, "rerunDisabled": False, "fullDisabled": False, "badge": "Ready"}


@pytest.mark.parametrize(
    ("over", "shown"),
    [
        ({}, True),  # uploaded film + analysis
        ({"has_video": False, "video_url": "https://example.com/film.mp4", "has_annotated_video": True}, True),
        ({"has_analysis": False, "status": "uploaded"}, False),  # nothing to re-run yet: "Analyze film"
        ({"has_video": False, "video_url": None, "has_annotated_video": True}, False),  # no film left to send
    ],
    ids=["upload", "link", "no-analysis", "no-film"],
)
def test_full_reanalysis_is_offered_for_film_with_an_analysis(tmp_path, over, shown):
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"""
const over = {json.dumps(over)};
gamePageRoutes(route, json, {{ gameBody: game(over), analysisBody: over.has_analysis === false ? null : analysis() }});
await import("./js/game.js");
await settle();
console.log(JSON.stringify({{ shown: !byId("full-analysis-btn").hidden }}));
""",
    )
    assert out["shown"] is shown


def test_full_reanalysis_needs_the_coachs_ok_and_rerun_keeps_its_meaning(tmp_path):
    """Declining the confirm sends nothing; Re-run analysis still starts a REANALYZE."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + """
gamePageRoutes(route, json, { gameBody: game(), analysisBody: analysis() });
route("POST", "/api/games/g_1/jobs", (req) => { posts.push(req.body); return json(job({ id: "j_2", kind: req.body.kind }), 201); });
await import("./js/game.js");
await settle();
globalThis.confirmAnswer = false;
byId("full-analysis-btn").click();
await settle();
const declined = { posts: posts.length, fullDisabled: byId("full-analysis-btn").disabled };
byId("reanalyze-btn").click();
await settle();
console.log(JSON.stringify({ declined, posts }));
""",
    )
    assert out["declined"] == {"posts": 0, "fullDisabled": False}
    assert out["posts"] == [{"kind": "reanalyze"}]


def test_free_throw_warning_offers_full_reanalysis_when_the_court_is_calibrated(tmp_path):
    """FREE_THROWS_NOT_DETECTED + a calibration: only a GPU run finds the free throws, so
    the warning on the Data quality tab carries the Full re-analysis button."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + """
let started = false;
gamePageRoutes(route, json, {
  gameBody: () => game(started ? { calibration, status: "queued", latest_job_id: "j_2" } : { calibration }),
  analysisBody: analysis({ data_quality: quality([freeThrows]) }),
});
route("GET", "/api/games/g_1/jobs", () => json(started ? [job({ id: "j_2" })] : []));
route("GET", "/api/jobs/j_2", json(job({ id: "j_2" })));
route("POST", "/api/games/g_1/jobs", (req) => { posts.push(req.body); started = true; return json(job({ id: "j_2" }), 201); });
await import("./js/game.js");
await settle();
const button = freeThrowWarning().querySelector("button");
const offered = { text: textOf(button), primary: button.classList.contains("btn-primary") };
button.click();
await settle();
console.log(JSON.stringify({ offered, posts, confirms: confirms.length, busyDisabled: freeThrowWarning().querySelector("button").disabled }));
""",
    )
    assert out["offered"] == {"text": "Full re-analysis", "primary": True}
    assert out["confirms"] == 1
    assert out["posts"] == [{"kind": "analyze"}]
    assert out["busyDisabled"] is True  # redrawn while the new run is queued


def test_free_throw_warning_without_a_calibration_has_no_full_reanalysis_button(tmp_path):
    """Without a calibration the GPU would miss them again: the warning says to calibrate
    first (guard)."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + """
gamePageRoutes(route, json, { gameBody: game(), analysisBody: analysis({ data_quality: quality([freeThrows]) }) });
await import("./js/game.js");
await settle();
console.log(JSON.stringify({ buttons: freeThrowWarning().querySelectorAll("button").length }));
""",
    )
    assert out["buttons"] == 0


def test_saving_a_calibration_brings_up_full_reanalysis_without_a_reload(tmp_path):
    """The Data quality tab kept the calibration the page was loaded with, so the button
    that needs one only appeared after a reload; and the calibration result offered only
    Re-run analysis, which cannot find free throws."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + CALIBRATION_JS
        + """
gamePageRoutes(route, json, { gameBody: game(), analysisBody: analysis({ data_quality: quality([freeThrows]) }) });
route("GET", "/api/court/landmarks", json({ court: {}, landmarks }));
route("PUT", "/api/games/g_1/calibration", (req) => json({ ...calibration, points: req.body.points }));
route("DELETE", "/api/games/g_1/calibration", { status: 204 });
await import("./js/game.js");
await settle();
await openCalibration();
for (const [x, y] of [[20, 300], [600, 300], [60, 40], [560, 40]]) clickFrame(x, y);
byId("cal-save").click();
await settle();
const saved = {
  calibrationShown: textOf(byId("quality-body")).includes("Manual calibration saved"),
  warningButtons: freeThrowWarning().querySelectorAll("button").map(textOf),
  result: $$("#cal-result button").map(textOf),
  primary: $$("#cal-result button.btn-primary").map(textOf),
};
byId("cal-delete").click();
await settle();
const removed = {
  calibrationShown: textOf(byId("quality-body")).includes("Manual calibration saved"),
  warningButtons: freeThrowWarning().querySelectorAll("button").map(textOf),
};
console.log(JSON.stringify({ saved, removed }));
""",
    )
    assert out["saved"] == {
        "calibrationShown": True,
        "warningButtons": ["Full re-analysis"],
        "result": ["Re-run analysis", "Full re-analysis"],
        "primary": ["Full re-analysis"],
    }
    assert out["removed"] == {"calibrationShown": False, "warningButtons": []}


def test_player_loads_the_new_annotated_copy_when_a_gpu_run_finishes(tmp_path):
    """A full re-analysis replaces annotated.mp4 under the same URL; the open page kept
    playing the old file, whose overlay no longer matched the new timeline."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + """
let finished = false;
gamePageRoutes(route, json, {
  gameBody: () => game({ has_annotated_video: true, latest_job_id: "j_1", status: finished ? "ready" : "processing" }),
  analysisBody: analysis({ timeline: [event] }),
});
const state = () => (finished ? { status: "succeeded", stage: "done", progress: 100 } : { status: "running", stage: "gpu_processing", progress: 40 });
route("GET", "/api/games/g_1/jobs", () => json([job(state())]));
route("GET", "/api/jobs/j_1", () => json(job(state())));
await import("./js/game.js");
await settle();
video.currentTime = 42;
const before = [...srcs];
finished = true;
await settle();
console.log(JSON.stringify({ before, srcs, time: video.currentTime }));
""",
    )
    annotated = "/api/games/g_1/video?variant=annotated"
    assert out["before"] == [annotated]
    assert out["srcs"] == [annotated, annotated]  # loaded again; the server sends it with no-cache
    assert out["time"] == 42  # ...at the same point of the film


def test_reanalysis_on_the_server_does_not_reload_the_film(tmp_path):
    """REANALYZE leaves the annotated copy alone, so the player keeps what it buffered (guard)."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + """
let finished = false;
gamePageRoutes(route, json, {
  gameBody: () => game({ has_annotated_video: true, latest_job_id: "j_1", status: finished ? "ready" : "processing" }),
  analysisBody: analysis(),
});
const state = () => ({ kind: "reanalyze", ...(finished ? { status: "succeeded", stage: "done" } : { status: "running", stage: "analyzing" }) });
route("GET", "/api/games/g_1/jobs", () => json([job(state())]));
route("GET", "/api/jobs/j_1", () => json(job(state())));
await import("./js/game.js");
await settle();
finished = true;
await settle();
console.log(JSON.stringify({ srcs }));
""",
    )
    assert out["srcs"] == ["/api/games/g_1/video?variant=annotated"]


# ---------------------------------------------------------------------------
# 2. Court calibration saved on a copy of another size
# ---------------------------------------------------------------------------

# Saved on the 1920x1080 original, where feet = (x / 20, (1080 - y) / 18). The fake video
# plays at 1280x720 (the annotated copy), shown at half size (640x360) on the page.
SAVED_ON_ORIGINAL_JS = """
const names = ["left_baseline_near_corner", "right_baseline_near_corner", "left_baseline_far_corner", "right_baseline_far_corner"];
const onOriginal = ([x, y]) => [x * 20, 1080 - y * 18];
const saved = { ...calibration, matrix: [[0.05, 0, 0], [0, -1 / 18, 60], [0, 0, 1]], video_width: 1920, video_height: 1080,
  points: names.map((landmark) => ({ landmark, px: onOriginal(landmarks[landmark]) })) };
gamePageRoutes(route, json, { gameBody: game({ calibration: saved }), analysisBody: analysis() });
route("GET", "/api/court/landmarks", json({ court: {}, landmarks }));
const puts = [];
route("PUT", "/api/games/g_1/calibration", (req) => { puts.push(req.body); return json({ ...saved, ...req.body }); });
await import("./js/game.js");
await settle();
await openCalibration();
"""


def test_calibration_saved_on_another_copy_is_drawn_at_the_loaded_size(tmp_path):
    """Saved on the full-size original (Safari) and opened on the 720p copy (Chrome): the
    crosses and the projected court lines were drawn 1.5 times too far out."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + CALIBRATION_JS
        + SAVED_ON_ORIGINAL_JS
        + """
const drawing = lastDrawing();
const crosses = drawing.filter((c) => c[0] === "fillText").map(([, text, x, y]) => [text, round1(x - 13), round1(y + 9)]);
const outline = drawing.find((c) => c[0] === "moveTo").slice(1).map(round1);
console.log(JSON.stringify({ list: $$("#cal-points li .mono").map(textOf), crosses, outline }));
""",
    )
    assert out["list"] == ["(0, 720)", "(1120, 720)", "(0, 120)", "(1120, 120)"]
    # Crosses on the 640x360 picture: half of the 1280x720 pixels.
    assert out["crosses"] == [["1", 0, 360], ["2", 560, 360], ["3", 0, 60], ["4", 560, 60]]
    # The court outline starts at the near left corner, (0, 0) ft: the bottom left of the picture.
    assert out["outline"] == [0, 360]


def test_points_added_to_a_rescaled_calibration_are_saved_in_one_pixel_size(tmp_path):
    """A point clicked on the 720p copy was mixed with points in 1080p pixels, and the lot
    was saved as 1280x720."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + CALIBRATION_JS
        + SAVED_ON_ORIGINAL_JS
        + """
byId("cal-landmark").value = "center";
clickFrame(280, 210); // the centre of the court, (42, 25) ft
byId("cal-save").click();
await settle();
console.log(JSON.stringify({ puts }));
""",
    )
    [body] = out["puts"]
    assert (body["video_width"], body["video_height"]) == (1280, 720)
    assert [p["px"] for p in body["points"]] == [[0, 720], [1120, 720], [0, 120], [1120, 120], [560, 420]]


def test_calibration_without_a_saved_size_is_drawn_as_saved(tmp_path):
    """Older calibrations have no video size: their points are taken as they are (guard)."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + CALIBRATION_JS
        + """
const saved = { ...calibration, video_width: null, video_height: null,
  points: [{ landmark: "left_baseline_near_corner", px: [10, 700] }, { landmark: "center", px: [640, 360] }] };
gamePageRoutes(route, json, { gameBody: game({ calibration: saved }), analysisBody: analysis() });
route("GET", "/api/court/landmarks", json({ court: {}, landmarks }));
await import("./js/game.js");
await settle();
await openCalibration();
console.log(JSON.stringify({ list: $$("#cal-points li .mono").map(textOf) }));
""",
    )
    assert out["list"] == ["(10, 700)", "(640, 360)"]


# ---------------------------------------------------------------------------
# 3. Upload stall watchdog
# ---------------------------------------------------------------------------

UPLOAD_LOG_JS = """
const uploadLog = () => server.log.filter((r) => r.includes("/uploads"));
route("POST", "/api/uploads/u_1/complete", json({ game: game(), job: job() }));
"""

# A fake clock for the stall watchdog: upload.js exports its timers for tests.
WATCHDOG_JS = (
    UPLOAD_LOG_JS
    + """
const uploadModule = await import("./js/upload.js");
const timers = [];
uploadModule.watchdogTimers.set = (fn, ms) => { timers.push({ fn, ms, live: true }); return timers.length - 1; };
uploadModule.watchdogTimers.clear = (id) => { if (timers[id]) timers[id].live = false; };
const live = () => timers.filter((t) => t.live);
await settle();
"""
)


def test_stalled_chunk_is_aborted_and_resumed_from_the_server(tmp_path):
    """A connection that died silently left the upload at the same percentage until the OS
    gave up on it; after 60 s without progress the chunk is sent again from what the
    server has."""
    out = run_page(
        tmp_path,
        "upload.html",
        "/upload?game=g_1",
        UPLOAD_ROUTES_JS
        + WATCHDOG_JS
        + """
let dead = true;
route("PUT", /^\\/api\\/uploads\\/u_\\d+\\/chunk$/, (req) => {
  if (dead) { dead = false; return new Promise(() => {}); } // no answer and no progress, ever
  return chunk(req);
});
drop();
await settle();
const stalled = { watchdogs: live().map((t) => t.ms), log: uploadLog() };
live()[0].fn(); // a minute goes by without upload progress
await settle();
console.log(JSON.stringify({ stalled, log: uploadLog(), live: live().length, navigatedTo: page.window.navigatedTo || null,
  error: textOf(byId("upload-error")) }));
""",
    )
    assert out["stalled"] == {
        "watchdogs": [60000],
        "log": ["POST /api/games/g_1/uploads", "PUT /api/uploads/u_1/chunk?offset=0"],
    }
    assert out["log"] == [
        "POST /api/games/g_1/uploads",
        "PUT /api/uploads/u_1/chunk?offset=0",
        "GET /api/uploads/u_1",  # how much did the server keep?
        "PUT /api/uploads/u_1/chunk?offset=0",
        "PUT /api/uploads/u_1/chunk?offset=4",
        "PUT /api/uploads/u_1/chunk?offset=8",
        "POST /api/uploads/u_1/complete?auto_start=true",
    ]
    assert out["live"] == 0  # no watchdog left running
    assert out["error"] == ""
    assert out["navigatedTo"] == "/games/g_1"


def test_upload_that_keeps_stalling_stops_with_resume(tmp_path):
    """After the usual 8 retries a dead connection ends in an error the coach can act on."""
    out = run_page(
        tmp_path,
        "upload.html",
        "/upload?game=g_1",
        UPLOAD_ROUTES_JS
        + WATCHDOG_JS
        + """
route("PUT", /^\\/api\\/uploads\\/u_\\d+\\/chunk$/, () => new Promise(() => {}));
drop();
await settle();
let stalls = 0;
while (live().length && stalls < 20) {
  live()[0].fn();
  stalls += 1;
  await settle();
}
console.log(JSON.stringify({ stalls, ...upload(), message: textOf($$("#upload-error .notice p")[0]) }));
""",
    )
    assert out["stalls"] == 9  # the first try and 8 retries
    assert out["error"] == "The upload stalled"
    assert out["message"] == "Nothing reached the server for 60 seconds."
    assert out["actions"] == ["Resume upload"]
    assert out["resumeShown"] is True


def test_upload_progress_keeps_a_slow_chunk_alive(tmp_path):
    """Every progress event restarts the 60 s count, so a slow connection that still
    sends is never cut off."""
    out = run_page(
        tmp_path,
        "upload.html",
        "/upload?game=g_1",
        UPLOAD_ROUTES_JS
        + WATCHDOG_JS
        + """
const Base = globalThis.XMLHttpRequest;
let slow = null;
globalThis.XMLHttpRequest = class extends Base {
  send(body) {
    if (slow) return super.send(body);
    slow = { xhr: this, body }; // the first chunk goes out slowly
  }
};
drop();
await settle();
const first = live().length;
slow.xhr.upload.onprogress({ loaded: 2, total: 4 });
const afterProgress = { armed: timers.length, live: live().length, firstLive: timers[0].live };
Base.prototype.send.call(slow.xhr, slow.body);
await settle();
console.log(JSON.stringify({ first, afterProgress, log: uploadLog(), navigatedTo: page.window.navigatedTo || null }));
""",
    )
    assert out["first"] == 1
    assert out["afterProgress"] == {"armed": 2, "live": 1, "firstLive": False}
    assert "GET /api/uploads/u_1" not in out["log"]  # never aborted
    assert out["navigatedTo"] == "/games/g_1"


def test_chunk_dropped_by_the_server_resumes_from_received(tmp_path):
    """The server drops a chunk that sent nothing for 120 s with 409 UPLOAD_INCOMPLETE and
    the current upload; the page resumes from its received (guard)."""
    out = run_page(
        tmp_path,
        "upload.html",
        "/upload?game=g_1",
        UPLOAD_ROUTES_JS
        + UPLOAD_LOG_JS
        + """
await import("./js/upload.js");
await settle();
let dropped = false;
route("PUT", /^\\/api\\/uploads\\/u_\\d+\\/chunk$/, (req) => {
  if (req.query.offset === "4" && !dropped) {
    dropped = true;
    return { status: 409, json: { error: { code: "UPLOAD_INCOMPLETE", title: "Upload incomplete",
      message: "The connection went quiet.", hint: null, retryable: false, detail: null }, upload: sessions.u_1 } };
  }
  return chunk(req);
});
drop();
await settle();
console.log(JSON.stringify({ log: uploadLog(), navigatedTo: page.window.navigatedTo || null, error: textOf(byId("upload-error")) }));
""",
    )
    assert out["log"] == [
        "POST /api/games/g_1/uploads",
        "PUT /api/uploads/u_1/chunk?offset=0",
        "PUT /api/uploads/u_1/chunk?offset=4",
        "PUT /api/uploads/u_1/chunk?offset=4",
        "PUT /api/uploads/u_1/chunk?offset=8",
        "POST /api/uploads/u_1/complete?auto_start=true",
    ]
    assert out["error"] == ""
    assert out["navigatedTo"] == "/games/g_1"


# ---------------------------------------------------------------------------
# 4. Small UX fixes
# ---------------------------------------------------------------------------

LINK_GAME = '{ has_video: false, video_url: "https://example.com/film.mp4", has_annotated_video: true }'


def test_game_added_by_link_offers_to_replace_its_film(tmp_path):
    """(a) The header said "Add film" for a game whose film is a video link."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"""
gamePageRoutes(route, json, {{ gameBody: game({LINK_GAME}), analysisBody: analysis() }});
await import("./js/game.js");
await settle();
console.log(JSON.stringify({{ film: textOf(byId("film-link")), noFilmShown: !byId("no-film").hidden }}));
""",
    )
    assert out == {"film": "Replace film", "noFilmShown": False}


def test_upload_page_for_a_game_added_by_link_warns_that_its_film_is_replaced(tmp_path):
    """(a) The upload page also said "Add film" and gave no warning that the link's film goes."""
    out = run_page(
        tmp_path,
        "upload.html",
        "/upload?game=g_1",
        f"""
route("GET", "/api/health", json({{ status: "ok", max_upload_bytes: 1e12 }}));
route("GET", "/api/games/g_1", json(game({LINK_GAME})));
await import("./js/upload.js");
await settle();
console.log(JSON.stringify({{
  title: textOf(byId("upload-title")),
  notice: textOf($("#film-notices .notice-title")),
  detail: textOf($("#film-notices .notice p")),
}}));
""",
    )
    assert out == {
        "title": "Replace film",
        "notice": "This game already has film",
        "detail": "New film replaces the film from the video link and runs the analysis again.",
    }


def test_games_list_offers_add_film_only_for_games_without_film(tmp_path):
    """(a) The games list showed "Add film" for a game added by link."""
    out = run_page(
        tmp_path,
        "index.html",
        "/",
        f"""
route("GET", "/api/games", json([game({LINK_GAME}),
  game({{ id: "g_2", has_video: false, has_analysis: false, status: "draft", video_filename: null, display_title: "Draft" }})]));
route("GET", "/api/health", json({{ status: "ok", version: "1", processor: "mock", queue_backend: "sqlite", queue_ok: true,
  worker_last_seen_s: 5, claude_configured: true, ffmpeg_available: true }}));
await import("./js/index.js");
await settle();
console.log(JSON.stringify({{ actions: $$("#games-list article").map((card) => card.querySelectorAll(".game-actions a").map(textOf)) }}));
""",
    )
    assert out["actions"] == [["Open", "Roster"], ["Open", "Roster", "Add film"]]


FIRST_ANALYSIS_JS = """
let finished = false;
gamePageRoutes(route, json, {
  gameBody: () => game(finished ? { has_annotated_video: true, latest_job_id: "j_1" }
    : { status: "processing", has_analysis: false, latest_job_id: "j_1" }),
  analysisBody: analysis({ timeline: [event] }),
});
const state = () => (finished ? { status: "succeeded", stage: "done", progress: 100 } : { status: "running", stage: "gpu_processing", progress: 40 });
route("GET", "/api/games/g_1/jobs", () => json([job(state())]));
route("GET", "/api/jobs/j_1", () => json(job(state())));
"""
LOAD_GAME_JS = """
await import("./js/game.js");
await settle();
"""


def test_player_switches_to_the_annotated_copy_when_the_first_analysis_finishes(tmp_path):
    """(b) Film uploaded and the page left open: when the analysis finished, the player
    stayed on the original although the annotated copy was there now."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + FIRST_ANALYSIS_JS
        + LOAD_GAME_JS
        + """
video.currentTime = 15;
const before = [...srcs];
finished = true;
await settle();
console.log(JSON.stringify({ before, srcs, annotatedPressed: byId("variant-annotated").getAttribute("aria-pressed"),
  time: video.currentTime }));
""",
    )
    assert out["before"] == ["/api/games/g_1/video?variant=original"]
    assert out["srcs"] == ["/api/games/g_1/video?variant=original", "/api/games/g_1/video?variant=annotated"]
    assert out["annotatedPressed"] == "true"
    assert out["time"] == 15


def test_player_keeps_the_version_the_coach_picked(tmp_path):
    """(b) ...unless the coach chose the original (guard)."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + FIRST_ANALYSIS_JS
        + LOAD_GAME_JS
        + """
byId("variant-original").click();
finished = true;
await settle();
console.log(JSON.stringify({ srcs, annotatedEnabled: !byId("variant-annotated").disabled }));
""",
    )
    assert out["srcs"] == ["/api/games/g_1/video?variant=original"]
    assert out["annotatedEnabled"] is True


def test_player_stays_on_the_frame_being_calibrated(tmp_path):
    """(b) ...or while the coach clicks court landmarks on the original (guard)."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + CALIBRATION_JS
        + FIRST_ANALYSIS_JS
        + """
route("GET", "/api/court/landmarks", json({ court: {}, landmarks }));
"""
        + LOAD_GAME_JS
        + """
await openCalibration();
finished = true;
await settle();
console.log(JSON.stringify({ srcs, calibrating: !byId("calibration-panel").hidden }));
""",
    )
    assert out == {"srcs": ["/api/games/g_1/video?variant=original"], "calibrating": True}


@pytest.mark.parametrize(
    ("status", "last_seen", "expected"),
    [
        ("queued", "null", "The background worker is not running - start basketball-scout-worker."),
        ("queued", "600", "The background worker was last seen 10 min ago - it may have stopped."),
        ("queued", "12", None),
        ("running", "null", None),  # a worker has the job
    ],
    ids=["queued-no-worker", "queued-stale-worker", "queued-worker-ok", "running"],
)
def test_queued_job_says_when_the_worker_is_not_running(tmp_path, status, last_seen, expected):
    """(c) Only the games list showed the worker status: on the game page a job just sat
    at "Waiting for the background worker"."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"""
const current = job({{ status: "{status}", stage: "{status}" === "queued" ? "queued" : "preparing" }});
gamePageRoutes(route, json, {{ gameBody: game({{ status: "queued", has_analysis: false, latest_job_id: "j_1" }}), jobs: [current] }});
route("GET", "/api/jobs/j_1", json(current));
route("GET", "/api/health", json({{ status: "degraded", queue_ok: true, claude_configured: true, max_upload_bytes: 1e12,
  worker_last_seen_s: {last_seen} }}));
await import("./js/game.js");
await settle();
const warning = $("#job-panel .notice");
console.log(JSON.stringify({{
  title: warning ? textOf(warning.querySelector(".notice-title")) : null,
  hint: warning ? textOf(warning.querySelector(".notice-hint")) : null,
  stage: textOf($("#job-panel .job-stage")),
  healthChecks: server.log.filter((r) => r === "GET /api/health").length,
}}));
""",
    )
    assert out["title"] == expected
    if expected:
        assert "basketball-scout-worker" in out["hint"]
        assert out["stage"] == "Waiting for the background worker"
    assert out["healthChecks"] <= 2  # the page load and one check, not one per 3 s poll


# ---------------------------------------------------------------------------
# Other defects found on the way
# ---------------------------------------------------------------------------


def test_plays_list_with_no_plays_does_not_blame_the_filters(tmp_path):
    """Like the timeline: with no plays at all the list said "No plays match these filters"."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + """
gamePageRoutes(route, json, { gameBody: game(), analysisBody: analysis({ plays: [] }) });
await import("./js/game.js");
await settle();
console.log(JSON.stringify({ text: textOf($("#plays-body td")), count: textOf(byId("plays-count")) }));
""",
    )
    assert out == {"text": "No plays were recognised in this film.", "count": "0 of 0 plays"}
