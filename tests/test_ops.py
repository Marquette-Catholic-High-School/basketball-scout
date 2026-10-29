"""Checks for the ops files: install / update / uninstall / dev scripts, the systemd and
nginx templates, .env.example, the Makefile and the docs.

Nothing here needs root, Linux, a network or a GPU. The scripts are syntax-checked and run
with --help (macOS ships bash 3.2, so this also keeps option parsing portable), and the
.env and template helpers are exercised by sourcing scripts/install.sh, which skips
main() when it is sourced.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest
from dotenv import dotenv_values
from pydantic import AliasChoices

from scout.config import Settings
from scout.errors import ErrorCode

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = ROOT / "scripts"
INSTALL_SH = SCRIPTS_DIR / "install.sh"
ENV_EXAMPLE = ROOT / ".env.example"
README = ROOT / "README.md"
SCRIPTS = ("install.sh", "uninstall.sh", "update.sh", "dev.sh")
UNITS = ("basketball-scout-web.service", "basketball-scout-worker.service")
NGINX_TEMPLATE = ROOT / "deploy" / "nginx" / "basketball-scout.conf"
REPO_URL = "https://github.com/Marquette-Catholic-High-School/basketball-scout.git"
BASH = shutil.which("bash")
IS_ROOT = hasattr(os, "geteuid") and os.geteuid() == 0

needs_bash = pytest.mark.skipif(BASH is None, reason="bash is not installed")

# "KEY=value" or a documented, commented-out "# KEY=value".
SETTING_LINE = re.compile(r"^\s*#?\s*([A-Z][A-Z0-9_]*)=")
# SCOUT_* keys that modal_app/app.py reads at `modal deploy` time (not Settings fields).
DEPLOY_TIME_KEYS = {"SCOUT_MODAL_GPU", "SCOUT_MODAL_TIMEOUT_S", "SCOUT_MODAL_MAX_CONTAINERS"}
# Keys read straight from the environment by the Modal / Anthropic SDKs or the GPU pipeline.
SDK_KEYS = {"ANTHROPIC_API_KEY", "MODAL_TOKEN_ID", "MODAL_TOKEN_SECRET", "MODAL_ENVIRONMENT", "OHV_HOME"}

INSTALL_FLAGS = {
    "--dir": "/opt/scout-test",
    "--data-dir": "/var/lib/scout-test",
    "--user": "scout",
    "--branch": "main",
    "--repo": REPO_URL,
    "--port": "8000",
    "--with-redis": None,
    "--with-nginx": None,
    "--domain": "scout.example.org",
    "--processor": "mock",
    "--modal-token-id": "ak-test",
    "--modal-token-secret": "as-test",
    "--anthropic-key": "sk-ant-test",
    "--deploy-modal": None,
    "--non-interactive": None,
    "-y": None,
}
UPDATE_FLAGS = {
    "--dir": "/opt/scout-test",
    "--branch": "main",
    "--deploy-modal": None,
    "--no-deploy-modal": None,
    "--force": None,
    "--skip-restart": None,
}
UNINSTALL_FLAGS = {
    "--dir": "/opt/scout-test",
    "--data-dir": "/var/lib/scout-test",
    "--user": "scout",
    "--purge": None,
    "--remove-user": None,
    "--remove-modal": None,
    "--yes": None,
    "-y": None,
}

# Constructs that need bash 4+; the scripts must run (--help, sourced helpers) on bash 3.2.
BASH4_ONLY = (
    r"declare -A",
    r"\bmapfile\b",
    r"\breadarray\b",
    r"\$\{[A-Za-z_]+,,\}",
    r"\$\{[A-Za-z_]+\^\^\}",
    r"\|&",
    r"&>>",
    r"\bcoproc\b",
    r"wait -n",
    r"local -n",
    r"\[\[ -v ",
)


# --- helpers ------------------------------------------------------------------------------


def script_env() -> dict[str, str]:
    """A small, predictable environment: no colours, no keys from the developer's shell."""
    return {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": os.environ.get("HOME", "/tmp"), "NO_COLOR": "1"}


def run_script(name: str, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [BASH, str(SCRIPTS_DIR / name), *args],
        capture_output=True,
        text=True,
        timeout=60,
        env=script_env(),
        stdin=subprocess.DEVNULL,
    )


def source_install(snippet: str, *args: str) -> subprocess.CompletedProcess[str]:
    """Run ``snippet`` in bash after sourcing install.sh (main() does not run); $1.. = args."""
    return subprocess.run(
        [BASH, "-c", f'source "$INSTALL_SH"; {snippet}', "test-ops", *args],
        capture_output=True,
        text=True,
        timeout=60,
        env={**script_env(), "INSTALL_SH": str(INSTALL_SH)},
        stdin=subprocess.DEVNULL,
    )


def env_example_keys() -> list[str]:
    keys = []
    for line in ENV_EXAMPLE.read_text().splitlines():
        match = SETTING_LINE.match(line)
        if match:
            keys.append(match.group(1))
    return keys


def settings_env_names() -> dict[str, str]:
    """Settings field -> the environment variable that sets it."""
    names = {}
    for name, field in Settings.model_fields.items():
        alias = field.validation_alias
        if isinstance(alias, AliasChoices):
            names[name] = str(alias.choices[0])
        elif isinstance(alias, str):
            names[name] = alias
        else:
            names[name] = f"SCOUT_{name.upper()}"
    return names


def unit_directives(name: str) -> dict[str, list[str]]:
    """Section -> "Key=Value" lines of a systemd template (comments skipped)."""
    sections: dict[str, list[str]] = {}
    current = None
    for line in (ROOT / "deploy" / "systemd" / name).read_text().splitlines():
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        if text.startswith("["):
            current = text
            sections[current] = []
            continue
        assert current, f"{name}: {text!r} comes before any [Section]"
        assert re.fullmatch(r"[A-Za-z]+=.*", text), f"{name}: not a Key=Value line: {text!r}"
        sections[current].append(text)
    return sections


# --- scripts ------------------------------------------------------------------------------


@needs_bash
@pytest.mark.parametrize("name", SCRIPTS)
def test_script_syntax(name):
    result = subprocess.run([BASH, "-n", str(SCRIPTS_DIR / name)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("name", SCRIPTS)
def test_script_header_and_mode(name):
    path = SCRIPTS_DIR / name
    lines = path.read_text().splitlines()
    assert lines[0] == "#!/usr/bin/env bash"
    assert "set -Eeuo pipefail" in lines
    assert os.access(path, os.X_OK), f"{name} is not executable: chmod +x scripts/{name}"


@pytest.mark.parametrize("name", SCRIPTS)
def test_scripts_avoid_bash4_only_features(name):
    code = "\n".join(line for line in (SCRIPTS_DIR / name).read_text().splitlines() if not line.lstrip().startswith("#"))
    for pattern in BASH4_ONLY:
        assert not re.search(pattern, code), f"{name} uses {pattern!r}, which bash 3.2 (macOS) lacks"


@needs_bash
@pytest.mark.parametrize("name", SCRIPTS)
@pytest.mark.parametrize("flag", ["--help", "-h"])
def test_help_exits_zero_without_root(name, flag):
    result = run_script(name, flag)
    assert result.returncode == 0, result.stderr
    assert "Usage:" in result.stdout
    assert result.stderr == ""


@needs_bash
def test_install_help_works_when_piped_into_bash():
    # curl -fsSL .../install.sh | sudo bash -s -- --help
    result = subprocess.run(
        [BASH, "-s", "--", "--help"],
        input=INSTALL_SH.read_text(),
        capture_output=True,
        text=True,
        timeout=60,
        env=script_env(),
    )
    assert result.returncode == 0, result.stderr
    assert "Usage:" in result.stdout


@needs_bash
@pytest.mark.parametrize(
    ("name", "flags"), [("install.sh", INSTALL_FLAGS), ("update.sh", UPDATE_FLAGS), ("uninstall.sh", UNINSTALL_FLAGS)]
)
def test_documented_flags_are_accepted(name, flags):
    help_text = run_script(name, "--help").stdout
    for flag, value in flags.items():
        assert flag in help_text, f"{name} --help does not mention {flag}"
        args = [flag] if value is None else [flag, value]
        result = run_script(name, *args, "--help")  # parsed in order, so --help exits after the flag
        assert result.returncode == 0, f"{name} rejected {flag}: {result.stderr}"


@needs_bash
@pytest.mark.parametrize(
    ("args", "message"),
    [
        (["--bogus"], "Unknown option: --bogus"),
        (["--processor", "gpu"], "--processor must be"),
        (["--processor=gpu"], "--processor must be"),
        (["--port", "80"], "--port must be"),
        (["--port", "eighty"], "--port must be"),
        (["--dir", "relative/path"], "--dir must be"),
        (["--dir", "/opt/my scout"], "--dir must be"),
        (["--data-dir", "/var/lib/../etc"], "--data-dir must be"),
        (["--user", "Coach Smith"], "--user must be"),
        (["--domain", "bad domain!"], "--domain must be"),
        (["--modal-token-id", "ak-only"], "both the Modal token ID and the token secret"),
        (["--anthropic-key", "sk-ant 'pasted'"], "unexpected characters"),
        (["--dir"], "--dir needs a value"),
    ],
)
def test_install_rejects_bad_options_before_doing_anything(args, message):
    result = run_script("install.sh", *args)
    assert result.returncode != 0
    assert message in result.stderr


@needs_bash
def test_update_rejects_conflicting_modal_flags():
    result = run_script("update.sh", "--deploy-modal", "--no-deploy-modal")
    assert result.returncode != 0
    assert "not both" in result.stderr


@needs_bash
@pytest.mark.skipif(IS_ROOT, reason="as root these would really install / update / uninstall")
@pytest.mark.parametrize(("name", "args"), [("install.sh", ["-y"]), ("update.sh", []), ("uninstall.sh", ["-y"])])
def test_server_scripts_require_root(name, args):
    result = run_script(name, *args)
    assert result.returncode != 0
    assert "root" in result.stderr


@needs_bash
def test_sourcing_install_sh_does_not_run_main():
    result = source_install("echo sourced-ok")
    assert result.returncode == 0, result.stderr
    assert result.stdout == "sourced-ok\n"


# --- install.sh helpers (sourced) ---------------------------------------------------------------


@needs_bash
def test_env_set_replaces_uncomments_and_appends(tmp_path):
    env = tmp_path / ".env"
    env.write_text("SCOUT_PORT=8000\n# SCOUT_DB_PATH=/x/scout.db\nSCOUT_HOST=1.1.1.1\nSCOUT_HOST=2.2.2.2\nQUOTED='a$b'\n")
    result = source_install(
        'env_set "$1" SCOUT_PORT 9000; env_set "$1" SCOUT_DB_PATH /var/lib/s/scout.db; '
        'env_set "$1" SCOUT_HOST 127.0.0.1; env_set "$1" ANTHROPIC_API_KEY sk-ant-x_y',
        str(env),
    )
    assert result.returncode == 0, result.stderr
    assert env.read_text().splitlines() == [
        "SCOUT_PORT=9000",
        "SCOUT_DB_PATH=/var/lib/s/scout.db",
        "SCOUT_HOST=127.0.0.1",
        "QUOTED='a$b'",
        "ANTHROPIC_API_KEY=sk-ant-x_y",
    ]
    values = dotenv_values(env)  # the parser the app uses agrees
    assert values["SCOUT_HOST"] == "127.0.0.1"
    assert values["QUOTED"] == "a$b"


@needs_bash
def test_env_get_reads_values_like_python_dotenv(tmp_path):
    env = tmp_path / ".env"
    env.write_text("A=1\nA=2\nB='x y'\nC=\"q\"\n# D=4\nE=\nWIN=crlf\r\n")
    parsed = dotenv_values(env)
    for key, expected in {"A": "2", "B": "x y", "C": "q", "D": "", "E": "", "WIN": "crlf", "MISSING": ""}.items():
        result = source_install('env_get "$1" "$2"', str(env), key)
        assert result.returncode == 0, result.stderr
        assert result.stdout.rstrip("\n") == expected, key
        if key in parsed:
            assert parsed[key] == expected, key


@needs_bash
def test_env_append_missing_adds_new_settings_only(tmp_path):
    env = tmp_path / ".env"
    env.write_text("SCOUT_AUTH_PASSWORD=kept-secret\nSCOUT_PROCESSOR=mock")  # no final newline
    first = source_install('env_append_missing "$1" "$2"', str(ENV_EXAMPLE), str(env))
    assert first.returncode == 0, first.stderr
    assert int(first.stdout.strip()) == len(set(env_example_keys())) - 2
    values = dotenv_values(env)
    assert values["SCOUT_AUTH_PASSWORD"] == "kept-secret"
    assert values["SCOUT_PROCESSOR"] == "mock"
    present = {m.group(1) for line in env.read_text().splitlines() if (m := SETTING_LINE.match(line))}
    assert present == set(env_example_keys())
    Settings(_env_file=env)  # the merged file is a valid configuration

    before = env.read_text()
    again = source_install('env_append_missing "$1" "$2"', str(ENV_EXAMPLE), str(env))
    assert again.stdout.strip() == "0"
    assert env.read_text() == before


CONFIGURE_ENV = """
chown() { :; }   # there is no service user on the test machine
INSTALL_DIR=$1 DATA_DIR=$2 ENV_FILE="$1/.env" SERVICE_USER=scout SERVICE_GROUP=scout
PORT=${PORT_OPT:-8000} BIND_HOST=127.0.0.1 PROCESSOR=${PROCESSOR_OPT:-} WITH_REDIS=${REDIS_OPT:-0}
ANTHROPIC_KEY=${KEY_OPT:-} MODAL_ID=${MODAL_ID_OPT:-} MODAL_SECRET=${MODAL_SECRET_OPT:-}
configure_env
echo "NEW_PASSWORD=[$NEW_PASSWORD]"
"""


def configure_env(install_dir: Path, data_dir: Path, **options: str) -> subprocess.CompletedProcess[str]:
    """Run install.sh's configure_env step against a temp install folder (options: *_OPT env vars)."""
    return subprocess.run(
        [BASH, "-c", f'source "$INSTALL_SH"; {CONFIGURE_ENV}', "test-ops", str(install_dir), str(data_dir)],
        capture_output=True,
        text=True,
        timeout=60,
        env={**script_env(), "INSTALL_SH": str(INSTALL_SH), **options},
        stdin=subprocess.DEVNULL,
    )


@pytest.fixture
def install_dir(tmp_path):
    folder = tmp_path / "opt" / "basketball-scout"
    folder.mkdir(parents=True)
    shutil.copy(ENV_EXAMPLE, folder / ".env.example")
    return folder


@needs_bash
def test_configure_env_first_install(install_dir, tmp_path):
    result = configure_env(
        install_dir,
        tmp_path / "data",
        PORT_OPT="8123",
        PROCESSOR_OPT="mock",
        REDIS_OPT="1",
        KEY_OPT="sk-ant-test-key",
        MODAL_ID_OPT="ak-test-id",
        MODAL_SECRET_OPT="as-test-secret",
    )
    assert result.returncode == 0, result.stderr
    env_file = install_dir / ".env"
    values = dotenv_values(env_file)
    password = re.search(r"NEW_PASSWORD=\[(.*)\]", result.stdout).group(1)
    assert re.fullmatch(r"[a-z2-9]{5}(-[a-z2-9]{5}){3}", password)
    assert values["SCOUT_AUTH_PASSWORD"] == password
    assert values["SCOUT_DATA_DIR"] == str(tmp_path / "data")
    assert (values["SCOUT_HOST"], values["SCOUT_PORT"]) == ("127.0.0.1", "8123")
    assert (values["SCOUT_PROCESSOR"], values["SCOUT_QUEUE_BACKEND"]) == ("mock", "redis")
    assert (values["ANTHROPIC_API_KEY"], values["MODAL_TOKEN_ID"], values["MODAL_TOKEN_SECRET"]) == (
        "sk-ant-test-key",
        "ak-test-id",
        "as-test-secret",
    )
    assert env_file.stat().st_mode & 0o777 == 0o600
    for secret in ("sk-ant-test-key", "ak-test-id", "as-test-secret"):
        assert secret not in result.stdout + result.stderr, "secrets must never be printed"
    assert not list(install_dir.glob(".env.bak-*")), "a brand-new .env needs no backup"
    Settings(_env_file=env_file)  # a valid configuration


@needs_bash
def test_configure_env_rerun_keeps_settings_and_password(install_dir, tmp_path):
    assert configure_env(install_dir, tmp_path / "data").returncode == 0
    env_file = install_dir / ".env"
    password = dotenv_values(env_file)["SCOUT_AUTH_PASSWORD"]
    env_file.write_text(env_file.read_text().replace("SCOUT_WORKER_CONCURRENCY=2", "SCOUT_WORKER_CONCURRENCY=4"))
    before = env_file.read_text()

    again = configure_env(install_dir, tmp_path / "data")
    assert again.returncode == 0, again.stderr
    assert "NEW_PASSWORD=[]" in again.stdout, "the password is generated only once"
    assert env_file.read_text() == before, "a re-run without options changes nothing"
    assert not list(install_dir.glob(".env.bak-*"))

    changed = configure_env(install_dir, tmp_path / "data", PORT_OPT="9000")
    assert changed.returncode == 0, changed.stderr
    values = dotenv_values(env_file)
    assert values["SCOUT_PORT"] == "9000"
    assert values["SCOUT_WORKER_CONCURRENCY"] == "4", "hand edits survive"
    assert values["SCOUT_AUTH_PASSWORD"] == password
    backups = list(install_dir.glob(".env.bak-*"))
    assert len(backups) == 1 and dotenv_values(backups[0])["SCOUT_PORT"] == "8000"


@needs_bash
def test_configure_env_restores_the_uninstall_backup(install_dir, tmp_path):
    data_dir = tmp_path / "data"
    (data_dir / "backups").mkdir(parents=True)
    (data_dir / "backups" / "env-20260101-000000").write_text("SCOUT_AUTH_PASSWORD=old-one\n")
    (data_dir / "backups" / "env-20260301-000000").write_text("SCOUT_AUTH_PASSWORD=kept-password\nSCOUT_PROCESSOR=mock\n")
    result = configure_env(install_dir, data_dir)
    assert result.returncode == 0, result.stderr
    assert "NEW_PASSWORD=[]" in result.stdout
    values = dotenv_values(install_dir / ".env")
    assert values["SCOUT_AUTH_PASSWORD"] == "kept-password"  # the newest backup wins
    assert values["SCOUT_PROCESSOR"] == "mock"
    assert values["SCOUT_DATA_DIR"] == str(data_dir)
    lines = (install_dir / ".env").read_text().splitlines()
    present = {match.group(1) for line in lines if (match := SETTING_LINE.match(line))}
    assert set(env_example_keys()) <= present, "settings missing from the old backup are added"


RESOLVE = 'SYSTEMD_DIR=$2 INSTALL_DIR=$1; resolve_settings; echo "$DATA_DIR|$PORT|$WITH_REDIS|$EFFECTIVE_PROCESSOR|$SERVICE_USER"'


@needs_bash
def test_rerun_reuses_the_earlier_install_choices(install_dir, tmp_path):
    systemd_dir = tmp_path / "systemd"
    systemd_dir.mkdir()
    (systemd_dir / UNITS[0]).write_text("[Service]\nUser=coachsvc\n")
    (install_dir / ".env").write_text(
        "SCOUT_DATA_DIR=/srv/scout-data\nSCOUT_PORT=8200\nSCOUT_QUEUE_BACKEND=redis\nSCOUT_PROCESSOR=local\n"
    )
    result = source_install(RESOLVE, str(install_dir), str(systemd_dir))
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "/srv/scout-data|8200|1|local|coachsvc"


@needs_bash
def test_rerun_refuses_a_data_folder_inside_the_code_folder(install_dir, tmp_path):
    (install_dir / ".env").write_text(f"SCOUT_DATA_DIR={install_dir}/data\n")
    result = source_install(RESOLVE, str(install_dir), str(tmp_path / "no-systemd"))
    assert result.returncode != 0
    assert "outside the code folder" in result.stderr


@needs_bash
def test_generated_password_is_strong_and_typeable():
    passwords = {source_install("generate_password").stdout.strip() for _ in range(2)}
    assert len(passwords) == 2
    for password in passwords:
        assert re.fullmatch(r"[a-z2-9]{5}(-[a-z2-9]{5}){3}", password), password


@needs_bash
@pytest.mark.parametrize("name", UNITS)
def test_install_renders_systemd_units(tmp_path, name):
    out = tmp_path / name
    result = source_install(
        'render_template "$1" "$2" USER=scout GROUP=scout DIR=/opt/basketball-scout HOST=127.0.0.1 '
        "PORT=8123 DATA_DIR=/var/lib/basketball-scout HOME=/home/scout",
        str(ROOT / "deploy" / "systemd" / name),
        str(out),
    )
    assert result.returncode == 0, result.stderr
    text = out.read_text()
    assert not re.search(r"@[A-Z_]+@", text)
    assert "WorkingDirectory=/opt/basketball-scout\n" in text
    assert "EnvironmentFile=/opt/basketball-scout/.env\n" in text
    assert "ReadWritePaths=/var/lib/basketball-scout /home/scout\n" in text
    if "web" in name:
        assert "--host 127.0.0.1 --port 8123" in text


@needs_bash
@pytest.mark.parametrize(
    ("server_name", "default_server", "listen"),
    [("_", " default_server", "listen 80 default_server;"), ("scout.example.org", "", "listen 80;")],
)
def test_install_renders_nginx_site(tmp_path, server_name, default_server, listen):
    out = tmp_path / "site.conf"
    result = source_install(
        'render_template "$1" "$2" "SERVER_NAME=$3" "DEFAULT_SERVER=$4" PORT=8123',
        str(NGINX_TEMPLATE),
        str(out),
        server_name,
        default_server,
    )
    assert result.returncode == 0, result.stderr
    text = out.read_text()
    assert not re.search(r"@[A-Z_]+@", text)
    assert listen in text
    assert f"server_name {server_name};" in text
    assert "proxy_pass http://127.0.0.1:8123;" in text


@needs_bash
def test_render_template_refuses_unknown_placeholders(tmp_path):
    template = tmp_path / "template.conf"
    template.write_text("a=@KNOWN@\nb=@UNKNOWN@\n")
    result = source_install('render_template "$1" "$2" KNOWN=1', str(template), str(tmp_path / "out"))
    assert result.returncode != 0
    assert "@UNKNOWN@" in result.stderr
    assert not (tmp_path / "out").exists()


def test_install_passes_every_template_placeholder():
    passed = set(re.findall(r'"([A-Z_]+)=\$', INSTALL_SH.read_text()))
    for template in [*(ROOT / "deploy" / "systemd" / unit for unit in UNITS), NGINX_TEMPLATE]:
        placeholders = set(re.findall(r"@([A-Z_]+)@", template.read_text()))
        assert placeholders <= passed, f"{template.name}: install.sh never fills {placeholders - passed}"


# --- .env.example --------------------------------------------------------------------------------


def test_env_example_covers_every_setting():
    missing = set(settings_env_names().values()) - set(env_example_keys())
    assert not missing, f".env.example does not mention {sorted(missing)}"


def test_env_example_has_no_unknown_keys():
    known = set(settings_env_names().values()) | DEPLOY_TIME_KEYS | SDK_KEYS
    unknown = set(env_example_keys()) - known
    assert not unknown, f".env.example has keys that nothing reads: {sorted(unknown)}"
    assert {"ANTHROPIC_API_KEY", "MODAL_TOKEN_ID", "MODAL_TOKEN_SECRET"} <= set(env_example_keys())


def test_env_example_lists_each_key_once():
    keys = env_example_keys()
    assert not {key for key in keys if keys.count(key) > 1}


def test_env_example_values_are_the_defaults(monkeypatch):
    for name in list(os.environ):
        if name.startswith("SCOUT_") and name != "SCOUT_ENV_FILE":
            monkeypatch.delenv(name)
    from_example = Settings(_env_file=ENV_EXAMPLE)
    defaults = Settings(_env_file=None)
    for name in Settings.model_fields:
        if name in ("auth_password", "anthropic_api_key"):  # blank placeholders for secrets
            continue
        assert getattr(from_example, name) == getattr(defaults, name), f"{name}: .env.example differs from the default"


def test_env_example_ships_no_secrets_and_no_empty_optionals():
    values = dotenv_values(ENV_EXAMPLE)
    assert values["ANTHROPIC_API_KEY"] == ""
    assert values["SCOUT_AUTH_PASSWORD"] == ""
    # An empty MODAL_TOKEN_ID in the environment would hide ~/.modal.toml from the Modal SDK,
    # and an empty optional path would turn into "." (the repository folder).
    for key in ("MODAL_TOKEN_ID", "MODAL_TOKEN_SECRET", "SCOUT_AUTH_PASSWORD_HASH", "SCOUT_DB_PATH",
                "SCOUT_DETECTOR_WEIGHTS", "SCOUT_COURT_KEYPOINT_WEIGHTS", "SCOUT_MODAL_ENVIRONMENT"):  # fmt: skip
        assert key not in values, f"{key} must stay commented out in .env.example"


def test_env_example_lines_are_safe_for_systemd_and_dotenv():
    for number, line in enumerate(ENV_EXAMPLE.read_text().splitlines(), start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, separator, value = line.partition("=")
        assert separator, f"line {number}: expected KEY=value"
        assert re.fullmatch(r"[A-Z][A-Z0-9_]*", key), f"line {number}: odd key {key!r}"
        if value[:1] not in ("'", '"'):
            # systemd keeps "# comments" and spaces as part of an unquoted value.
            assert not re.search(r"[\s#$\"'\\]", value), f"line {number}: quote this value or move the comment"


# --- systemd and nginx templates -----------------------------------------------------------------


@pytest.mark.parametrize("name", UNITS)
def test_systemd_units_have_expected_directives(name):
    sections = unit_directives(name)
    assert set(sections) == {"[Unit]", "[Service]", "[Install]"}
    unit, service, install = sections["[Unit]"], sections["[Service]"], sections["[Install]"]
    for expected in ("After=network-online.target", "Wants=network-online.target"):
        assert expected in unit
    for expected in (
        "User=@USER@",
        "Group=@GROUP@",
        "WorkingDirectory=@DIR@",
        "EnvironmentFile=@DIR@/.env",
        "Restart=on-failure",
        "NoNewPrivileges=true",
        "PrivateTmp=true",
        "ProtectSystem=strict",
        "ProtectHome=read-only",
        "ReadWritePaths=@DATA_DIR@ @HOME@",
    ):
        assert expected in service, f"{name}: missing {expected}"
    # ProtectHome=true would hide ~/.modal.toml (the token from `modal token new`).
    assert "ProtectHome=true" not in service
    assert install == ["WantedBy=multi-user.target"]


def test_web_unit_runs_uvicorn_on_the_configured_address():
    service = unit_directives(UNITS[0])["[Service]"]
    exec_start = next(line for line in service if line.startswith("ExecStart="))
    assert exec_start.startswith("ExecStart=@DIR@/.venv/bin/python -m uvicorn scout.main:app ")
    assert "--host @HOST@ --port @PORT@" in exec_start
    assert "--forwarded-allow-ips 127.0.0.1" in exec_start


def test_worker_unit_stops_gracefully():
    service = unit_directives(UNITS[1])["[Service]"]
    assert "ExecStart=@DIR@/.venv/bin/python -m scout.worker" in service
    assert "KillSignal=SIGTERM" in service
    assert "TimeoutStopSec=60" in service
    # SCOUT_PROCESSOR=local needs /dev/nvidia*, which PrivateDevices would hide.
    assert "PrivateDevices=true" not in service


def test_nginx_template_handles_uploads_and_video():
    text = NGINX_TEMPLATE.read_text()
    for needle in (
        "listen 80@DEFAULT_SERVER@;",
        "server_name @SERVER_NAME@;",
        "client_max_body_size 64m;",
        "proxy_request_buffering off;",
        "proxy_read_timeout 600s;",
        "proxy_set_header Range $http_range;",
        "proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
        "proxy_pass http://127.0.0.1:@PORT@;",
    ):
        assert needle in text, f"nginx template lacks {needle}"
    code = re.sub(r"#.*", "", text)
    assert code.count("{") == code.count("}")


def test_nginx_body_limit_fits_an_upload_chunk():
    limit_mb = int(re.search(r"client_max_body_size (\d+)m;", NGINX_TEMPLATE.read_text()).group(1))
    assert Settings.model_fields["upload_chunk_mb"].default * 2 <= limit_mb


# --- Makefile and docs ------------------------------------------------------------------------------


def test_makefile_has_the_documented_targets():
    text = (ROOT / "Makefile").read_text()
    targets = set(re.findall(r"^([a-z][a-z-]*):", text, re.MULTILINE))
    expected = {"install", "dev", "test", "run-web", "run-worker", "deploy-modal", "warmup-modal", "lint", "clean"}
    assert expected <= targets
    for line in text.splitlines():
        assert not line.startswith(" "), f"Makefile recipes must be indented with a tab: {line!r}"


def test_readme_mentions_repo_and_key_commands():
    readme = README.read_text()
    for needle in (
        REPO_URL,
        "scripts/install.sh",
        "scripts/update.sh",
        "scripts/uninstall.sh",
        "scripts/dev.sh",
        "make dev",
        "SCOUT_PROCESSOR=mock",
        "modal token new",
        "modal deploy modal_app/app.py",
        "modal run modal_app/app.py::warmup",
        "modal app logs basketball-scout",
        "uvicorn scout.main:app",
        "python -m scout.worker",
        "python -m scout.auth hash-password",
        "pytest",
    ):
        assert needle in readme, f"README.md does not mention {needle!r}"


def test_readme_documents_every_setting():
    readme = README.read_text()
    missing = [key for key in env_example_keys() if key not in readme]
    assert not missing, f"README.md configuration reference lacks {missing}"


def test_readme_troubleshooting_covers_every_error_code():
    readme = README.read_text()
    missing = [code.value for code in ErrorCode if code.value not in readme]
    assert not missing, f"README.md troubleshooting lacks {missing}"
    assert "413" in readme


def test_readme_links_existing_docs():
    readme = README.read_text()
    for doc in ("docs/ARCHITECTURE.md", "docs/TRACKING_SCHEMA.md", "docs/FASTSCOUT.md", "docs/PROXMOX.md", "docs/DEPLOYMENT.md"):
        assert f"({doc})" in readme, f"README.md does not link {doc}"
        assert (ROOT / doc).is_file(), f"{doc} is missing"


def test_proxmox_doc_has_a_complete_qm_create():
    text = (ROOT / "docs" / "PROXMOX.md").read_text()
    match = re.search(r"^qm create (?:.*\\\n)*.*$", text, re.MULTILINE)  # the command with its continuation lines
    assert match, "docs/PROXMOX.md has no qm create command"
    command = match.group(0)
    for flag in (
        "--machine q35",
        "--bios ovmf",
        "--efidisk0",
        "pre-enrolled-keys=",
        "--cpu host",
        "--cores 8",
        "--memory 32768",
        "--scsihw virtio-scsi-single",
        ":200,",
        "iothread=1",
        "discard=on",
        "ssd=1",
        "cache=none",
        "--net0 virtio",
        "--agent enabled=1",
    ):
        assert flag in command, f"the qm create example lacks {flag}"


def test_deployment_doc_covers_operations():
    text = (ROOT / "docs" / "DEPLOYMENT.md").read_text()
    for needle in ("journalctl -u basketball-scout-web", "journalctl -u basketball-scout-worker", "/api/health",
                   "SCOUT_WORKER_CONCURRENCY", "max_containers", "certbot", "Restor"):  # fmt: skip
        assert needle in text, f"docs/DEPLOYMENT.md does not mention {needle!r}"
