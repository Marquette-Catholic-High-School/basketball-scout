#!/usr/bin/env bash
# Run Basketball Scout on your own computer for development (macOS or Linux).
#
#   scripts/dev.sh [--port N] [--host ADDRESS] [--no-install]        (or: make dev)
#
# 1. Creates .venv (Python 3.11+) and installs requirements-dev.txt when they changed.
# 2. Writes a development .env if there is none: SCOUT_PROCESSOR=mock (synthetic demo
#    data, no GPU or Modal account needed) and the password "dev".
# 3. Runs the web app with auto-reload on http://127.0.0.1:8000 and the worker side by
#    side, both logging to this terminal. Ctrl-C stops both.
#
# Works with the bash 3.2 that ships with macOS.

set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
PORT=${PORT:-8000}
HOST=${HOST:-127.0.0.1}
INSTALL_DEPS=1
WEB_PID=""
WORKER_PID=""
EXIT_STATUS=0

usage() {
  cat <<EOF
Run the Basketball Scout web app and worker locally for development.

Usage: scripts/dev.sh [options]

  --port N       web port (default: 8000, or the PORT environment variable)
  --host ADDR    address to listen on (default: 127.0.0.1, this computer only)
  --no-install   skip the "pip install -r requirements-dev.txt" check
  -h, --help     show this help

A new .env uses SCOUT_PROCESSOR=mock (demo data, no GPU) and the password "dev".
Sign in as "coach" / "dev" at http://127.0.0.1:8000/. Ctrl-C stops everything.
EOF
}

info() { printf '==> %s\n' "$*"; }

die() {
  printf 'dev.sh: %s\n' "$*" >&2
  exit 1
}

parse_args() {
  local port_re='^[0-9]{1,5}$'
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h | --help)
        usage
        exit 0
        ;;
      --port)
        if [[ $# -lt 2 ]]; then die "--port needs a value"; fi
        PORT=$2
        shift
        ;;
      --host)
        if [[ $# -lt 2 ]]; then die "--host needs a value"; fi
        HOST=$2
        shift
        ;;
      --no-install) INSTALL_DEPS=0 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  if [[ ! $PORT =~ $port_re ]]; then
    die "--port must be a number (got '$PORT')"
  fi
}

python_ok() {  # python_ok PYTHON: it runs and is version 3.11 or newer
  "$1" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1
}

find_python() {
  local candidate
  for candidate in python3.12 python3.13 python3.11 python3; do
    if command -v "$candidate" >/dev/null 2>&1 && python_ok "$candidate"; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

ensure_venv() {
  local python
  if [[ -e .venv ]]; then
    if ! python_ok .venv/bin/python; then
      die ".venv is broken or uses Python older than 3.11. Delete the .venv folder and run scripts/dev.sh again."
    fi
    return 0
  fi
  if ! python=$(find_python); then
    die "Python 3.11 or newer is needed. macOS: brew install python@3.12 (or python.org). Ubuntu: sudo apt install python3 python3-venv"
  fi
  info "Creating .venv with $("$python" --version 2>&1)"
  "$python" -m venv .venv
  .venv/bin/python -m pip install --quiet --disable-pip-version-check --upgrade pip
}

ensure_requirements() {  # reinstall only when requirements*.txt changed since the last run
  local stamp=.venv/.dev-requirements.cksum current
  if [[ $INSTALL_DEPS -eq 0 ]]; then
    return 0
  fi
  current=$(cat requirements.txt requirements-dev.txt | cksum)
  if [[ -f $stamp && $(cat "$stamp") == "$current" ]]; then
    return 0
  fi
  info "Installing requirements-dev.txt into .venv"
  .venv/bin/python -m pip install --quiet --disable-pip-version-check -r requirements-dev.txt
  printf '%s\n' "$current" >"$stamp"
}

env_value() {  # env_value KEY: value of KEY in .env (last line wins)
  awk -v key="$1" 'index($0, key "=") == 1 { value = substr($0, length(key) + 2) } END { print value }' .env
}

set_env_value() {  # set_env_value KEY VALUE: replace the KEY= line copied from .env.example
  local tmp
  tmp=$(mktemp .env.XXXXXX)
  awk -v key="$1" -v value="$2" 'index($0, key "=") == 1 { print key "=" value; next } { print }' .env >"$tmp"
  mv "$tmp" .env
}

ensure_env() {
  if [[ -f .env ]]; then
    info "Using the existing .env (SCOUT_PROCESSOR=$(env_value SCOUT_PROCESSOR))"
    return 0
  fi
  cp .env.example .env
  set_env_value SCOUT_PROCESSOR mock
  set_env_value SCOUT_AUTH_PASSWORD dev
  chmod 600 .env
  info "Created .env for development: SCOUT_PROCESSOR=mock (demo data, no GPU), password 'dev'"
}

start_processes() {
  local user
  user=$(env_value SCOUT_AUTH_USERNAME)
  .venv/bin/python -m uvicorn scout.main:app --reload --reload-dir scout --host "$HOST" --port "$PORT" &
  WEB_PID=$!
  .venv/bin/python -m scout.worker &
  WORKER_PID=$!
  info "Web app on http://$HOST:$PORT/ (sign in as ${user:-coach}; the password is SCOUT_AUTH_PASSWORD in .env)"
  info "The web app reloads when you edit scout/; restart this script after changing worker code."
  info "Ctrl-C stops both."
}

wait_for_exit() {  # returns when either process stops; EXIT_STATUS is its exit code
  while kill -0 "$WEB_PID" 2>/dev/null && kill -0 "$WORKER_PID" 2>/dev/null; do
    sleep 1
  done
  if ! kill -0 "$WEB_PID" 2>/dev/null; then
    wait "$WEB_PID" || EXIT_STATUS=$?
    printf 'dev.sh: the web app stopped (exit code %s)\n' "$EXIT_STATUS" >&2
  else
    wait "$WORKER_PID" || EXIT_STATUS=$?
    printf 'dev.sh: the worker stopped (exit code %s)\n' "$EXIT_STATUS" >&2
  fi
}

cleanup() {  # stop whichever process is still running
  local pid
  for pid in $WEB_PID $WORKER_PID; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true
  printf '\nStopped the web app and the worker.\n'
}

main() {
  parse_args "$@"
  cd "$ROOT_DIR"
  trap 'printf "dev.sh: failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
  ensure_venv
  ensure_requirements
  ensure_env
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  start_processes
  wait_for_exit
  exit "$EXIT_STATUS"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
