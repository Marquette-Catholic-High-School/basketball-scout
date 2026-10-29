"""Verification of the second review round in the frontend and ops/outputs areas.

Regression tests for what the verification fixed (the annotated copy after a GPU run that
failed once its results were installed; the FastScout free-throw note leaving out PF) and
guards for the checks the round asked for: a double click on Full re-analysis starts one
job, a calibration saved on one copy of the film survives a save and a switch to a copy of
another size, and uninstall.sh never picks a system folder, or a path outside the code
folder that it cannot place, as OHV_HOME to delete.
"""

from __future__ import annotations

import pytest

from scout.export import fastscout
from scout.schemas import PipelineWarning
from tests.test_export_fastscout import make_analysis, make_roster
from tests.test_review2_frontend import CALIBRATION_JS, GAME_JS, SAVED_ON_ORIGINAL_JS
from tests.test_review_frontend import run_page
from tests.test_review_ops import needs_bash, script_env, source_script

ANNOTATED = "/api/games/g_1/video?variant=annotated"

# ---------------------------------------------------------------------------
# Frontend: the annotated copy after a GPU run that failed later on
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("stage", "reloaded"),
    [("analyzing", True), ("reporting", True), ("gpu_processing", False)],
    ids=["failed-after-the-gpu-results", "failed-writing-the-report", "failed-on-the-gpu"],
)
def test_player_reloads_the_annotated_copy_a_failed_gpu_run_installed(tmp_path, stage, reloaded):
    """The worker puts the new annotated.mp4 in place before the analysis step. When that step
    failed, the open page kept the old file, and after Retry (a REANALYZE, which keeps the new
    copy) it played the old overlay under the new timeline. A run that failed on the GPU left
    the copy alone, so the player keeps what it buffered."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"""
let failed = false;
gamePageRoutes(route, json, {{
  gameBody: () => game({{ has_annotated_video: true, latest_job_id: "j_1", status: failed ? "failed" : "processing" }}),
  analysisBody: analysis({{ timeline: [event] }}),
}});
const error = {{ code: "INTERNAL_ERROR", title: "Something went wrong", message: "Boom.", hint: null, retryable: true, detail: null }};
const state = () => (failed ? {{ status: "failed", stage: "{stage}", error }} : {{ status: "running", stage: "gpu_processing", progress: 40 }});
route("GET", "/api/games/g_1/jobs", () => json([job(state())]));
route("GET", "/api/jobs/j_1", () => json(job(state())));
await import("./js/game.js");
await settle();
video.currentTime = 42;
failed = true;
await settle();
console.log(JSON.stringify({{ srcs, time: video.currentTime, error: textOf($("#job-panel .notice-title")) }}));
""",
    )
    assert out["error"] == "Something went wrong"  # the job really ended, with its Retry
    assert out["srcs"] == ([ANNOTATED, ANNOTATED] if reloaded else [ANNOTATED])
    assert out["time"] == 42


# ---------------------------------------------------------------------------
# Frontend guards
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "first", ['byId("full-analysis-btn")', 'freeThrowWarning().querySelector("button")'], ids=["header", "warning"]
)
def test_double_click_on_full_reanalysis_starts_one_job(tmp_path, first):
    """The confirm comes first and the buttons are disabled before the POST goes out, so the
    second click of a double click (which a browser does not deliver to a disabled button)
    sends nothing; once the job is queued every Full re-analysis button is disabled (guard)."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"const first = () => {first};\n"
        + """
let started = false;
gamePageRoutes(route, json, {
  gameBody: () => game(started ? { calibration, status: "queued", latest_job_id: "j_2" } : { calibration }),
  analysisBody: analysis({ data_quality: quality([freeThrows]) }),
});
route("GET", "/api/games/g_1/jobs", () => json(started ? [job({ id: "j_2" })] : []));
route("GET", "/api/jobs/j_2", json(job({ id: "j_2" })));
route("POST", "/api/games/g_1/jobs", async (req) => {
  posts.push(req.body);
  await new Promise((resolve) => setTimeout(resolve, 5)); // still on its way when the second click comes
  started = true;
  return json(job({ id: "j_2" }), 201);
});
await import("./js/game.js");
await settle();
const click = (button) => { if (!button.disabled) button.click(); };
click(first());
click(first()); // the second click of the double click, while the POST is on its way
await settle();
// Both buttons as the page shows them now (the warning is redrawn with the queued job).
for (const button of [byId("full-analysis-btn"), freeThrowWarning().querySelector("button")]) click(button);
await settle();
console.log(JSON.stringify({ posts, confirms: confirms.length, headerDisabled: byId("full-analysis-btn").disabled,
  warningDisabled: freeThrowWarning().querySelector("button").disabled }));
""",
    )
    assert out["posts"] == [{"kind": "analyze"}]
    assert out["confirms"] == 1
    assert out["headerDisabled"] is True and out["warningDisabled"] is True  # the job is queued now


def test_calibration_from_another_copy_survives_a_save_and_a_switch_of_copy(tmp_path):
    """Saved on the 1920x1080 original, opened on the 720p copy, saved again unchanged (the
    server fits a new matrix to the points it gets), then the full-size original plays: the
    court is drawn in the same place every time, and each save names the pixel size of its
    points (guard)."""
    # The fake server fits the matrix like the real one: feet = (x / 20, 60 - y / 18) in 1080p pixels.
    server_fits = SAVED_ON_ORIGINAL_JS.replace(
        "return json({ ...saved, ...req.body });",
        "const s = 1920 / req.body.video_width; "
        "return json({ ...saved, ...req.body, matrix: [[0.05 * s, 0, 0], [0, -s / 18, 60], [0, 0, 1]] });",
    )
    assert server_fits != SAVED_ON_ORIGINAL_JS
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + CALIBRATION_JS
        + server_fits
        + """
/** The near left corner, (0, 0) ft, as a share of the picture: [0, 1] is its bottom left. */
const corner = () => {
  const [x, y] = lastDrawing().find((c) => c[0] === "moveTo").slice(1);
  const { width, height } = byId("video").rect;
  return [round1(x / width), round1(y / height)];
};
const list = () => $$("#cal-points li .mono").map(textOf);
const opened = { corner: corner(), list: list() };
byId("cal-save").click();
await settle();
byId("cal-close").click();
byId("calibrate-btn").click();
await settle();
const reopened = { corner: corner(), list: list() };
Object.assign(video, { videoWidth: 1920, videoHeight: 1080 }); // the full-size original takes over
for (const id of ["video", "calibration-layer"]) byId(id).rect = { left: 0, top: 0, width: 960, height: 540 };
fire(video, "loadedmetadata", { bubbles: false });
await settle();
const fullSize = { corner: corner(), list: list() };
byId("cal-save").click();
await settle();
const sizes = puts.map((p) => [p.video_width, p.video_height, p.points[1].px]);
console.log(JSON.stringify({ opened, reopened, fullSize, sizes }));
""",
    )
    in_720p = ["(0, 720)", "(1120, 720)", "(0, 120)", "(1120, 120)"]
    assert out["opened"] == {"corner": [0, 1], "list": in_720p}
    assert out["reopened"] == {"corner": [0, 1], "list": in_720p}
    assert out["fullSize"] == {"corner": [0, 1], "list": ["(0, 1080)", "(1680, 1080)", "(0, 180)", "(1680, 180)"]}
    assert out["sizes"] == [[1280, 720, [1120, 720]], [1920, 1080, [1680, 1080]]]


# ---------------------------------------------------------------------------
# uninstall.sh guard: what OHV_HOME may be deleted
# ---------------------------------------------------------------------------

RESOLVE_OHV = r"""
INSTALL_DIR=$1 DATA_DIR=$2 ENV_FILE="$1/.env"
resolve_ohv_dir
printf 'OHV_DIR=[%s] KEPT=[%s]\n' "$OHV_DIR" "$OHV_KEPT"
"""


@needs_bash
@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("/", "OHV_DIR=[/] KEPT=[a system folder]"),
        ("//", "OHV_DIR=[/] KEPT=[a system folder]"),
        ("/opt/", "OHV_DIR=[/opt] KEPT=[a system folder]"),
        ("/usr/local", "OHV_DIR=[/usr/local] KEPT=[a system folder]"),
        ("{ohv}/..", "OHV_DIR=[{ohv}/..] KEPT=[it does not look like an OpenHoopVision checkout]"),
        # Relative values are read from the code folder: deleted with it, never on their own.
        ("../openhoopvision", "OHV_DIR=[] KEPT=[]"),
        ("~/ohv", "OHV_DIR=[] KEPT=[]"),
        ("{ohv}/", "OHV_DIR=[{ohv}] KEPT=[]"),  # the real checkout: deleted
    ],
    ids=["root", "double-slash", "opt", "usr-local", "dot-dot", "relative-up", "tilde", "checkout"],
)
def test_uninstall_only_deletes_an_ohv_home_it_can_place(tmp_path, value, expected):
    code = tmp_path / "opt" / "basketball-scout"
    (code / "scout").mkdir(parents=True)
    data = tmp_path / "var" / "lib" / "basketball-scout"
    data.mkdir(parents=True)
    ohv = tmp_path / "opt" / "openhoopvision"
    (ohv / ".git").mkdir(parents=True)
    (ohv / "main.py").write_text("# OpenHoopVision\n")
    (code / ".env").write_text(f"SCOUT_PROCESSOR=local\nOHV_HOME={value.format(ohv=ohv)}\n")
    result = source_script("uninstall.sh", RESOLVE_OHV, str(code), str(data), env=script_env(tmp_path))
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == expected.format(ohv=ohv)


# ---------------------------------------------------------------------------
# FastScout notes: what else goes missing with the free throws
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("code", ["FREE_THROWS_NOT_DETECTED", "EXTRA_EVENTS_FAILED"])
def test_free_throw_note_says_pf_misses_the_shooting_fouls(game, code):
    """The pipeline infers its shooting fouls from the free-throw trips (docs/TRACKING_SCHEMA.md:
    "free throws (and the shooting fouls inferred from them) could not be detected"), so the PF
    column of the paste is short as well; the note named FTM-A, FGM-A and PTS only."""
    analysis = make_analysis()
    analysis.data_quality.warnings.append(PipelineWarning(code=code, message="Free throws were not detected."))
    warnings = fastscout.paste_block_warnings(analysis, game, roster=make_roster(game.id))
    note = next(w for w in warnings if w.startswith("Free throws could not be detected"))
    assert "PF is missing the shooting fouls that sent players to the line." in note
    assert "FTM-A" in note and "FGM-A and PTS run high" in note and note.endswith("correct those columns in FastScout.")
