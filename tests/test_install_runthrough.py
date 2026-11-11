"""What following the install guide on a fresh Ubuntu 24.04 VM showed (November 2026).

The guide was run step by step on a clean Ubuntu Server 24.04 VM: install, a film through
nginx, update, a second install, uninstall, reinstall over the kept data. These tests keep
what went wrong there from coming back:

* install.sh warned "The app does not answer through nginx on port 80" on a first install:
  it asked nginx a millisecond after `systemctl reload nginx`, while the old workers still
  served the stock site (nginx's access log showed the 404).
* After uninstall.sh (which keeps .env in <data>/backups/), a reinstall planned and asked
  as if there were no settings: it asked again for the keys it had, named the wrong
  processor and left Redis out, so after `apt-get purge redis-server` (which uninstall.sh
  suggested) no job could run while the installer said "installed and running".
* The Modal dashboard shows a new token as a `modal token set --token-id ... --token-secret
  ...` line. Pasted at the Token ID question, the whole line became the token ID and the
  installer stopped only after the secret question, so everything had to start again.
* "installed and running" only meant that the web process answered; jobs could still be
  unable to run. install.sh and update.sh now also ask /api/health.
* The summary asked to allow port 80 in ufw although the rule was there, and uninstall.sh
  told everyone to remove a Modal app, revoke keys and purge redis-server they never had.
"""

from __future__ import annotations

import base64
import json
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from tests.test_ops import BASH, ENV_EXAMPLE, INSTALL_SH, SCRIPTS_DIR, needs_bash, script_env


def run_sourced(script: str, snippet: str, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    """Run ``snippet`` in bash after sourcing scripts/<script> (its main() does not run)."""
    return subprocess.run(
        [BASH, "-c", f'source "$SCRIPT"; {snippet}', "test-runthrough", *args],
        capture_output=True,
        text=True,
        timeout=60,
        env={**script_env(), "SCRIPT": str(SCRIPTS_DIR / script), **(env or {})},
        stdin=subprocess.DEVNULL,
    )


@pytest.fixture
def install_dir(tmp_path):
    folder = tmp_path / "opt" / "basketball-scout"
    folder.mkdir(parents=True)
    return folder


def saved_settings(data_dir: Path, text: str) -> Path:
    """The .env copy uninstall.sh leaves in the data folder."""
    (data_dir / "backups").mkdir(parents=True, exist_ok=True)
    backup = data_dir / "backups" / "env-20261110-200650"
    backup.write_text(text)
    return backup


# --- reinstall after uninstall: plan and ask with the settings that will be restored -------------

PLAN = 'SYSTEMD_DIR=$2 INSTALL_DIR=$1 DATA_DIR=$3; resolve_settings; echo "$PORT|$WITH_REDIS|$EFFECTIVE_PROCESSOR"; modal_credentials_present && echo "modal token: yes"; show_plan'


@needs_bash
def test_a_reinstall_after_uninstall_plans_with_the_saved_settings(install_dir, tmp_path):
    data_dir = tmp_path / "data"
    backup = saved_settings(
        data_dir,
        "SCOUT_PORT=8200\nSCOUT_QUEUE_BACKEND=redis\nSCOUT_PROCESSOR=mock\n"
        "MODAL_TOKEN_ID=ak-saved\nMODAL_TOKEN_SECRET=as-saved\nANTHROPIC_API_KEY=sk-ant-saved\n",
    )
    result = run_sourced("install.sh", PLAN, str(install_dir), str(tmp_path / "systemd"), str(data_dir))
    assert result.returncode == 0, result.stderr
    lines = result.stdout.splitlines()
    assert lines[0] == "8200|1|mock", "Redis, the port and the processor come from the saved settings"
    assert "modal token: yes" in lines
    assert f"restoring the ones uninstall.sh saved ({backup})" in result.stdout
    assert "Job queue          redis" in result.stdout


@needs_bash
def test_settings_in_env_still_win_over_an_older_backup(install_dir, tmp_path):
    data_dir = tmp_path / "data"
    saved_settings(data_dir, "SCOUT_PORT=8200\nSCOUT_QUEUE_BACKEND=redis\nSCOUT_PROCESSOR=mock\n")
    (install_dir / ".env").write_text(f"SCOUT_DATA_DIR={data_dir}\nSCOUT_PORT=8300\nSCOUT_PROCESSOR=modal\n")
    result = run_sourced("install.sh", PLAN, str(install_dir), str(tmp_path / "systemd"), str(data_dir))
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines()[0] == "8300|0|modal"
    assert "keeping" in result.stdout and "restoring" not in result.stdout


ASK = """
can_ask() { return 0; }
tty_available() { return 1; }  # confirm() takes its default instead of waiting on a real terminal
ask() { printf '%s\\n' "$1" >>"$ASKED"; }  # every question, answered with Enter
SYSTEMD_DIR=$2 INSTALL_DIR=$1 DATA_DIR=$3
resolve_settings
ask_for_missing_keys
echo "[done]"
"""


def ask_for_missing_keys(install_dir: Path, tmp_path: Path, data_dir: Path) -> tuple[subprocess.CompletedProcess[str], str]:
    asked = tmp_path / "asked.txt"
    asked.write_text("")
    result = run_sourced("install.sh", ASK, str(install_dir), str(tmp_path / "systemd"), str(data_dir), env={"ASKED": str(asked)})
    return result, asked.read_text()


@needs_bash
def test_a_reinstall_does_not_ask_again_for_the_keys_it_restores(install_dir, tmp_path):
    data_dir = tmp_path / "data"
    saved_settings(data_dir, "MODAL_TOKEN_ID=ak-saved\nMODAL_TOKEN_SECRET=as-saved\nANTHROPIC_API_KEY=sk-ant-saved\n")
    result, asked = ask_for_missing_keys(install_dir, tmp_path, data_dir)
    assert result.returncode == 0, result.stderr
    assert asked == "", f"asked again: {asked!r}"
    assert "[done]" in result.stdout


@needs_bash
def test_a_first_install_still_asks_for_both_keys(install_dir, tmp_path):
    result, asked = ask_for_missing_keys(install_dir, tmp_path, tmp_path / "data")
    assert result.returncode == 0, result.stderr
    assert asked.splitlines() == [
        "Paste the key (input hidden), or press Enter to skip: ",
        "Token ID (ak-..., input hidden: the pasted line holds the secret), or press Enter to skip: ",
    ]
    assert "paste the whole 'modal token set ...' line" in result.stdout


# --- pasted keys --------------------------------------------------------------------------------


@needs_bash
@pytest.mark.parametrize(
    ("pasted", "key"),
    [
        ("sk-ant-test-abc_DEF-123", "sk-ant-test-abc_DEF-123"),
        ('"sk-ant-abc"', "sk-ant-abc"),
        ("'sk-ant-abc'", "sk-ant-abc"),
        ("ANTHROPIC_API_KEY=sk-ant-abc", "sk-ant-abc"),
        ('export MODAL_TOKEN_ID="ak-abc"', "ak-abc"),
        ("MODAL_TOKEN_SECRET='as-abc'", "as-abc"),
        ("sk-ant-abc\r", "sk-ant-abc"),
        ('"', '"'),
        # curly quotes, from a document or a chat message
        ("‘sk-ant-abc’", "sk-ant-abc"),
        ("“ak-abc”", "ak-abc"),
    ],
)
def test_a_pasted_key_loses_its_quotes_and_name(pasted, key):
    result = run_sourced("install.sh", 'clean_key_input "$1"', pasted)
    assert result.returncode == 0, result.stderr
    assert result.stdout == key


@needs_bash
@pytest.mark.parametrize(
    ("pasted", "pair"),
    [
        ("modal token set --token-id ak-1a2b --token-secret as-3c4d", "ak-1a2b as-3c4d"),
        ("modal token set --token-id ak-1a2b --token-secret as-3c4d --profile=school --activate", "ak-1a2b as-3c4d"),
        ("modal token set --token-id=ak-1a2b --token-secret=as-3c4d", "ak-1a2b as-3c4d"),
        ("modal token set --token-id 'ak-1a2b' --token-secret \"as-3c4d\"", "ak-1a2b as-3c4d"),
        ("modal token set --token-id ‘ak-1a2b’ --token-secret ‘as-3c4d’", "ak-1a2b as-3c4d"),
        ("modal token set --token-id ak-1a2b --token-secret as-3c4d;", "ak-1a2b as-3c4d"),
        ("modal token set --token-id ak-1a2b", ""),
        ("ak-1a2b", ""),
    ],
)
def test_the_modal_command_line_gives_the_token_id_and_secret(pasted, pair):
    result = run_sourced("install.sh", 'modal_token_from_command "$1"', pasted)
    assert result.returncode == 0, result.stderr
    assert result.stdout == pair


READ_KEY = """
ask() {  # the next line of the answers file, as typed at the prompt
  local n
  n=$(cat "$ANSWERS.n")
  echo $((n + 1)) >"$ANSWERS.n"
  sed -n "$((n + 1))p" "$ANSWERS"
}
read_key "$1" "$2" "prompt: " secret  # both Modal questions hide the input: the pasted line holds the secret
echo "VALUE=[$KEY_VALUE] SECRET=[$KEY_SECRET] ASKED=$(cat "$ANSWERS.n")"
"""


def read_key(tmp_path: Path, label: str, prefix: str, *answers: str) -> subprocess.CompletedProcess[str]:
    file = tmp_path / "answers"
    file.write_text("".join(f"{answer}\n" for answer in answers))
    (tmp_path / "answers.n").write_text("0\n")
    return run_sourced("install.sh", READ_KEY, label, prefix, env={"ANSWERS": str(file)})


@needs_bash
def test_the_modal_command_line_pasted_at_the_token_id_question_gives_both(tmp_path):
    result = read_key(tmp_path, "Modal token ID", "ak-", "modal token set --token-id ak-1a2b --token-secret as-3c4d")
    assert result.returncode == 0, result.stderr
    assert "VALUE=[ak-1a2b] SECRET=[as-3c4d] ASKED=1" in result.stdout
    assert "Took the token ID and the secret from the pasted command" in result.stdout


@needs_bash
def test_the_modal_command_line_pasted_at_the_secret_question_gives_the_secret(tmp_path):
    result = read_key(tmp_path, "Modal token secret", "as-", "modal token set --token-id ak-1a2b --token-secret as-3c4d")
    assert "VALUE=[as-3c4d] SECRET=[] ASKED=1" in result.stdout


@needs_bash
def test_a_pasted_modal_line_with_a_broken_value_is_asked_again(tmp_path):
    """The values from the pasted line are checked like typed ones: an unbalanced quote used
    to pass here and stop the install later in validate_keys ("unexpected characters")."""
    result = read_key(tmp_path, "Modal token ID", "ak-", 'modal token set --token-id ak-1a2b --token-secret "as-3c4d', "")
    assert "VALUE=[] SECRET=[] ASKED=2" in result.stdout
    assert "has no usable token ID (ak-...) and secret (as-...)" in result.stderr
    assert "Took the token ID" not in result.stdout


def test_the_token_id_question_hides_what_is_pasted():
    """The pasted `modal token set ...` line holds the secret, so the Token ID question hides
    its input as the secret question does (on the VM the whole line was echoed)."""
    line = next(text for text in INSTALL_SH.read_text(encoding="utf-8").splitlines() if 'read_key "Modal token ID"' in text)
    assert line.rstrip().endswith(" secret"), line


@needs_bash
def test_a_key_that_starts_wrongly_is_asked_again(tmp_path):
    result = read_key(tmp_path, "Modal token ID", "ak-", "as-3c4d", "ak-1a2b")
    assert "VALUE=[ak-1a2b] SECRET=[] ASKED=2" in result.stdout
    assert "A Modal token ID starts with ak-" in result.stderr


@needs_bash
def test_the_same_unusual_key_twice_is_kept(tmp_path):
    result = read_key(tmp_path, "Modal token ID", "ak-", "tok-1a2b", "tok-1a2b")
    assert "VALUE=[tok-1a2b] SECRET=[] ASKED=2" in result.stdout


@needs_bash
def test_a_key_in_quotes_or_with_its_name_is_cleaned(tmp_path):
    result = read_key(tmp_path, "Anthropic API key", "sk-ant-", 'ANTHROPIC_API_KEY="sk-ant-abc"')
    assert "VALUE=[sk-ant-abc] SECRET=[] ASKED=1" in result.stdout
    assert result.stderr == ""


@needs_bash
def test_text_with_spaces_is_asked_again_and_enter_skips(tmp_path):
    result = read_key(tmp_path, "Anthropic API key", "sk-ant-", "my key is sk-ant-abc", "")
    assert "VALUE=[] SECRET=[] ASKED=2" in result.stdout
    assert "it has spaces or quotes in it" in result.stderr


@needs_bash
def test_three_wrong_answers_skip_the_key_instead_of_stopping_the_install(tmp_path):
    result = read_key(tmp_path, "Anthropic API key", "sk-ant-", "one two", "three four", "five six")
    assert result.returncode == 0
    assert "VALUE=[] SECRET=[] ASKED=3" in result.stdout
    assert "Skipped the Anthropic API key" in result.stderr


@needs_bash
def test_enter_skips_quietly(tmp_path):
    result = read_key(tmp_path, "Anthropic API key", "sk-ant-", "")
    assert "VALUE=[] SECRET=[] ASKED=1" in result.stdout
    assert result.stderr == ""


# --- nginx right after a reload ----------------------------------------------------------------


@needs_bash
def test_the_nginx_check_waits_for_the_reload_to_take_over():
    snippet = 'tries=0; flaky() { tries=$((tries + 1)); [ "$tries" -ge 3 ]; }; retry_for 10 flaky && echo "ok after $tries"'
    result = run_sourced("install.sh", snippet)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "ok after 3"


@needs_bash
def test_the_nginx_check_still_gives_up():
    result = run_sourced("install.sh", 'never() { return 1; }; retry_for 1 never || echo "gave up"')
    assert result.stdout.strip() == "gave up"


@needs_bash
def test_wait_for_health_retries_the_nginx_check():
    source = INSTALL_SH.read_text(encoding="utf-8")
    body = source.split("wait_for_health() {", 1)[1].split("\n}\n", 1)[0]
    assert "retry_for 15 nginx_forwards" in body


# --- git never waits in a pager ----------------------------------------------------------------


@needs_bash
@pytest.mark.parametrize("script", ["install.sh", "update.sh"])
def test_git_runs_without_a_pager(script):
    """update.sh prints the list of new commits straight to the terminal: git showed it in a
    pager, which waits for q once the list is longer than the screen (on the VM the pager's
    keypad codes showed up around a one-line list)."""
    snippet = 'runuser() { printf "%s\\n" "$@"; }; SERVICE_USER=scout INSTALL_DIR=/opt/x SERVICE_HOME=/home/scout; as_user git log'
    result = run_sourced(script, snippet)
    assert result.returncode == 0, result.stderr
    assert "GIT_PAGER=cat" in result.stdout.splitlines()


# --- "installed and running" means that jobs can run -------------------------------------------


@pytest.fixture
def health_server():
    """A stand-in for the app's /api/health; set .reply and .credentials ("user:password")."""

    class Handler(BaseHTTPRequestHandler):
        reply: dict = {}
        credentials: str | None = None
        requests: list = []

        def do_GET(self):  # noqa: N802 - the http.server API
            Handler.requests.append((self.path, self.headers.get("Authorization")))
            if Handler.credentials is not None:
                expected = "Basic " + base64.b64encode(Handler.credentials.encode()).decode()
                if self.headers.get("Authorization") != expected:
                    self.send_response(401)
                    self.end_headers()
                    return
            body = json.dumps(Handler.reply).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield server, Handler
    server.shutdown()
    server.server_close()


HEALTHY = {"status": "ok", "queue_backend": "sqlite", "queue_ok": True, "ffmpeg_available": True}


def health_problems(script: str, env_file: Path, port: int, tmp_path: Path) -> subprocess.CompletedProcess[str]:
    if script == "install.sh":
        snippet = 'ENV_FILE=$1 PORT=$2; health_problems; echo "[done]"'
    else:  # update.sh reads the port from the installed unit, else .env
        snippet = 'ENV_FILE=$1 SYSTEMD_DIR=$3; health_problems; echo "[done]"'
    return run_sourced(script, snippet, str(env_file), str(port), str(tmp_path / "no-systemd"))


@needs_bash
@pytest.mark.parametrize("script", ["install.sh", "update.sh"])
def test_a_queue_that_does_not_answer_is_reported(health_server, tmp_path, script):
    server, handler = health_server
    port = server.server_address[1]
    handler.reply = {**HEALTHY, "status": "degraded", "queue_backend": "redis", "queue_ok": False}
    handler.credentials = "coach:typed-password"
    env_file = tmp_path / ".env"
    env_file.write_text(f"SCOUT_PORT={port}\nSCOUT_AUTH_PASSWORD=typed-password\n")
    result = health_problems(script, env_file, port, tmp_path)
    assert result.returncode == 0, result.stderr
    assert "block\tthe job queue (redis) does not answer (check: sudo systemctl status redis-server)" in result.stdout
    assert handler.requests and handler.requests[-1][0] == "/api/health"
    assert "typed-password" not in result.stdout + result.stderr


@needs_bash
@pytest.mark.parametrize("script", ["install.sh", "update.sh"])
def test_a_healthy_server_reports_nothing(health_server, tmp_path, script):
    server, handler = health_server
    port = server.server_address[1]
    handler.reply = {**HEALTHY, "status": "degraded", "modal_configured": False}  # no Modal token yet: not a blocker
    handler.credentials = "coach:pw"
    env_file = tmp_path / ".env"
    env_file.write_text(f"SCOUT_PORT={port}\nSCOUT_AUTH_PASSWORD=pw\n")
    result = health_problems(script, env_file, port, tmp_path)
    assert result.stdout.strip() == "[done]"


@needs_bash
@pytest.mark.parametrize(
    ("processor", "line"),
    [
        ("local", "block\tffmpeg is missing, so no film can be prepared"),
        ("modal", "note\tffmpeg is missing, so uploads skip the film length check"),
        ("mock", "note\tffmpeg is missing, so uploads skip the film length check"),
    ],
)
def test_missing_ffmpeg_stops_jobs_only_for_the_local_gpu(health_server, tmp_path, processor, line):
    """Only the local GPU pipeline runs ffmpeg on the server; with Modal an upload just skips
    the optional ffprobe length check (the app's own status panel calls it a warning)."""
    server, handler = health_server
    port = server.server_address[1]
    handler.reply = {**HEALTHY, "processor": processor, "ffmpeg_available": False}
    env_file = tmp_path / ".env"
    env_file.write_text("SCOUT_AUTH_DISABLED=true\n")
    result = health_problems("install.sh", env_file, port, tmp_path)
    assert line in result.stdout
    assert handler.requests[-1][1] is None, "no credentials are sent when sign-in is off"


@needs_bash
@pytest.mark.parametrize("script", ["install.sh", "update.sh"])
def test_a_name_and_password_with_quotes_and_backslashes_sign_in(health_server, tmp_path, script):
    server, handler = health_server
    port = server.server_address[1]
    handler.reply = {**HEALTHY, "queue_ok": False}
    handler.credentials = 'he"ad\\coach:pa"ss\\word'
    env_file = tmp_path / ".env"
    env_file.write_text(f"SCOUT_PORT={port}\nSCOUT_AUTH_USERNAME='he\"ad\\coach'\nSCOUT_AUTH_PASSWORD='pa\"ss\\word'\n")
    result = health_problems(script, env_file, port, tmp_path)
    assert "block\tthe job queue" in result.stdout, (result.stdout, result.stderr, handler.requests)


@needs_bash
@pytest.mark.parametrize("script", ["install.sh", "update.sh"])
@pytest.mark.parametrize(
    "env",
    [
        "SCOUT_AUTH_PASSWORD_HASH='pbkdf2_sha256$600000$x$y'\n",
        # README's way to switch to a hash leaves the generated password in place: the app
        # then signs in with the hash, so asking with the password would fail (and count).
        "SCOUT_AUTH_PASSWORD=old-generated\nSCOUT_AUTH_PASSWORD_HASH='pbkdf2_sha256$600000$x$y'\n",
    ],
)
def test_a_password_hash_means_no_question_and_says_it_could_not_check(health_server, tmp_path, script, env):
    server, handler = health_server
    port = server.server_address[1]
    env_file = tmp_path / ".env"
    env_file.write_text(f"SCOUT_PORT={port}\n{env}")
    result = health_problems(script, env_file, port, tmp_path)
    assert result.stdout.startswith("?\tthe sign-in uses SCOUT_AUTH_PASSWORD_HASH"), result.stdout
    assert handler.requests == []


@needs_bash
def test_an_app_that_does_not_answer_is_reported_as_not_checked(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text("SCOUT_AUTH_PASSWORD=pw\n")
    result = health_problems("install.sh", env_file, 9, tmp_path)  # nothing listens on port 9
    assert result.returncode == 0
    assert result.stdout.startswith("?\tthe app did not answer /api/health")


@needs_bash
def test_a_refused_sign_in_is_reported_as_not_checked(health_server, tmp_path):
    server, handler = health_server
    port = server.server_address[1]
    handler.reply = {**HEALTHY, "queue_ok": False}
    handler.credentials = "coach:the-real-one"
    env_file = tmp_path / ".env"
    env_file.write_text(f"SCOUT_PORT={port}\nSCOUT_AUTH_PASSWORD=a-stale-one\n")
    result = health_problems("install.sh", env_file, port, tmp_path)
    assert result.stdout.startswith("?\tthe app did not answer /api/health"), result.stdout


REPORT = """
REPORTED=$1
health_problems() { printf '%b' "$REPORTED"; }
JOBS_BLOCKED=${PRESET:-0}
report_job_health
echo "JOBS_BLOCKED=${JOBS_BLOCKED:-n/a}"
"""


@needs_bash
@pytest.mark.parametrize("script", ["install.sh", "update.sh"])
@pytest.mark.parametrize(
    ("reported", "preset", "says", "blocked", "ok"),
    [
        ("", "0", [], "0", True),
        ("block\\tthe job queue (redis) does not answer\\n", "0", ["Jobs cannot run: the job queue (redis) does not answer."], "1", False),
        ("note\\tffmpeg is missing, so uploads skip the film length check\\n", "0", ["ffmpeg is missing, so uploads skip the film length check."], "0", True),
        ("?\\tthe sign-in uses SCOUT_AUTH_PASSWORD_HASH\\n", "0", ["Could not check that jobs can run: the sign-in uses SCOUT_AUTH_PASSWORD_HASH."], "0", False),
    ],
)
def test_what_the_health_check_says(script, reported, preset, says, blocked, ok):
    result = run_sourced(script, REPORT, reported, env={"PRESET": preset})
    assert result.returncode == 0, result.stderr
    output = result.stdout + result.stderr
    for text in says:
        assert text in output
    assert ("Jobs can run" in output) is ok, output
    if script == "install.sh":
        assert f"JOBS_BLOCKED={blocked}" in result.stdout


@needs_bash
def test_no_jobs_can_run_line_after_the_worker_did_not_start():
    """install.sh sets JOBS_BLOCKED when the worker is not running (update.sh stops there)."""
    result = run_sourced("install.sh", REPORT, "", env={"PRESET": "1"})
    assert "Jobs can run" not in result.stdout + result.stderr
    assert "JOBS_BLOCKED=1" in result.stdout


WAIT = """
curl() { return 0; }          # the web app answers
systemctl() { return 1; }     # ... but the worker is not active
report_job_health() { echo "health checked"; }
PORT=8000 WITH_NGINX=0
wait_for_health
echo "JOBS_BLOCKED=$JOBS_BLOCKED"
"""


@needs_bash
def test_a_worker_that_does_not_run_changes_the_banner():
    result = run_sourced("install.sh", WAIT)
    assert result.returncode == 0, result.stderr
    assert "The worker is not running, so no job can run" in result.stderr
    assert "JOBS_BLOCKED=1" in result.stdout


@needs_bash
def test_the_summary_says_when_jobs_cannot_run():
    source = INSTALL_SH.read_text(encoding="utf-8")
    assert "installed, but jobs cannot run yet" in source.split("print_summary() {", 1)[1]


# --- the firewall tip --------------------------------------------------------------------------

UFW = """
ufw() {
  printf '%s\\n' "Status: active" "" "To                         Action      From" \\
    "--                         ------      ----"
  printf '%s\\n' "$RULES"
}
ufw_allows "$1" && echo allowed || echo missing
"""


@needs_bash
@pytest.mark.parametrize(
    ("rules", "rule", "answer"),
    [
        ("OpenSSH                    ALLOW       Anywhere\n80/tcp                     ALLOW       Anywhere", "80/tcp", "allowed"),
        ("80                         ALLOW       Anywhere", "80/tcp", "allowed"),
        ("OpenSSH                    ALLOW       Anywhere", "80/tcp", "missing"),
        ("80/tcp                     DENY        Anywhere", "80/tcp", "missing"),
        ("80/tcp                     ALLOW       Anywhere", "8000/tcp", "missing"),
        ("8000/tcp                   ALLOW       Anywhere", "8000/tcp", "allowed"),
        # `ufw allow out 80/tcp` (for apt on a server that blocks outgoing) lets nobody in
        ("80/tcp                     ALLOW OUT   Anywhere", "80/tcp", "missing"),
        ("80/tcp                     ALLOW FWD   Anywhere", "80/tcp", "missing"),
    ],
)
def test_ufw_rules_are_read(rules, rule, answer):
    result = run_sourced("install.sh", UFW, rule, env={"RULES": rules})
    assert result.stdout.strip() == answer


SUMMARY = """
ufw() {
  if [[ $1 == status ]]; then
    printf '%s\\n' "Status: active" "80/tcp                     ALLOW       Anywhere"
  fi
}
hostname() { echo 192.0.2.10; }
INSTALL_DIR=$1 ENV_FILE=$1/.env DATA_DIR=$1/data SERVICE_USER=scout PORT=8000 WITH_NGINX=1
EFFECTIVE_PROCESSOR=mock
print_summary
"""


@needs_bash
def test_the_summary_does_not_ask_for_a_firewall_rule_that_is_there(install_dir):
    (install_dir / ".env").write_text("SCOUT_AUTH_USERNAME=coach\nSCOUT_AUTH_PASSWORD=pw\nANTHROPIC_API_KEY=sk-ant-x\n")
    result = run_sourced("install.sh", SUMMARY, str(install_dir))
    assert result.returncode == 0, result.stderr
    assert "ufw" not in result.stdout, result.stdout
    assert "Basketball Scout is installed and running" in result.stdout


# --- uninstall.sh: notes that fit this server --------------------------------------------------

UNINSTALL_SUMMARY = """
dpkg-query() { case " $INSTALLED " in *" ${@: -1} "*) printf 'install ok installed' ;; esac; }
DATA_DIR=/var/lib/basketball-scout PURGE=0 REMOVE_MODAL=0 MODAL_USED=$1 ANTHROPIC_USED=$2
print_summary
"""


@needs_bash
def test_uninstall_does_not_mention_what_this_server_never_had():
    result = run_sourced("uninstall.sh", UNINSTALL_SUMMARY, "0", "0", env={"INSTALLED": "nginx"})
    assert result.returncode == 0, result.stderr
    out = result.stdout
    assert "System packages (nginx, ffmpeg, python3) were left installed." in out
    assert "sudo apt-get purge nginx\n" in out
    assert "redis" not in out
    assert "Modal" not in out and "Revoke" not in out and "Anthropic" not in out


@needs_bash
def test_uninstall_names_the_modal_app_and_both_keys_when_they_were_used():
    result = run_sourced("uninstall.sh", UNINSTALL_SUMMARY, "1", "1", env={"INSTALLED": "nginx redis-server"})
    out = result.stdout
    assert "System packages (nginx, redis-server, ffmpeg, python3) were left installed." in out
    assert "sudo apt-get purge nginx redis-server" in out
    assert "modal app stop basketball-scout -y" in out
    assert "Revoke the Modal token (Modal dashboard) and the Anthropic API key" in out


@needs_bash
@pytest.mark.parametrize(("modal", "anthropic", "line"), [("1", "0", "Revoke the Modal token this server used"), ("0", "1", "Revoke the Anthropic API key this server used")])
def test_uninstall_names_only_the_key_that_was_used(modal, anthropic, line):
    result = run_sourced("uninstall.sh", UNINSTALL_SUMMARY, modal, anthropic, env={"INSTALLED": ""})
    assert line in result.stdout
    assert "Not reinstalling?" not in result.stdout, "nothing to purge"


UNINSTALL_RESOLVE = """
user_home() { printf '%s' "$HOME_DIR"; }
INSTALL_DIR=$1 DATA_DIR=$2 SERVICE_USER=scout SYSTEMD_DIR=$1/no-systemd
resolve
echo "MODAL_USED=$MODAL_USED ANTHROPIC_USED=$ANTHROPIC_USED"
"""


@needs_bash
@pytest.mark.parametrize(
    ("env", "marker", "used"),
    [
        ("", None, "MODAL_USED=0 ANTHROPIC_USED=0"),
        ("MODAL_TOKEN_ID=ak-x\nMODAL_TOKEN_SECRET=as-y\n", None, "MODAL_USED=1 ANTHROPIC_USED=0"),
        ("ANTHROPIC_API_KEY=sk-ant-x\n", None, "MODAL_USED=0 ANTHROPIC_USED=1"),
        ("", ".git/basketball-scout-modal", "MODAL_USED=1 ANTHROPIC_USED=0"),
        ("", "home/.modal.toml", "MODAL_USED=1 ANTHROPIC_USED=0"),
    ],
)
def test_uninstall_finds_what_this_server_used(install_dir, tmp_path, env, marker, used):
    (install_dir / "scout").mkdir()
    (install_dir / "scout" / "main.py").write_text("")
    (install_dir / ".env").write_text(f"SCOUT_DATA_DIR={tmp_path / 'data'}\n{env}")
    home = tmp_path / "home"
    home.mkdir()
    if marker == ".git/basketball-scout-modal":
        (install_dir / ".git").mkdir()
        (install_dir / ".git" / "basketball-scout-modal").write_text("abc123\n")
    elif marker:
        (tmp_path / marker).write_text("[default]\n")
    result = run_sourced("uninstall.sh", UNINSTALL_RESOLVE, str(install_dir), str(tmp_path / "data"), env={"HOME_DIR": str(home)})
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip().splitlines()[-1] == used


def test_env_example_is_where_the_tests_expect_it():
    assert ENV_EXAMPLE.is_file()
