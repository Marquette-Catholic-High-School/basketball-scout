"""Regression tests from the second review round of the ops and outputs areas: the local-GPU
install (OpenCV's system libraries, OHV_HOME), update.sh checking out a newly pinned
OpenHoopVision and saying whether the services were restarted, uninstall.sh removing what a
local-GPU install added, the Makefile's test target, the Claude report's 403 wording and web
filter pages, and the FREE_THROWS_NOT_DETECTED warning in the FastScout notes and the payload.

Like tests/test_ops.py the script tests need no root, Linux, network or GPU: the scripts are
sourced (main() runs only where a test calls it) and apt-get, systemctl, runuser, pip and the
OpenHoopVision installer are shell functions that print what they were asked to do.
"""

from __future__ import annotations

import tomllib
from pathlib import Path
from types import SimpleNamespace

import anthropic
import httpx2
import pytest

from scout.errors import ErrorCode, ScoutError
from scout.export import fastscout
from scout.reporting import claude_report
from scout.schemas import PipelineWarning, TeamSide
from tests.test_export_fastscout import make_analysis, make_roster
from tests.test_reporting import FakeClient, _sdk_client, status_error
from tests.test_review_ops import NO_USER, git, needs_bash, needs_git, script_env, source_script

ROOT = Path(__file__).resolve().parent.parent
S = TeamSide.SCOUTED

# ---------------------------------------------------------------------------
# install.sh: the local GPU pipeline
# ---------------------------------------------------------------------------

INSTALL_GPU = """
command() {  # no NVIDIA driver, even on a test machine that has one
  if [[ ${1:-} == -v && ${2:-} == nvidia-smi ]]; then return 1; fi
  builtin command "$@"
}
apt-get() { echo "APT: $*"; }
apt-cache() {  # Debian 12 has no libglib2.0-0t64
  if [[ ${NO_T64:-0} == 1 && " $* " == *" libglib2.0-0t64 "* ]]; then echo "E: No packages found" >&2; return 100; fi
  echo "Package: found"
}
as_user() { echo "AS-USER: $*"; }
chown() { echo "CHOWN: $*"; }
INSTALL_DIR=$1 ENV_FILE="$1/.env" EFFECTIVE_PROCESSOR=local SERVICE_USER=scout SERVICE_GROUP=scout
install_gpu_packages
"""


@pytest.fixture
def local_gpu_code(tmp_path):
    """A code folder with modal_app/requirements-gpu.txt and a .env for SCOUT_PROCESSOR=local."""
    folder = tmp_path / "opt" / "basketball-scout"
    (folder / "modal_app").mkdir(parents=True)
    (folder / "modal_app" / "requirements-gpu.txt").write_text("opencv-python==5.0.0.93\n")
    ohv_home = tmp_path / "opt" / "openhoopvision"
    (folder / ".env").write_text(f"SCOUT_PROCESSOR=local\nOHV_HOME={ohv_home}\n")
    return SimpleNamespace(folder=folder, ohv_home=ohv_home)


def _calls(stdout: str, prefix: str) -> list[str]:
    return [line for line in stdout.splitlines() if line.startswith(prefix)]


@needs_bash
@pytest.mark.parametrize(
    ("no_t64", "glib"), [("0", "libglib2.0-0t64"), ("1", "libglib2.0-0")], ids=["ubuntu-24.04", "debian-12"]
)
def test_local_gpu_install_adds_the_libraries_opencv_needs_before_pip(local_gpu_code, tmp_path, no_t64, glib):
    # opencv-python (the GUI build OHV pins) loads libGL.so.1. APT_PACKAGES has no libgl1 and
    # installs with --no-install-recommends, so on a server without a desktop OHV stopped with
    # "ImportError: libGL.so.1". Ubuntu 24.04 calls glib libglib2.0-0t64, Debian 12 libglib2.0-0.
    env = {**script_env(tmp_path), "NO_T64": no_t64}
    result = source_script("install.sh", INSTALL_GPU, str(local_gpu_code.folder), env=env)
    assert result.returncode == 0, result.stderr
    lines = result.stdout.splitlines()
    apt = f"APT: install -y -q --no-install-recommends libgl1 {glib}"
    pip = next(i for i, line in enumerate(lines) if line.startswith("AS-USER: ") and " -m pip install " in line)
    assert apt in lines and lines.index("APT: update -q") < lines.index(apt) < pip
    ohv = _calls(result.stdout, "AS-USER: ")[-1]
    assert ohv.endswith(f"-m modal_app.pipeline.ohv install --home {local_gpu_code.ohv_home}")


@needs_bash
def test_local_gpu_install_refuses_an_ohv_home_that_holds_other_files(local_gpu_code, tmp_path):
    # OHV_HOME=/opt (the parent folder, say) was handed to the service user with chown, which could
    # then replace other software there; the OpenHoopVision clone into it failed only afterwards.
    shared = tmp_path / "opt"
    (shared / "other-app").mkdir(parents=True)
    (local_gpu_code.folder / ".env").write_text(f"SCOUT_PROCESSOR=local\nOHV_HOME={shared}\n")
    result = source_script("install.sh", INSTALL_GPU, str(local_gpu_code.folder), env=script_env(tmp_path))
    assert result.returncode != 0
    assert "already holds other files" in result.stderr
    assert not _calls(result.stdout, "CHOWN: ") and not _calls(result.stdout, "AS-USER: ")


@needs_bash
def test_local_gpu_install_rerun_keeps_using_its_openhoopvision_checkout(local_gpu_code, tmp_path):
    (local_gpu_code.ohv_home / ".git").mkdir(parents=True)
    (local_gpu_code.ohv_home / "main.py").write_text("# OpenHoopVision\n")
    result = source_script("install.sh", INSTALL_GPU, str(local_gpu_code.folder), env=script_env(tmp_path))
    assert result.returncode == 0, result.stderr
    assert _calls(result.stdout, "CHOWN: ") == [f"CHOWN: scout:scout {local_gpu_code.ohv_home}"]


# ---------------------------------------------------------------------------
# update.sh: a newly pinned OpenHoopVision commit
# ---------------------------------------------------------------------------


@pytest.fixture
def local_checkout(tmp_path):
    """A server checkout with SCOUT_PROCESSOR=local; ``commit`` adds a commit that changes one file."""
    env = script_env(tmp_path)
    install = tmp_path / "opt" / "basketball-scout"
    (install / "modal_app" / "pipeline").mkdir(parents=True)
    git(tmp_path, "init", "-q", "-b", "main", str(install), env=env)
    (install / "modal_app" / "pipeline" / "ohv.py").write_text('OHV_COMMIT = "ec969037b2c0"\n')
    (install / "README.md").write_text("version 1\n")
    git(install, "add", ".", env=env)
    git(install, "commit", "-q", "-m", "version 1", env=env)
    first = git(install, "rev-parse", "HEAD", env=env)
    ohv_home = tmp_path / "opt" / "openhoopvision"
    (install / ".env").write_text(f"SCOUT_PROCESSOR=local\nOHV_HOME={ohv_home}\n")  # untracked, like on a server

    def commit(path: str, text: str) -> str:
        (install / path).write_text(text)
        git(install, "commit", "-q", "-am", f"change {path}", env=env)
        return git(install, "rev-parse", "HEAD", env=env)

    return SimpleNamespace(env=env, install=install, first=first, commit=commit, ohv_home=ohv_home)


UPDATE_REQUIREMENTS = """
as_user() { if [[ $1 == git ]]; then (cd "$INSTALL_DIR" && "$@"); else echo "AS-USER: $*"; fi; }
INSTALL_DIR=$1 ENV_FILE="$1/.env" SERVICE_USER=$(id -un) RUNNING_HEAD=$2 NEW_HEAD=$3
install_requirements
echo "--- way back"
print_rollback_commands
"""


def _update_requirements(checkout: SimpleNamespace, new_head: str):
    return source_script(
        "update.sh", UPDATE_REQUIREMENTS, str(checkout.install), checkout.first, new_head, env=checkout.env
    )


@needs_git
def test_update_checks_out_a_newly_pinned_openhoopvision_commit(local_checkout):
    # ohv.py pins OHV_COMMIT and the weights. install.sh checks that commit out, update.sh never did:
    # a local-GPU server ran new code against the old OpenHoopVision.
    new_head = local_checkout.commit("modal_app/pipeline/ohv.py", 'OHV_COMMIT = "0123456789ab"\n')
    result = _update_requirements(local_checkout, new_head)
    assert result.returncode == 0, result.stderr
    install, way_back = result.stdout.split("--- way back")
    calls = _calls(install, "AS-USER: ")
    assert " -m pip install " in calls[0] and calls[0].endswith("/requirements.txt")
    python = f"{local_checkout.install}/.venv/bin/python"
    assert calls[-1] == f"AS-USER: {python} -m modal_app.pipeline.ohv install --home {local_checkout.ohv_home}"
    # Going back to the old code re-pins the old commit too.
    repin = f"-m modal_app.pipeline.ohv install --home {local_checkout.ohv_home}"
    assert way_back.index("reset --hard") < way_back.index(repin)


@needs_git
def test_update_way_back_reinstalls_the_old_gpu_packages(local_checkout):
    # A local-GPU update that installed new torch / OpenCV pins printed a way back that reinstalled
    # requirements.txt only, so the old code kept running on the new GPU stack.
    co = local_checkout
    (co.install / "modal_app" / "requirements-gpu.txt").write_text("torch==2.12.1+cu130\n")
    git(co.install, "add", "modal_app/requirements-gpu.txt", env=co.env)
    git(co.install, "commit", "-q", "-m", "GPU requirements", env=co.env)
    co.first = git(co.install, "rev-parse", "HEAD", env=co.env)  # what the services run
    new_head = co.commit("modal_app/requirements-gpu.txt", "torch==2.13.0+cu130\n")
    result = _update_requirements(co, new_head)
    assert result.returncode == 0, result.stderr
    install, way_back = result.stdout.split("--- way back")
    requirements = f"{co.install}/modal_app/requirements-gpu.txt"
    assert any(line.endswith(f"-m pip install --quiet --disable-pip-version-check -r {requirements}")
               for line in _calls(install, "AS-USER: "))  # fmt: skip
    assert f"pip install -r {requirements}" in way_back


@needs_git
@pytest.mark.parametrize(
    ("processor", "changed"),
    [("local", "README.md"), ("modal", "modal_app/pipeline/ohv.py")],
    ids=["pin-unchanged", "modal-processor"],
)
def test_update_leaves_openhoopvision_alone_otherwise(local_checkout, processor, changed):
    (local_checkout.install / ".env").write_text(f"SCOUT_PROCESSOR={processor}\nOHV_HOME={local_checkout.ohv_home}\n")
    new_head = local_checkout.commit(changed, "changed\n")
    result = _update_requirements(local_checkout, new_head)
    assert result.returncode == 0, result.stderr
    assert "modal_app.pipeline.ohv" not in result.stdout


# ---------------------------------------------------------------------------
# update.sh: what a failure says about the running services
# ---------------------------------------------------------------------------

UPDATE_FAILS = """
systemctl() { echo "SYSTEMCTL: $*"; }
curl() { return 7; }   # the web app never answers
INSTALL_DIR=$1 ENV_FILE="$1/.env" SERVICE_USER=scout SYSTEMD_DIR=$2 HEALTH_TIMEOUT_S=0
CODE_CHANGED=1 RUNNING_HEAD=0123456789abcdef0123 NEW_HEAD=fedcba9876543210fedc
"""


@needs_bash
@pytest.mark.parametrize(
    ("failing_step", "restarted"),
    [("restart_services", True), ('die "modal deploy failed"', False)],
    ids=["health-check-after-restart", "before-restart"],
)
def test_update_failure_says_whether_the_services_were_restarted(tmp_path, failing_step, restarted):
    # A failed health check comes after `systemctl restart`, but the message said the services
    # "keep running the old version until they are restarted".
    systemd = tmp_path / "systemd"
    systemd.mkdir()
    (systemd / "basketball-scout-web.service").write_text("ExecStart=python -m uvicorn scout.main:app --port 1\n")
    result = source_script(
        "update.sh", UPDATE_FAILS + failing_step, str(tmp_path), str(systemd), env=script_env(tmp_path)
    )
    assert result.returncode != 0
    assert ("restarted on the new version" in result.stderr) is restarted
    assert ("keep running the old version" in result.stderr) is not restarted
    assert "reset --hard 0123456789abcdef0123" in result.stderr


# ---------------------------------------------------------------------------
# uninstall.sh: what a local-GPU install added
# ---------------------------------------------------------------------------

UNINSTALL_MAIN = f"""
require_root() {{ :; }}
systemctl() {{ :; }}
remove_nginx_site() {{ :; }}
rm() {{  # only ever inside the test folder; GNU rm's --one-file-system is not on every test machine
  local arg args=()
  for arg in "$@"; do
    case $arg in
      --one-file-system) ;;
      -*) args+=("$arg") ;;
      "$TEST_ROOT"/*) args+=("$arg") ;;
      *) echo "REFUSED: rm $arg" >&2; return 1 ;;
    esac
  done
  command rm "${{args[@]}}"
}}
SYSTEMD_DIR=$1/no-systemd NVIDIA_MODULES_FILE=$2
main --dir "$1" --user {NO_USER} -y
"""


@pytest.fixture
def local_gpu_server(tmp_path):
    """What install.sh --processor local leaves: code, OpenHoopVision checkout, NVIDIA module list."""
    code = tmp_path / "opt" / "basketball-scout"
    (code / "scout").mkdir(parents=True)
    (code / "scout" / "main.py").write_text("# app\n")
    ohv = tmp_path / "opt" / "openhoopvision"
    (ohv / ".git").mkdir(parents=True)
    (ohv / "main.py").write_text("# OpenHoopVision\n")
    (ohv / "weights").mkdir()
    (ohv / "weights" / "rf-detr-basketball.pth").write_bytes(b"weights")
    modules = tmp_path / "etc" / "modules-load.d" / "basketball-scout-nvidia.conf"
    modules.parent.mkdir(parents=True)
    modules.write_text("nvidia\nnvidia_uvm\n")
    data = tmp_path / "srv" / "scout-data"
    (data / "games").mkdir(parents=True)

    def settings(**values: str) -> None:
        lines = {"SCOUT_DATA_DIR": str(data), "SCOUT_PROCESSOR": "local", "OHV_HOME": str(ohv), **values}
        (code / ".env").write_text("".join(f"{key}={value}\n" for key, value in lines.items()))

    settings()
    return SimpleNamespace(code=code, ohv=ohv, modules=modules, data=data, settings=settings, root=tmp_path)


def _uninstall(server: SimpleNamespace):
    env = {**script_env(server.root), "TEST_ROOT": str(server.root)}
    result = source_script("uninstall.sh", UNINSTALL_MAIN, str(server.code), str(server.modules), env=env)
    summary = result.stdout.split("Basketball Scout was removed", 1)[-1]
    return result, summary


@needs_bash
def test_uninstall_removes_what_a_local_gpu_install_added(local_gpu_server):
    # The OpenHoopVision checkout (several GB of weights) and the boot-time NVIDIA module list are
    # derived from the install, not user data, but both stayed behind.
    server = local_gpu_server
    result, summary = _uninstall(server)
    assert result.returncode == 0, result.stderr
    assert not server.code.exists() and not server.ohv.exists() and not server.modules.exists()
    assert (server.data / "games").is_dir() and list((server.data / "backups").glob("env-*"))
    assert f"Local GPU: deleted the OpenHoopVision checkout {server.ohv} and {server.modules}" in summary
    assert f"Local GPU    {server.ohv}" in result.stdout  # in the plan, before anything is removed


@needs_bash
@pytest.mark.parametrize("case", ["system-folder", "not-a-checkout", "holds-the-data"])
def test_uninstall_keeps_an_ohv_home_that_is_not_safe_to_delete(local_gpu_server, case):
    server = local_gpu_server
    if case == "system-folder":
        kept, reason = Path("/usr"), "a system folder"
    elif case == "not-a-checkout":
        kept, reason = server.root / "opt" / "shared", "it does not look like an OpenHoopVision checkout"
        (kept / "other-app").mkdir(parents=True)
    else:
        kept, reason = server.ohv, "the data or code folder is inside it"
        (server.ohv / "scout-data" / "games").mkdir(parents=True)
        server.settings(SCOUT_DATA_DIR=str(server.ohv / "scout-data"))
    if case != "holds-the-data":
        server.settings(OHV_HOME=str(kept))
    result, summary = _uninstall(server)
    assert result.returncode == 0, result.stderr
    assert "REFUSED" not in result.stderr
    assert kept.is_dir() and not server.code.exists()
    assert f"Kept {kept} (OHV_HOME): {reason}." in result.stderr
    assert f"Local GPU: OHV_HOME ({kept}) was not deleted: {reason}." in summary


@needs_bash
def test_uninstall_of_a_modal_install_keeps_openhoopvision_but_drops_the_module_list(local_gpu_server):
    # SCOUT_PROCESSOR is no longer local: the checkout may not be ours. The module list is (by name).
    server = local_gpu_server
    server.settings(SCOUT_PROCESSOR="modal")
    result, summary = _uninstall(server)
    assert result.returncode == 0, result.stderr
    assert server.ohv.is_dir() and not server.modules.exists()
    assert f"Local GPU: deleted {server.modules}" in summary


# ---------------------------------------------------------------------------
# Makefile
# ---------------------------------------------------------------------------


def test_make_test_shows_the_pass_fail_count():
    # pyproject.toml's addopts already pass -q; `pytest -q` on top made it -qq, which drops the
    # "N passed" line, so `make test` printed only dots.
    addopts = tomllib.loads((ROOT / "pyproject.toml").read_text())["tool"]["pytest"]["ini_options"]["addopts"]
    recipe = (ROOT / "Makefile").read_text().split("\ntest:", 1)[1].split("\n\n", 1)[0]
    command = next(line for line in recipe.splitlines() if " -m pytest" in line)
    assert addopts.split().count("-q") + command.split().count("-q") == 1


# ---------------------------------------------------------------------------
# Claude report: 403 and answers that are not from the API
# ---------------------------------------------------------------------------


@pytest.fixture
def analysis():
    return make_analysis()


@pytest.fixture
def rosters(game):
    return {S: make_roster(game.id)}


def _report_error(analysis, game, rosters, settings, client) -> ScoutError:
    with pytest.raises(ScoutError) as err:
        claude_report.generate_report(analysis, game, rosters, settings=settings, client=client)
    return err.value


def test_permission_denied_is_not_reported_as_a_rejected_key(analysis, game, rosters, settings):
    # 403: the API knows the key but it may not do this (no access to the model, or an unsupported
    # region). "The Anthropic API key was rejected" sent IT staff off to replace a working key.
    denied = status_error(
        anthropic.PermissionDeniedError, 403, "permission_error",
        "Your API key does not have permission to use the specified resource.",
    )  # fmt: skip
    error = _report_error(analysis, game, rosters, settings, FakeClient(denied))
    assert error.code == ErrorCode.REPORT_AUTH_FAILED and not error.retryable
    assert error.message.startswith("Anthropic refused this request:") and "rejected" not in error.message
    assert "organisation" in error.message and "region" in error.message
    assert settings.claude_model in (error.hint or "") and "SCOUT_CLAUDE_MODEL" in (error.hint or "")
    assert "does not have permission" in (error.detail or "") and "req_123" in (error.detail or "")
    assert error.__cause__ is denied


def test_rejected_key_keeps_its_message(analysis, game, rosters, settings):
    rejected = status_error(anthropic.AuthenticationError, 401, "authentication_error", "invalid x-api-key")
    error = _report_error(analysis, game, rosters, settings, FakeClient(rejected))
    assert error.code == ErrorCode.REPORT_AUTH_FAILED
    assert error.message == "The Anthropic API key was rejected."


BLOCK_PAGE = (
    b"<!DOCTYPE html><html><head><title>Access denied</title></head><body><h1>This site is blocked by "
    b"your school's web filter</h1><p>Category: Artificial Intelligence</p></body></html>"
)


@pytest.mark.parametrize("status", [403, 407])
def test_web_filter_pages_are_not_shown_raw(analysis, game, rosters, settings, status):
    # A web filter answers with its own HTML page. The SDK keeps the raw page as the error text, and
    # the report error showed it to the coach (407 Proxy Authentication Required) or called it a
    # rejected API key (403).
    page = httpx2.Response(status, headers={"content-type": "text/html; charset=utf-8"}, content=BLOCK_PAGE)
    client, _ = _sdk_client(page)
    error = _report_error(analysis, game, rosters, settings, client)
    assert error.code == ErrorCode.REPORT_FAILED and error.retryable
    for text in (error.message, error.hint or "", error.detail or ""):
        assert "<" not in text and "blocked by" not in text, text
    assert f"(HTTP {status})" in error.message and "web filter or proxy" in error.message
    assert "api.anthropic.com" in (error.hint or "") and "text/html" in (error.detail or "")


def test_gateway_error_page_is_still_a_busy_api_without_the_page(analysis, game, rosters, settings):
    page = httpx2.Response(502, headers={"content-type": "text/html"}, content=b"<html><h1>502 Bad Gateway</h1></html>")
    client, _ = _sdk_client(page)
    error = _report_error(analysis, game, rosters, settings, client)
    assert error.code == ErrorCode.REPORT_OVERLOADED
    assert "<html" not in (error.detail or "") and "text/html" in (error.detail or "")


# ---------------------------------------------------------------------------
# FREE_THROWS_NOT_DETECTED in the outputs
# ---------------------------------------------------------------------------


FREE_THROWS_MESSAGE = (
    "The court could not be mapped, so free throws were not detected: each free throw counts as a 2-point "
    "attempt, so FGA and points run high."
)


def _no_free_throws(analysis):
    analysis.data_quality.warnings.append(PipelineWarning(code="FREE_THROWS_NOT_DETECTED", message=FREE_THROWS_MESSAGE))
    return analysis


def test_fastscout_notes_say_free_throws_are_missing(analysis, game):
    # Without court positions the pipeline cannot tell a free throw from a field goal: the paste
    # block's FTM-A is empty while FGM-A and PTS include every free throw.
    warnings = fastscout.paste_block_warnings(_no_free_throws(analysis), game, roster=make_roster(game.id))
    note = next(w for w in warnings if w.startswith("Free throws could not be detected"))
    assert "(the court was not mapped)" in note and "FTM-A" in note and "FGM-A and PTS run high" in note
    assert "Calibrate the court and choose Full re-analysis before pasting" in note


def test_fastscout_notes_flag_free_throws_after_the_extra_event_pass_failed(analysis, game):
    # EXTRA_EVENTS_FAILED: the pass that turns OHV's free-throw "shots" into free throws crashed, so
    # they stay field-goal attempts just the same.
    message = "Free throws, fouls and screens could not be detected for this film."
    analysis.data_quality.warnings.append(PipelineWarning(code="EXTRA_EVENTS_FAILED", message=message))
    warnings = fastscout.paste_block_warnings(analysis, game, roster=make_roster(game.id))
    note = next(w for w in warnings if w.startswith("Free throws could not be detected"))
    assert "(the free-throw detection failed)" in note and "FGM-A and PTS run high" in note
    assert "Calibrate" not in note


def test_team_numbers_say_the_score_counts_free_throws_as_baskets(analysis):
    lines = fastscout.team_helper_block(_no_free_throws(analysis), S).splitlines()
    assert lines[-2].startswith("Free throws not detected (the court was not mapped)") and "2-point" in lines[-2]
    assert lines[-1] == "From video analysis - verify against the film."


def test_no_free_throw_note_when_they_were_detected(analysis, game):
    warnings = fastscout.paste_block_warnings(analysis, game, roster=make_roster(game.id))
    assert not any("Free throws" in w for w in warnings)
    assert "Free throws" not in fastscout.team_helper_block(analysis, S)


def test_claude_payload_carries_the_free_throw_warning_even_when_trimmed(analysis, game, rosters):
    # The report must not present FT numbers as real: the pipeline's warning reaches Claude in
    # data_quality.warnings, which payload trimming never drops.
    payload = claude_report.build_report_payload(_no_free_throws(analysis), game, rosters, token_budget=50)
    assert "omitted_sections" in payload
    assert f"FREE_THROWS_NOT_DETECTED: {FREE_THROWS_MESSAGE}" in payload["data_quality"]["warnings"]
