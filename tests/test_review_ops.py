"""Regression tests from the ops review: data folders kept inside the code folder, update.sh
--force keeping local config edits, the deploy/ notice before a restart, Modal deploys into
SCOUT_MODAL_ENVIRONMENT, the data-disk mount dependency, and docs that must match the code.

Like tests/test_ops.py these need no root, Linux, network or GPU: the scripts are sourced (their
main() does not run) and the system commands they would call are replaced by shell functions.
"""

from __future__ import annotations

import importlib
import inspect
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = ROOT / "scripts"
DOCS = ROOT / "docs"
BASH = shutil.which("bash")
GIT = shutil.which("git")
NO_USER = "scout-review-no-such-user"  # a service user that does not exist on the test machine

needs_bash = pytest.mark.skipif(BASH is None, reason="bash is not installed")
needs_git = pytest.mark.skipif(BASH is None or GIT is None, reason="bash and git are needed")


def script_env(tmp_path: Path) -> dict[str, str]:
    """No colours, no keys from the developer's shell, and git without their config or hooks."""
    empty = tmp_path / "empty.gitconfig"
    empty.touch()
    return {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(tmp_path),
        "NO_COLOR": "1",
        "GIT_CONFIG_GLOBAL": str(empty),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Review",
        "GIT_AUTHOR_EMAIL": "review@example.org",
        "GIT_COMMITTER_NAME": "Review",
        "GIT_COMMITTER_EMAIL": "review@example.org",
    }


def source_script(name: str, snippet: str, *args: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    """Run ``snippet`` in bash after sourcing scripts/``name`` (main() does not run); $1.. = args."""
    return subprocess.run(
        [BASH, "-c", f'source "$SCRIPT"; {snippet}', "test-review-ops", *args],
        capture_output=True,
        text=True,
        timeout=120,
        env={**env, "SCRIPT": str(SCRIPTS_DIR / name)},
        stdin=subprocess.DEVNULL,
    )


def git(cwd: Path, *args: str, env: dict[str, str]) -> str:
    return subprocess.run(
        [GIT, *args], cwd=cwd, env=env, check=True, capture_output=True, text=True
    ).stdout.strip()


# --- uninstall.sh / install.sh: games kept inside the code folder -------------------------------


@pytest.fixture
def code_folder(tmp_path):
    """A Basketball Scout checkout whose .env points at a RELATIVE data folder holding games."""
    folder = tmp_path / "opt" / "basketball-scout"
    (folder / "scout").mkdir(parents=True)
    (folder / "scout" / "main.py").write_text("# app\n")
    (folder / "data" / "games").mkdir(parents=True)
    (folder / "data" / "scout.db").write_bytes(b"SQLite format 3\x00")
    (folder / ".env").write_text("SCOUT_DATA_DIR=data\n")
    return folder


UNINSTALL_RESOLVE = (
    f"INSTALL_DIR=$1 SYSTEMD_DIR=$2 SERVICE_USER={NO_USER} PURGE=${{PURGE_OPT:-0}}; "
    'resolve; echo "DATA_DIR=$DATA_DIR"'
)


@needs_bash
@pytest.mark.parametrize("env_line", ["SCOUT_DATA_DIR=data", "SCOUT_DATA_DIR=./data/", "# SCOUT_DATA_DIR=data"])
def test_uninstall_refuses_to_delete_games_in_a_relative_data_folder(code_folder, tmp_path, env_line):
    # The app reads a relative (or unset) SCOUT_DATA_DIR from the code folder, so the games are in
    # <code>/data. uninstall.sh used to assume /var/lib/basketball-scout and delete them with the code.
    (code_folder / ".env").write_text(env_line + "\n")
    result = source_script(
        "uninstall.sh", UNINSTALL_RESOLVE, str(code_folder), str(tmp_path / "no-systemd"), env=script_env(tmp_path)
    )
    assert result.returncode != 0, result.stdout
    assert f"{code_folder}/data is inside {code_folder}" in result.stderr
    assert (code_folder / "data" / "scout.db").exists()


@needs_bash
def test_uninstall_purge_resolves_the_relative_data_folder(code_folder, tmp_path):
    result = source_script(
        "uninstall.sh",
        UNINSTALL_RESOLVE,
        str(code_folder),
        str(tmp_path / "no-systemd"),
        env={**script_env(tmp_path), "PURGE_OPT": "1"},
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip().endswith(f"DATA_DIR={code_folder}/data")


@needs_bash
def test_uninstall_keeps_the_default_data_folder_for_an_absolute_or_missing_setting(code_folder, tmp_path):
    env = script_env(tmp_path)
    (code_folder / "data" / "scout.db").unlink()  # no games in the code folder (see the test below)
    (code_folder / "data" / "games").rmdir()
    (code_folder / ".env").write_text("SCOUT_DATA_DIR=/srv/scout-data\n")
    absolute = source_script("uninstall.sh", UNINSTALL_RESOLVE, str(code_folder), str(tmp_path / "x"), env=env)
    assert absolute.returncode == 0, absolute.stderr
    assert absolute.stdout.strip().endswith("DATA_DIR=/srv/scout-data")

    (code_folder / ".env").write_text("SCOUT_DATA_DIR=data\n")  # relative, but no games there
    empty = source_script("uninstall.sh", UNINSTALL_RESOLVE, str(code_folder), str(tmp_path / "x"), env=env)
    assert empty.returncode == 0, empty.stderr
    assert empty.stdout.strip().endswith("DATA_DIR=/var/lib/basketball-scout")

    (code_folder / ".env").unlink()  # half-finished install: no .env, the installer's default folder
    missing = source_script("uninstall.sh", UNINSTALL_RESOLVE, str(code_folder), str(tmp_path / "x"), env=env)
    assert missing.returncode == 0, missing.stderr
    assert missing.stdout.strip().endswith("DATA_DIR=/var/lib/basketball-scout")


INSTALL_RESOLVE = 'SYSTEMD_DIR=$2 INSTALL_DIR=$1; resolve_settings; echo "DATA_DIR=$DATA_DIR"'


@needs_bash
def test_install_rerun_does_not_silently_leave_games_in_a_relative_data_folder(code_folder, tmp_path):
    # Before: SCOUT_DATA_DIR=data (games in <code>/data) became /var/lib/basketball-scout, the
    # services started on an empty database, and a later uninstall deleted the old games.
    result = source_script(
        "install.sh", INSTALL_RESOLVE, str(code_folder), str(tmp_path / "no-systemd"), env=script_env(tmp_path)
    )
    assert result.returncode != 0, result.stdout
    assert "outside the code folder" in result.stderr
    assert "Moving the data folder" in result.stderr


@needs_bash
def test_install_rerun_with_a_relative_but_empty_data_folder_uses_the_default(code_folder, tmp_path):
    (code_folder / "data" / "scout.db").unlink()
    result = source_script(
        "install.sh", INSTALL_RESOLVE, str(code_folder), str(tmp_path / "no-systemd"), env=script_env(tmp_path)
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "DATA_DIR=/var/lib/basketball-scout"


# --- update.sh --force keeps local config edits -------------------------------------------------------


@pytest.fixture
def server_checkout(tmp_path):
    """An "upstream" repo pushed to a bare "origin" (GitHub) and a server checkout cloned from it."""
    env = script_env(tmp_path)
    upstream, origin, install = tmp_path / "upstream", tmp_path / "origin.git", tmp_path / "opt" / "basketball-scout"
    git(tmp_path, "init", "-q", "--bare", "-b", "main", str(origin), env=env)
    git(tmp_path, "init", "-q", "-b", "main", str(upstream), env=env)
    (upstream / "config").mkdir()
    (upstream / "config" / "court.yaml").write_text("length_ft: 84.0\nwidth_ft: 50.0\n")
    (upstream / "README.md").write_text("version 1\n")
    git(upstream, "add", ".", env=env)
    git(upstream, "commit", "-q", "-m", "version 1", env=env)
    git(upstream, "remote", "add", "origin", str(origin), env=env)
    git(upstream, "push", "-q", "origin", "main", env=env)
    install.parent.mkdir(parents=True)
    git(tmp_path, "clone", "-q", str(origin), str(install), env=env)
    data = tmp_path / "server-data"  # tmp_path/data is the conftest data dir
    data.mkdir()
    (install / ".env").write_text(f"SCOUT_DATA_DIR={data}\n")  # untracked, like on a server

    def publish(path: str, text: str) -> str:
        (upstream / path).write_text(text)
        git(upstream, "commit", "-q", "-am", f"change {path}", env=env)
        git(upstream, "push", "-q", "origin", "main", env=env)
        return git(upstream, "rev-parse", "HEAD", env=env)

    return SimpleNamespace(env=env, install=install, data=data, publish=publish)


UPDATE_PULL = """
as_user() { (cd "$INSTALL_DIR" && GIT_TERMINAL_PROMPT=0 "$@"); }   # no runuser on the test machine
INSTALL_DIR=$1 ENV_FILE="$1/.env" SERVICE_USER=$(id -un) BRANCH=main FORCE=1
OLD_HEAD=$(git_user rev-parse HEAD) RUNNING_HEAD=$OLD_HEAD
check_local_changes
pull_code
"""


def run_update_pull(checkout: SimpleNamespace) -> subprocess.CompletedProcess[str]:
    return source_script("update.sh", UPDATE_PULL, str(checkout.install), env=checkout.env)


def court_file(checkout: SimpleNamespace) -> str:
    return (checkout.install / "config" / "court.yaml").read_text()


@needs_git
def test_update_force_puts_local_config_edits_back(server_checkout):
    # README tells coaches to set the gym length in config/court.yaml. update.sh --force used to
    # stash that edit and never put it back, so every update silently reverted the setting.
    new_head = server_checkout.publish("README.md", "version 2\n")
    (server_checkout.install / "config" / "court.yaml").write_text("length_ft: 74.0\nwidth_ft: 50.0\n")

    result = run_update_pull(server_checkout)
    assert result.returncode == 0, result.stderr
    assert git(server_checkout.install, "rev-parse", "HEAD", env=server_checkout.env) == new_head
    assert "length_ft: 74.0" in court_file(server_checkout)
    assert "Put your local changes back" in result.stdout
    patches = list((server_checkout.data / "backups").glob("local-changes-*.patch"))
    assert len(patches) == 1 and "length_ft: 74.0" in patches[0].read_text()


@needs_git
def test_update_force_with_a_clash_keeps_the_new_version_and_the_saved_changes(server_checkout):
    new_head = server_checkout.publish("config/court.yaml", "length_ft: 80.0\nwidth_ft: 50.0\n")
    (server_checkout.install / "config" / "court.yaml").write_text("length_ft: 74.0\nwidth_ft: 50.0\n")

    result = run_update_pull(server_checkout)
    assert result.returncode == 0, result.stderr
    assert git(server_checkout.install, "rev-parse", "HEAD", env=server_checkout.env) == new_head
    assert court_file(server_checkout) == "length_ft: 80.0\nwidth_ft: 50.0\n"  # clean: no conflict markers
    assert git(server_checkout.install, "status", "--porcelain", "--untracked-files=no", env=server_checkout.env) == ""
    assert "NOT in use now" in result.stderr
    stash = git(server_checkout.install, "stash", "show", "-p", "stash@{0}", env=server_checkout.env)
    assert "length_ft: 74.0" in stash


@needs_git
def test_update_force_that_cannot_fetch_leaves_local_changes_in_place(server_checkout):
    # The changes used to be stashed before the fetch: with GitHub unreachable the update stopped
    # and the running app was left without the coach's edits (config files are read at run time).
    git(server_checkout.install, "remote", "set-url", "origin", str(server_checkout.data / "gone.git"),
        env=server_checkout.env)  # fmt: skip
    (server_checkout.install / "config" / "court.yaml").write_text("length_ft: 74.0\nwidth_ft: 50.0\n")

    result = run_update_pull(server_checkout)
    assert result.returncode != 0
    assert "git fetch failed" in result.stderr
    assert "length_ft: 74.0" in court_file(server_checkout)
    assert git(server_checkout.install, "stash", "list", env=server_checkout.env) == ""


@needs_git
def test_update_rollback_help_says_how_to_get_the_local_changes_back(server_checkout):
    # "git reset --hard <old commit>" drops the re-applied edits from the working tree.
    server_checkout.publish("README.md", "version 2\n")
    (server_checkout.install / "config" / "court.yaml").write_text("length_ft: 74.0\nwidth_ft: 50.0\n")
    result = source_script(
        "update.sh", UPDATE_PULL + "print_rollback_help\n", str(server_checkout.install), env=server_checkout.env
    )
    assert result.returncode == 0, result.stderr
    reset = result.stdout.index("reset --hard")
    assert result.stdout.index(" stash apply ", reset) > reset


@needs_git
def test_update_without_force_still_refuses_and_explains_force(server_checkout):
    (server_checkout.install / "config" / "court.yaml").write_text("length_ft: 74.0\nwidth_ft: 50.0\n")
    result = source_script(
        "update.sh", UPDATE_PULL.replace("FORCE=1", "FORCE=0"), str(server_checkout.install), env=server_checkout.env
    )
    assert result.returncode != 0
    assert "config/court.yaml" in result.stderr
    assert "--force" in result.stderr and "puts them back" in result.stderr
    assert "length_ft: 74.0" in court_file(server_checkout)


# --- update.sh: the deploy/ notice comes before the restart --------------------------------------------

UPDATE_MAIN = """
TEST_DIR=$1 TEST_SYSTEMD=$2
require_root() { :; }
as_user() { (cd "$INSTALL_DIR" && "$@"); }
check_checkout() {
  INSTALL_DIR=$TEST_DIR ENV_FILE="$TEST_DIR/.env" SERVICE_USER=$(id -un) BRANCH=main
  OLD_HEAD=$(git_user rev-parse HEAD~1) RUNNING_HEAD=$OLD_HEAD
}
check_local_changes() { :; }
pull_code() { NEW_HEAD=$(git_user rev-parse HEAD); CODE_CHANGED=1; }
install_requirements() { :; }
run_migrations() { :; }
deploy_modal() { :; }
systemctl() { return 0; }
SYSTEMD_DIR=$TEST_SYSTEMD HEALTH_TIMEOUT_S=0
main
"""


@needs_git
def test_update_says_deploy_templates_changed_before_a_failing_restart(server_checkout, tmp_path):
    # A new version whose services need the new unit files fails its health check with the old
    # ones; the "re-run install.sh" hint used to be printed only after a successful restart.
    (server_checkout.install / "deploy").mkdir()
    (server_checkout.install / "deploy" / "unit.service").write_text("[Service]\nExecStart=/bin/true\n")
    git(server_checkout.install, "add", "deploy", env=server_checkout.env)
    git(server_checkout.install, "commit", "-q", "-m", "new unit template", env=server_checkout.env)
    systemd = tmp_path / "systemd"
    systemd.mkdir()
    (systemd / "basketball-scout-web.service").write_text("ExecStart=python -m uvicorn scout.main:app --port 1\n")

    result = source_script(
        "update.sh", UPDATE_MAIN, str(server_checkout.install), str(systemd), env=server_checkout.env
    )
    assert result.returncode != 0
    assert "did not answer" in result.stderr
    hint = result.stderr.index("templates in deploy/ changed")
    assert hint < result.stderr.index("did not answer")


# --- Modal deploys go where the worker looks -----------------------------------------------------------

DEPLOY_STUBS = """
as_user_with_env() { echo "MODAL-CLI: $*"; }
record_state() { :; }
INSTALL_DIR=$1 ENV_FILE="$1/.env" SERVICE_USER=scout SERVICE_HOME=$1
"""


@needs_bash
@pytest.mark.parametrize(
    ("name", "call"),
    [
        ("update.sh", "DEPLOY_MODE=yes NEW_HEAD=abc; deploy_modal"),
        ("install.sh", "MODAL_ID='' MODAL_SECRET=''; run_modal_deploy"),
    ],
)
@pytest.mark.parametrize("environment", ["staging", ""])
def test_modal_deploy_targets_the_environment_the_worker_uses(tmp_path, name, call, environment):
    # The worker looks the app up in SCOUT_MODAL_ENVIRONMENT; `modal deploy` only knew
    # MODAL_ENVIRONMENT, so setting just the first deployed somewhere the worker never looks.
    (tmp_path / ".env").write_text(
        f"MODAL_TOKEN_ID=ak-x\nMODAL_TOKEN_SECRET=as-y\nSCOUT_MODAL_ENVIRONMENT={environment}\n"
    )
    result = source_script(name, DEPLOY_STUBS + call, str(tmp_path), env=script_env(tmp_path))
    assert result.returncode == 0, result.stderr
    expected = f"/.venv/bin/modal deploy --env {environment} modal_app/app.py" if environment else (
        "/.venv/bin/modal deploy modal_app/app.py"
    )
    assert expected in result.stdout


@needs_bash
def test_uninstall_stops_the_modal_app_in_its_environment(tmp_path):
    folder = tmp_path / "opt" / "basketball-scout"
    (folder / ".venv" / "bin").mkdir(parents=True)
    (folder / "scout").mkdir()
    (folder / "scout" / "main.py").write_text("# app\n")
    (folder / ".venv" / "bin" / "modal").write_text("#!/bin/sh\n")
    (folder / ".venv" / "bin" / "modal").chmod(0o755)
    (folder / ".env").write_text("SCOUT_MODAL_ENVIRONMENT=staging\n")
    snippet = (
        f'runuser() {{ echo "RUN: $*"; }}; INSTALL_DIR=$1 SYSTEMD_DIR=$1/no-systemd SERVICE_USER={NO_USER} '
        'ASSUME_YES=1; resolve; SERVICE_HOME=$1; remove_modal'
    )
    result = source_script("uninstall.sh", snippet, str(folder), env=script_env(tmp_path))
    assert result.returncode == 0, result.stderr
    calls = [line for line in result.stdout.splitlines() if line.startswith("RUN: ")]
    assert len(calls) == 3 and all(line.endswith(" --env staging") for line in calls), calls


# --- systemd units wait for the data disk --------------------------------------------------------------


@needs_bash
@pytest.mark.parametrize("name", ["basketball-scout-web.service", "basketball-scout-worker.service"])
def test_units_require_the_data_folder_mount(tmp_path, name):
    # docs/PROXMOX.md suggests a second disk mounted at the data folder; without this the services
    # can start first and create an empty database on the system disk underneath the mount point.
    out = tmp_path / name
    result = source_script(
        "install.sh",
        'render_template "$1" "$2" USER=scout GROUP=scout DIR=/opt/basketball-scout HOST=127.0.0.1 '
        "PORT=8000 DATA_DIR=/var/lib/basketball-scout HOME=/home/scout",
        str(ROOT / "deploy" / "systemd" / name),
        str(out),
        env=script_env(tmp_path),
    )
    assert result.returncode == 0, result.stderr
    unit_section = out.read_text().split("[Service]")[0]
    assert "\nRequiresMountsFor=/var/lib/basketball-scout /home/scout\n" in unit_section


# --- docs match the code -------------------------------------------------------------------------------


def _module_interfaces() -> str:
    text = (DOCS / "ARCHITECTURE.md").read_text()
    section = text.split("## Module interfaces", 1)[1]
    return section.split("```python", 1)[1].split("```", 1)[0]


DOCUMENTED_FUNCTIONS = {
    "load_tracking(": "scout.analysis.pipeline:load_tracking",
    "analyze_game(": "scout.analysis.pipeline:analyze_game",
    "save_analysis(": "scout.analysis.pipeline:save_analysis",
    "load_analysis(": "scout.analysis.pipeline:load_analysis",
    "resolve_team_map(": "scout.analysis.teams:resolve_team_map",
    "side_of(": "scout.analysis.teams:side_of",
    "player_ref(": "scout.analysis.events:player_ref",
    "build_timeline(": "scout.analysis.events:build_timeline",
    "build_box_scores(": "scout.analysis.boxscore:build_box_scores",
    "load_play_rules(": "scout.analysis.plays:load_play_rules",
    "detect_plays(": "scout.analysis.plays:detect_plays",
    "link_plays(": "scout.analysis.plays:link_plays",
    "summarize_plays(": "scout.analysis.plays:summarize_plays",
    "generate_synthetic_game(": "scout.analysis.synthetic:generate_synthetic_game",
    "synthetic_rosters(": "scout.analysis.synthetic:synthetic_rosters",
    "parse_roster_file(": "scout.roster.importer:parse_roster_file",
    "merge_players(": "scout.roster.importer:merge_players",
    "normalize_jersey(": "scout.roster.matcher:normalize_jersey",
    "jersey_similarity(": "scout.roster.matcher:jersey_similarity",
    "jersey_votes(": "scout.roster.matcher:jersey_votes",
    "match_votes(": "scout.roster.matcher:match_votes",
    "assign_tracks(": "scout.roster.matcher:assign_tracks",
    "match_name(": "scout.roster.matcher:match_name",
    "load_fastscout_config(": "scout.export.fastscout:load_fastscout_config",
    "validate_fastscout_config(": "scout.export.fastscout:validate_fastscout_config",
    "build_paste_block(": "scout.export.fastscout:build_paste_block",
    "paste_block_warnings(": "scout.export.fastscout:paste_block_warnings",
    "team_helper_block(": "scout.export.fastscout:team_helper_block",
    "list_custom_tables(": "scout.export.fastscout:list_custom_tables",
    "custom_table_titles(": "scout.export.fastscout:custom_table_titles",
    "build_custom_table_csv(": "scout.export.fastscout:build_custom_table_csv",
    "build_timeline_csv(": "scout.export.fastscout:build_timeline_csv",
    "sanitize_fastscout_name(": "scout.export.fastscout:sanitize_fastscout_name",
    "jersey_words(": "scout.export.fastscout:jersey_words",
    "build_report_payload(": "scout.reporting.claude_report:build_report_payload",
    "generate_report(": "scout.reporting.claude_report:generate_report",
    "report_to_markdown(": "scout.reporting.render:report_to_markdown",
    "get_queue(": "scout.jobs.queue:get_queue",
    "submit_job(": "scout.jobs.queue:submit_job",
    "get_processor(": "scout.processing:get_processor",
    "poll_result_from_response(": "scout.processing.base:poll_result_from_response",
    "Worker(": "scout.worker:Worker",
    "runner.run_pipeline(": "modal_app.pipeline.runner:run_pipeline",
    "possession.assign_ball_holders(": "modal_app.pipeline.possession:assign_ball_holders",
    "events.enrich_events(": "modal_app.pipeline.events:enrich_events",
    "events.detect_events(": "modal_app.pipeline.events:detect_events",
    "result.build_tracking_result(": "modal_app.pipeline.result:build_tracking_result",
}


def _documented_params(block: str, prefix: str) -> list[str]:
    match = re.search(rf"(?:^|[\s/])({re.escape(prefix)})([^)]*)\)", block, re.MULTILINE)
    assert match, f"docs/ARCHITECTURE.md does not document {prefix}...)"
    names = []
    for part in match.group(2).split(","):
        name = re.split(r"[:=]", part.strip(), maxsplit=1)[0].strip()
        if name and name != "*":
            names.append(name)
    return names


@pytest.mark.parametrize("prefix", sorted(DOCUMENTED_FUNCTIONS))
def test_architecture_signatures_match_the_code(prefix):
    module, attr = DOCUMENTED_FUNCTIONS[prefix].split(":")
    target = getattr(importlib.import_module(module), attr)
    actual = [p.name for p in inspect.signature(target).parameters.values() if p.name != "self"]
    assert _documented_params(_module_interfaces(), prefix) == actual


def test_architecture_documents_the_review_requested_contracts():
    text = (DOCS / "ARCHITECTURE.md").read_text()
    for needle in (
        "`dev.sh`",
        "the scoring team's free\n    throw is the next ball event",
        "A missed last free throw does not flip the possession",
        "keeps that player's\n# id",
        "`AUTH_REQUIRED` (401",
        "`AUTH_THROTTLED` (429 with `Retry-After`",
        "`AUTH_NOT_CONFIGURED` (503",
        "Only one REPORT job per game",
        "clears the\n  track overrides",
        "`track_id` in the body is optional",
        "newest job first",
        "GET /api/games/{id}/export/fastscout-notes?side=scouted",
        '{"warnings": [str], "team_numbers": str}',
        "the attempt is not counted towards `WORKER_LOST`",
        "measured from `Job.started_at`",
        'pipeline.options["seed"]',
        "if enqueue fails, the new row is marked failed",
        ".heartbeat(worker_id)",
        "scout/processing/base.py",
    ):
        assert needle in text, f"docs/ARCHITECTURE.md lacks {needle!r}"


def test_architecture_documents_every_api_route():
    from scout.main import create_app

    def norm(text: str) -> str:
        return re.sub(r"\{[^}]*\}", "{}", text)

    # "`GET` / `HEAD /api/health/live`" documents both methods of one path.
    doc = re.sub(r"`([A-Z]+)` / `([A-Z]+) (/[^`\s]+)`", r"`\1 \3` / `\2 \3`", (DOCS / "ARCHITECTURE.md").read_text())
    doc = norm(doc)
    missing = [
        f"{method.upper()} {path}"
        for path, operations in create_app().openapi()["paths"].items()
        for method in operations
        if norm(f"{method.upper()} {path}") not in doc
    ]
    assert not missing, f"docs/ARCHITECTURE.md > HTTP API lacks {missing}"


def _pipeline_warning_codes() -> set[str]:
    codes = set()
    for path in (ROOT / "modal_app").rglob("*.py"):
        text = path.read_text()
        codes |= set(re.findall(r"""\bwarn\(\s*["']([A-Z][A-Z0-9_]+)["']""", text))
        codes |= set(re.findall(r"""_warning\(\s*["']([A-Z][A-Z0-9_]+)["']""", text))
        codes |= set(re.findall(r"""^[A-Z_]+ = ["']([A-Z][A-Z0-9_]+_RECOVERED)["']""", text, re.MULTILINE))
    return codes


def test_tracking_schema_lists_every_pipeline_warning_code():
    codes = _pipeline_warning_codes()
    assert {"COURT_MAPPING_SPARSE", "OCR_UNAVAILABLE", "COURT_ORIENTATION_CHECK", "GPU_OOM_RECOVERED"} <= codes
    text = (DOCS / "TRACKING_SCHEMA.md").read_text()
    missing = sorted(code for code in codes if f"`{code}`" not in text)
    assert not missing, f"docs/TRACKING_SCHEMA.md lacks the warning codes {missing}"


def test_tracking_schema_lists_every_pipeline_error_code_and_internal_attrs():
    from modal_app.pipeline import errors

    text = (DOCS / "TRACKING_SCHEMA.md").read_text()
    codes = [value for name, value in vars(errors).items() if name.isupper() and isinstance(value, str)]
    missing = [code for code in codes if f"`{code}`" not in text]
    assert not missing, f"docs/TRACKING_SCHEMA.md lacks the error codes {missing}"
    for needle in (
        "`CONFIG_INVALID`",
        "`attrs.replaces_event_id`",
        "removes the key",
        "`Game.has_video` is true when a film file is stored on this server",
        "`HealthStatus.max_upload_bytes`",
        "Raising `SCOUT_MODAL_TIMEOUT_S` above 8 hours also requires raising `SCOUT_MODAL_MAX_WAIT_HOURS`",
    ):
        # Wherever the paragraph wraps its lines.
        assert " ".join(needle.split()) in " ".join(text.split()), f"docs/TRACKING_SCHEMA.md lacks {needle!r}"


def test_modal_timeout_advice_mentions_the_worker_wait_limit():
    # The worker gives up after SCOUT_MODAL_MAX_WAIT_HOURS (8) and cancels the call, so raising
    # only SCOUT_MODAL_TIMEOUT_S above 8 hours still fails long films with MODAL_TIMEOUT.
    readme = (ROOT / "README.md").read_text()
    row = next(line for line in readme.splitlines() if line.startswith("| `MODAL_TIMEOUT` |"))
    assert "SCOUT_MODAL_MAX_WAIT_HOURS" in row.split("|")[3]
    example = (ROOT / ".env.example").read_text()
    comment = example.split("# SCOUT_MODAL_TIMEOUT_S=")[0].rsplit("# Time limit for one film", 1)[1]
    assert "SCOUT_MODAL_MAX_WAIT_HOURS" in comment


def test_docs_do_not_say_make_run_web_reads_scout_host():
    # The Makefile passes its own HOST/PORT (127.0.0.1:8000) to uvicorn.
    makefile = (ROOT / "Makefile").read_text()
    recipe = makefile.split("\nrun-web:", 1)[1].split("\n\n", 1)[0]
    assert "--host $(HOST) --port $(PORT)" in recipe and "SCOUT_" not in recipe
    assert "used by `scout-web` and `make run-web`" not in (ROOT / ".env.example").read_text()
    assert "Listen address for `scout-web` / `make run-web`" not in (ROOT / "README.md").read_text()


def test_readme_says_what_is_not_verified_yet_and_summarises_the_proxmox_vm():
    readme = (ROOT / "README.md").read_text()
    status = readme.split("## What is not verified yet", 1)[1].split("\n## ", 1)[0]
    for needle in ("real GPU", "real game film", "archived FastScout documentation", "Ubuntu 24.04"):
        assert needle in status, f"README.md > What is not verified yet lacks {needle!r}"
    proxmox = readme.split("### Proxmox VM", 1)[1].split("\n### ", 1)[0]
    for needle in ("`q35`", "OVMF", "`host`", "32 GB", "200 GB", "Ubuntu Server 24.04", "(docs/PROXMOX.md)"):
        assert needle in proxmox, f"README.md > Proxmox VM lacks {needle!r}"
    assert "[What is not verified yet](#what-is-not-verified-yet)" in readme
    assert "[Proxmox VM](#proxmox-vm)" in readme


def test_deployment_docs_cover_proxies_and_the_single_web_process():
    # Behind a school proxy every coach shares its address in the sign-in lockout unless the VM's
    # nginx trusts it, and a rewritten Host makes older browsers' changes look cross-site.
    proxmox = (DOCS / "PROXMOX.md").read_text()
    for needle in ("set_real_ip_from", "real_ip_header X-Forwarded-For", "X-Forwarded-Host"):
        assert needle in proxmox, f"docs/PROXMOX.md > Reverse proxy lacks {needle!r}"
    deployment = (DOCS / "DEPLOYMENT.md").read_text()
    assert "single uvicorn process (no `--workers`)" in deployment
    assert "SCOUT_MODAL_TIMEOUT_S` above 8 hours therefore also needs" in deployment


# --- Second ops review -----------------------------------------------------------------------------------


@needs_bash
@pytest.mark.parametrize("env_text", ["SCOUT_DATA_DIR=/srv/scout-data\n", None], ids=["absolute-setting", "no-env"])
def test_uninstall_refuses_to_delete_games_left_in_the_code_folder(code_folder, tmp_path, env_text):
    # <code>/data is the app's default data folder. With .env missing, or pointing elsewhere after an
    # earlier relative setting, uninstall.sh said "Data kept: ..." and deleted those games with the code.
    if env_text is None:
        (code_folder / ".env").unlink()
    else:
        (code_folder / ".env").write_text(env_text)
    env = script_env(tmp_path)
    result = source_script("uninstall.sh", UNINSTALL_RESOLVE, str(code_folder), str(tmp_path / "x"), env=env)
    assert result.returncode != 0, result.stdout
    assert f"{code_folder}/data holds games" in result.stderr
    assert (code_folder / "data" / "scout.db").exists()

    purge = source_script(
        "uninstall.sh", UNINSTALL_RESOLVE, str(code_folder), str(tmp_path / "x"), env={**env, "PURGE_OPT": "1"}
    )
    assert purge.returncode == 0, purge.stderr  # --purge deletes everything on purpose


UNINSTALL_REMOVE_USER = (
    'TEST_HOME=$3; user_home() { printf "%s" "$TEST_HOME"; }; '
    f"INSTALL_DIR=$1 SYSTEMD_DIR=$2 SERVICE_USER={NO_USER} REMOVE_USER=${{REMOVE_USER_OPT:-1}} "
    'PURGE=${PURGE_OPT:-0}; resolve; echo "DATA_DIR=$DATA_DIR"'
)


@needs_bash
def test_uninstall_remove_user_refuses_to_delete_a_data_folder_inside_the_users_home(tmp_path):
    # --remove-user runs `userdel --remove`, which deletes the home folder: a data folder kept there
    # (install.sh --data-dir /home/scout/...) went with it, although the plan said "Data kept".
    folder = tmp_path / "opt" / "basketball-scout"
    (folder / "scout").mkdir(parents=True)
    (folder / "scout" / "main.py").write_text("# app\n")
    home = tmp_path / "home" / "scout"
    data = home / "scout-data"
    (data / "games").mkdir(parents=True)
    (folder / ".env").write_text(f"SCOUT_DATA_DIR={data}\n")
    env = script_env(tmp_path)
    args = (str(folder), str(tmp_path / "no-systemd"), str(home))

    refused = source_script("uninstall.sh", UNINSTALL_REMOVE_USER, *args, env=env)
    assert refused.returncode != 0, refused.stdout
    assert f"{data} is inside {home}" in refused.stderr and "--remove-user" in refused.stderr

    keep_user = source_script("uninstall.sh", UNINSTALL_REMOVE_USER, *args, env={**env, "REMOVE_USER_OPT": "0"})
    assert keep_user.returncode == 0, keep_user.stderr
    assert keep_user.stdout.strip().endswith(f"DATA_DIR={data}")
    purge = source_script("uninstall.sh", UNINSTALL_REMOVE_USER, *args, env={**env, "PURGE_OPT": "1"})
    assert purge.returncode == 0, purge.stderr


@needs_bash
def test_readme_hash_password_command_works_from_any_folder(tmp_path):
    # install.sh installs requirements.txt, not the scout package, so the documented
    # `/opt/basketball-scout/.venv/bin/python -m scout.auth hash-password` failed with
    # "No module named 'scout'" unless the admin happened to be in the code folder.
    readme = (ROOT / "README.md").read_text()
    commands = [c for c in re.findall(r"`([^`]*-m scout\.auth hash-password)`", readme) if "/opt/basketball-scout" in c]
    assert commands, "README.md shows no server command for scout.auth hash-password"
    for command in commands:
        shell = (
            command.replace("/opt/basketball-scout/.venv/bin/python", '"$PYTHON"')
            .replace(".venv/bin/python", '"$PYTHON"')
            .replace("/opt/basketball-scout", '"$CODE"')
        )
        result = subprocess.run(
            [BASH, "-c", shell],
            cwd=tmp_path,  # an admin's home folder, say
            input="a long test password\n",
            capture_output=True,
            text=True,
            timeout=120,
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(tmp_path),
                 "PYTHON": sys.executable, "CODE": str(ROOT)},  # fmt: skip
        )
        assert result.returncode == 0, f"{command!r}: {result.stderr}"
        assert result.stdout.startswith("pbkdf2_sha256$")


def test_readme_restores_config_files_as_the_service_user():
    # The checkout belongs to `scout`: `sudo git checkout config/` stops with git's "detected dubious
    # ownership", and without -C it depends on the folder the admin is in.
    readme = (ROOT / "README.md").read_text()
    row = next(line for line in readme.splitlines() if line.startswith("| `CONFIG_INVALID` |"))
    assert "sudo -u scout git -C /opt/basketball-scout checkout -- config/" in row


UPDATE_STUBS = """
as_user() { (cd "$INSTALL_DIR" && GIT_TERMINAL_PROMPT=0 "$@"); }   # no runuser on the test machine
as_user_with_env() { echo "MODAL-CLI: $*"; }
INSTALL_DIR=$1 ENV_FILE="$1/.env" SERVICE_USER=$(id -un) SERVICE_HOME=$1 BRANCH=main
"""


def follow_rollback(checkout: SimpleNamespace, printed: str) -> None:
    """Do what update.sh printed: the git reset and the rm (pip, Modal and systemctl need a server)."""
    for line in printed.splitlines():
        words = line.split()
        if words[:1] == ["sudo"] and "reset" in words and "--hard" in words:
            git(checkout.install, "reset", "-q", "--hard", words[-1], env=checkout.env)
        elif words[:3] == ["sudo", "rm", "-f"]:
            for path in words[3:]:
                Path(path).unlink(missing_ok=True)


def pull(checkout: SimpleNamespace) -> str:
    git(checkout.install, "pull", "-q", "--ff-only", env=checkout.env)
    return git(checkout.install, "rev-parse", "HEAD", env=checkout.env)


@needs_git
def test_update_rollback_after_a_modal_deploy_lets_the_next_update_redeploy(server_checkout):
    # An update deployed modal_app/ and then failed (say at the health check). The printed rollback
    # redeploys the old GPU app, but .git/basketball-scout-modal still named the new commit, so a
    # later server-only update skipped the redeploy: the old pipeline kept running under new code.
    co = server_checkout
    old = git(co.install, "rev-parse", "HEAD", env=co.env)
    (co.install / ".env").write_text(f"SCOUT_DATA_DIR={co.data}\nMODAL_TOKEN_ID=ak-x\nMODAL_TOKEN_SECRET=as-y\n")
    upstream = co.install.parent.parent / "upstream"
    (upstream / "modal_app").mkdir()
    (upstream / "modal_app" / "app.py").write_text("# GPU app v2\n")
    git(upstream, "add", "modal_app", env=co.env)
    git(upstream, "commit", "-q", "-m", "GPU app v2", env=co.env)
    git(upstream, "push", "-q", "origin", "main", env=co.env)
    pull(co)

    failed = source_script(
        "update.sh",
        UPDATE_STUBS + 'OLD_HEAD=$2 RUNNING_HEAD=$2 NEW_HEAD=$(git_user rev-parse HEAD) CODE_CHANGED=1\n'
        "deploy_modal\nprint_rollback_help\n",
        str(co.install),
        old,
        env=co.env,
    )
    assert failed.returncode == 0, failed.stderr
    assert "MODAL-CLI: " in failed.stdout and "modal deploy" in failed.stdout
    follow_rollback(co, failed.stdout)
    assert git(co.install, "rev-parse", "HEAD", env=co.env) == old

    co.publish("README.md", "version 3\n")  # the fix is server-side only
    pull(co)
    later = source_script(
        "update.sh",
        UPDATE_STUBS + "OLD_HEAD=$2 NEW_HEAD=$(git_user rev-parse HEAD)\n"
        "RUNNING_HEAD=$(read_state running); RUNNING_HEAD=${RUNNING_HEAD:-$OLD_HEAD}; MODAL_HEAD=$(read_state modal)\n"
        'deploy_modal\necho "MODAL=$MODAL_SUMMARY"\n',
        str(co.install),
        old,
        env=co.env,
    )
    assert later.returncode == 0, later.stderr
    assert "MODAL=deployed" in later.stdout


@needs_git
def test_update_summary_says_how_to_go_back_and_the_next_update_restarts(server_checkout):
    # A successful update printed no way back. Going back by hand left .git/basketball-scout-running
    # on the new commit, so the next update.sh moved the files forward and kept the old processes
    # running ("Nothing new: the services keep running").
    co = server_checkout
    old = git(co.install, "rev-parse", "HEAD", env=co.env)
    co.publish("README.md", "version 2\n")
    new = pull(co)
    (co.install / ".git" / "basketball-scout-running").write_text(new + "\n")  # restarted on it
    summary = source_script(
        "update.sh", UPDATE_STUBS + "RUNNING_HEAD=$2 NEW_HEAD=$3\nprint_summary\n", str(co.install), old, new,
        env=co.env,
    )  # fmt: skip
    assert summary.returncode == 0, summary.stderr
    assert f"git -C {co.install} reset --hard {old}" in summary.stdout
    assert "systemctl restart basketball-scout-web basketball-scout-worker" in summary.stdout
    follow_rollback(co, summary.stdout)

    later = source_script(
        "update.sh",
        UPDATE_STUBS + "OLD_HEAD=$(git_user rev-parse HEAD)\n"
        "RUNNING_HEAD=$(read_state running); RUNNING_HEAD=${RUNNING_HEAD:-$OLD_HEAD}\n"
        'pull_code\necho "CODE_CHANGED=$CODE_CHANGED"\n',
        str(co.install),
        env=co.env,
    )
    assert later.returncode == 0, later.stderr
    assert git(co.install, "rev-parse", "HEAD", env=co.env) == new
    assert "CODE_CHANGED=1" in later.stdout


@needs_git
def test_update_restarts_when_the_checkout_was_moved_back_by_hand(server_checkout):
    # Same as above without the printed commands: an ad-hoc `git reset` (or checkout of an older tag)
    # while the record still names the newer commit. The files on disk change, so restart.
    co = server_checkout
    old = git(co.install, "rev-parse", "HEAD", env=co.env)
    co.publish("README.md", "version 2\n")
    new = pull(co)
    (co.install / ".git" / "basketball-scout-running").write_text(new + "\n")
    git(co.install, "reset", "-q", "--hard", old, env=co.env)
    result = source_script(
        "update.sh",
        UPDATE_STUBS + "OLD_HEAD=$(git_user rev-parse HEAD) RUNNING_HEAD=$(read_state running)\n"
        'pull_code\necho "CODE_CHANGED=$CODE_CHANGED"\n',
        str(co.install),
        env=co.env,
    )
    assert result.returncode == 0, result.stderr
    assert "CODE_CHANGED=1" in result.stdout


UNINSTALL_REMOVE_DATA = """
mountpoint() { [[ ${2%/} == "$DATA_DIR" ]]; }    # the data folder is a disk of its own
rm() {                                             # GNU rm's --one-file-system is not on every test machine
  local arg args=()
  for arg in "$@"; do [[ $arg == --one-file-system ]] || args+=("$arg"); done
  command rm "${args[@]}"
}
DATA_DIR=$1 QUEUE_BACKEND=sqlite
remove_data
echo "after remove_data"
"""


@needs_bash
def test_uninstall_purge_empties_a_data_folder_that_is_a_mount_point(tmp_path):
    # docs/PROXMOX.md suggests a second disk mounted at the data folder. `rm -rf` on the mount point
    # emptied it, then failed with "Device or resource busy", so --purge stopped there (no
    # --remove-user, no summary) and every re-run failed at the same step.
    data = tmp_path / "var" / "lib" / "basketball-scout"
    (data / "games" / "g_1").mkdir(parents=True)
    (data / "games" / "g_1" / "source.mp4").write_bytes(b"film")
    (data / "scout.db").write_bytes(b"SQLite format 3\x00")
    (data / "backups").mkdir()
    (data / ".scout-hidden").write_text("x")
    result = source_script("uninstall.sh", UNINSTALL_REMOVE_DATA, str(data), env=script_env(tmp_path))
    assert result.returncode == 0, result.stderr
    assert "after remove_data" in result.stdout
    assert data.is_dir(), "the mount point must stay"
    assert list(data.iterdir()) == []


def test_readme_outbound_access_lists_the_python_package_host():
    # pip downloads every package from files.pythonhosted.org (pypi.org only serves the index), so a
    # school firewall allowlisting the README's list broke install.sh's pip step.
    readme = (ROOT / "README.md").read_text()
    row = next(line for line in readme.splitlines() if line.startswith("| Internet access |"))
    for host in ("github.com", "pypi.org", "files.pythonhosted.org", "modal.com", "api.anthropic.com"):
        assert host in row, f"README.md > What you need lacks {host}"
