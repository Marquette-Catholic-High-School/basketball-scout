#!/usr/bin/env bash
# Install Basketball Scout on Ubuntu 24.04 LTS (Debian 12 works too).
#
#   sudo scripts/install.sh [options]                  from a clone of the repository
#   curl -fsSL https://raw.githubusercontent.com/Marquette-Catholic-High-School/basketball-scout/main/scripts/install.sh \
#     | sudo bash -s -- [options]                      or straight from GitHub
#
# Steps: check this machine, install system packages (git, Python, ffmpeg...), create
# the service user, clone the code into /opt/basketball-scout, build the Python
# environment, write .env (with a generated password), install and start the two
# systemd services (optionally behind nginx, optionally with Redis), wait until the web
# app answers and print the address and password.
#
# Safe to run again, e.g. to repair an install or to add --with-nginx later: it updates
# the code, never replaces an existing .env (it only adds settings that are missing and
# the values you pass as options) and restarts the services.
#
# Everything runs inside main(), called on the last line, so a half-downloaded script
# never runs and `curl ... | sudo bash` cannot feed the rest of the script to a command.

set -Eeuo pipefail

REPO_URL_DEFAULT="https://github.com/Marquette-Catholic-High-School/basketball-scout.git"
DEFAULT_DIR=/opt/basketball-scout
DEFAULT_DATA_DIR=/var/lib/basketball-scout
DEFAULT_USER=scout
DEFAULT_PORT=8000
WEB_UNIT=basketball-scout-web.service
WORKER_UNIT=basketball-scout-worker.service
SYSTEMD_DIR=/etc/systemd/system
NGINX_SITE_NAME=basketball-scout
USER_COMMENT="Basketball Scout service"
APT_PACKAGES="git ca-certificates curl python3 python3-venv python3-pip ffmpeg sqlite3"
MIN_FREE_GB_CODE=3
MIN_FREE_GB_DATA=10
RECOMMENDED_FREE_GB_DATA=50
HEALTH_TIMEOUT_S=90

# Options (see usage). Empty means "keep what an earlier install chose, else the default".
INSTALL_DIR=$DEFAULT_DIR
DATA_DIR=""
SERVICE_USER=""
BRANCH=main
REPO_URL=$REPO_URL_DEFAULT
REPO_GIVEN=0
PORT=""
WITH_REDIS=0
WITH_NGINX=0
DOMAIN=""
PROCESSOR=""
MODAL_ID=${MODAL_TOKEN_ID:-}
MODAL_SECRET=${MODAL_TOKEN_SECRET:-}
ANTHROPIC_KEY=${ANTHROPIC_API_KEY:-}
DEPLOY_MODAL=0
ASSUME_YES=0

# Worked out while the script runs.
ENV_FILE=""
SERVICE_GROUP=""
SERVICE_HOME=""
BIND_HOST=0.0.0.0
EFFECTIVE_PROCESSOR=modal
NEW_PASSWORD=""
ENV_BACKED_UP=0
MODAL_DEPLOY_RESULT=""
NEXT_STEP=0
STOCK_SITE_DISABLED=0

C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD="" C_OFF=""

usage() {
  cat <<EOF
Install Basketball Scout (web app + background worker) on Ubuntu 24.04 or Debian 12.

Usage: sudo scripts/install.sh [options]

Where things go:
  --dir DIR               code and Python environment (default: $DEFAULT_DIR)
  --data-dir DIR          games, film and database (default: $DEFAULT_DATA_DIR)
  --user NAME             system user that runs the services (default: $DEFAULT_USER)
  --repo URL              git repository to install from (default: the GitHub repository)
  --branch NAME           branch to install (default: main)
  --port N                port the web app listens on (default: $DEFAULT_PORT)

Optional parts:
  --with-nginx            nginx in front on port 80 (big uploads, video seeking, ready for HTTPS)
  --domain NAME           host name for nginx, e.g. scout.myschool.org (implies --with-nginx)
  --with-redis            install Redis and use it as the job queue (default: SQLite)
  --processor NAME        modal (default) | mock (demo data, no GPU) | local (this machine's GPU)

Keys (you can also set MODAL_TOKEN_ID, MODAL_TOKEN_SECRET and ANTHROPIC_API_KEY):
  --modal-token-id ID     Modal token ID (ak-...)
  --modal-token-secret S  Modal token secret (as-...)
  --anthropic-key KEY     Anthropic API key (sk-ant-...) for the Claude scouting report
  --deploy-modal          deploy the GPU app to Modal at the end (first time: 10-20 minutes)

  -y, --non-interactive   do not ask anything: answer yes and skip keys that are missing
  -h, --help              show this help

Examples:
  sudo scripts/install.sh
  sudo scripts/install.sh --with-nginx --domain scout.myschool.org --deploy-modal
  sudo scripts/install.sh --processor mock -y          # demo without a GPU

Keys typed on the command line end up in your shell history. Leave them out and the
installer asks for them (typing is hidden), or add them to $DEFAULT_DIR/.env later.
Running the installer again is safe: it keeps your settings, data and password.
EOF
}

# --- Output --------------------------------------------------------------------------

setup_colors() {
  if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    C_RED=$'\033[1;31m' C_GREEN=$'\033[1;32m' C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[1;34m' C_BOLD=$'\033[1m' C_OFF=$'\033[0m'
  fi
}

step() { printf '\n%s==> %s%s\n' "$C_BLUE" "$*" "$C_OFF"; }
info() { printf '    %s\n' "$*"; }
ok() { printf '    %s[ok]%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '    %s[warning]%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }

die() {
  printf '\n%s[error]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2
  exit 1
}

on_error() {  # ERR trap: say where the script stopped (the failing command printed why)
  local status=$1 line=$2 command=$3
  if [[ $BASH_SUBSHELL -gt 0 ]]; then
    return 0
  fi
  printf '\n%s[error]%s install.sh stopped at line %s (exit code %s) while running:\n    %s\n' \
    "$C_RED" "$C_OFF" "$line" "$status" "$command" >&2
  printf '    Fix the problem shown above, then run the same command again: re-running is safe.\n' >&2
}

# --- Questions -----------------------------------------------------------------------
# Answers are read from /dev/tty, so prompts work even with `curl ... | sudo bash`.

tty_available() { { : </dev/tty; } 2>/dev/null; }

can_ask() {  # true when we may ask questions (a terminal, and no -y)
  if [[ $ASSUME_YES -eq 0 ]] && tty_available; then
    return 0
  fi
  return 1
}

confirm() {  # confirm QUESTION DEFAULT(y|n): -y answers yes; without a terminal the default wins
  local question=$1 default=${2:-n} hint="[y/N]" answer=""
  if [[ $ASSUME_YES -eq 1 ]]; then
    return 0
  fi
  if [[ $default == y ]]; then
    hint="[Y/n]"
  fi
  if tty_available; then
    printf '    %s %s ' "$question" "$hint" >/dev/tty
    IFS= read -r answer </dev/tty || answer=""
  fi
  case $answer in
    [Yy] | [Yy][Ee][Ss]) return 0 ;;
    [Nn] | [Nn][Oo]) return 1 ;;
  esac
  if [[ $default == y ]]; then
    return 0
  fi
  return 1
}

ask() {  # ask PROMPT [secret]: one line from the terminal (hidden when "secret"), trimmed
  local answer=""
  printf '    %s' "$1" >/dev/tty
  if [[ ${2:-} == secret ]]; then
    read -r -s answer </dev/tty || answer=""
    printf '\n' >/dev/tty
  else
    read -r answer </dev/tty || answer=""
  fi
  printf '%s' "$answer"
}

# --- Validation ------------------------------------------------------------------------

need_value() {  # need_value OPTION [VALUE]: the option got a value
  if [[ $# -lt 2 || -z $2 || $2 == --* ]]; then
    die "$1 needs a value (see --help)"
  fi
}

valid_path() {  # absolute, no spaces or shell characters, no "." or ".." parts, not "/"
  local path_re='^/[A-Za-z0-9._/-]+$' dots_re='(^|/)\.\.?(/|$)'
  [[ $1 =~ $path_re && ! $1 =~ $dots_re ]]
}

valid_user() {
  local user_re='^[a-z_][a-z0-9_-]{0,31}$'
  [[ $1 =~ $user_re ]]
}

valid_port() {
  local port_re='^[0-9]{1,5}$'
  [[ $1 =~ $port_re ]] && ((10#$1 >= 1024 && 10#$1 <= 65535))
}

valid_branch() {
  local branch_re='^[A-Za-z0-9._/][A-Za-z0-9._/-]*$'
  [[ $1 =~ $branch_re ]]
}

valid_domain() {
  local label='[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?'
  local domain_re="^${label}(\.${label})*$"
  [[ $1 =~ $domain_re ]]
}

valid_secret() {  # API keys and tokens: letters, digits, "-", "_" and "."
  local secret_re='^[A-Za-z0-9._-]+$'
  [[ $1 =~ $secret_re ]]
}

strip_trailing_slashes() {
  local path=$1
  while [[ $path == */ && $path != / ]]; do
    path=${path%/}
  done
  printf '%s' "$path"
}

paths_overlap() {  # true when one path is the other or lies inside it
  [[ $1 == "$2" || $1 == "$2"/* || $2 == "$1"/* ]]
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    if [[ $1 == --*=* ]]; then
      set -- "${1%%=*}" "${1#*=}" "${@:2}"
    fi
    case $1 in
      -h | --help)
        usage
        exit 0
        ;;
      --dir) need_value "$@"; INSTALL_DIR=$2; shift ;;
      --data-dir) need_value "$@"; DATA_DIR=$2; shift ;;
      --user) need_value "$@"; SERVICE_USER=$2; shift ;;
      --branch) need_value "$@"; BRANCH=$2; shift ;;
      --repo) need_value "$@"; REPO_URL=$2; REPO_GIVEN=1; shift ;;
      --port) need_value "$@"; PORT=$2; shift ;;
      --with-redis) WITH_REDIS=1 ;;
      --with-nginx) WITH_NGINX=1 ;;
      --domain) need_value "$@"; DOMAIN=$2; WITH_NGINX=1; shift ;;
      --processor) need_value "$@"; PROCESSOR=$2; shift ;;
      --modal-token-id) need_value "$@"; MODAL_ID=$2; shift ;;
      --modal-token-secret) need_value "$@"; MODAL_SECRET=$2; shift ;;
      --anthropic-key) need_value "$@"; ANTHROPIC_KEY=$2; shift ;;
      --deploy-modal) DEPLOY_MODAL=1 ;;
      -y | --yes | --non-interactive) ASSUME_YES=1 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done
}

validate_args() {
  INSTALL_DIR=$(strip_trailing_slashes "$INSTALL_DIR")
  if ! valid_path "$INSTALL_DIR"; then
    die "--dir must be an absolute path made of letters, digits, '.', '_', '-' and '/' (got '$INSTALL_DIR')."
  fi
  if [[ -n $DATA_DIR ]]; then
    DATA_DIR=$(strip_trailing_slashes "$DATA_DIR")
    if ! valid_path "$DATA_DIR"; then
      die "--data-dir must be an absolute path made of letters, digits, '.', '_', '-' and '/' (got '$DATA_DIR')."
    fi
  fi
  if [[ -n $SERVICE_USER ]] && ! valid_user "$SERVICE_USER"; then
    die "--user must be a lowercase Linux user name such as 'scout' (got '$SERVICE_USER')."
  fi
  if [[ -n $PORT ]] && ! valid_port "$PORT"; then
    die "--port must be a number from 1024 to 65535 (got '$PORT'). For port 80/443 use --with-nginx."
  fi
  if ! valid_branch "$BRANCH"; then
    die "--branch '$BRANCH' is not a valid branch name."
  fi
  if [[ -n $DOMAIN ]] && ! valid_domain "$DOMAIN"; then
    die "--domain must be a host name such as scout.myschool.org (got '$DOMAIN')."
  fi
  case ${PROCESSOR:-modal} in
    modal | mock | local) ;;
    *) die "--processor must be modal, mock or local (got '$PROCESSOR')." ;;
  esac
  if [[ $REPO_URL == -* ]]; then
    die "--repo must be a git URL or a path (got '$REPO_URL')."
  fi
  validate_keys
}

validate_keys() {
  check_secret "Modal token ID" "$MODAL_ID" ak-
  check_secret "Modal token secret" "$MODAL_SECRET" as-
  check_secret "Anthropic API key" "$ANTHROPIC_KEY" sk-ant-
  if [[ -n $MODAL_ID && -z $MODAL_SECRET ]] || [[ -z $MODAL_ID && -n $MODAL_SECRET ]]; then
    die "Give both the Modal token ID and the token secret (or neither)."
  fi
}

check_secret() {  # check_secret LABEL VALUE EXPECTED_PREFIX
  if [[ -z $2 ]]; then
    return 0
  fi
  if ! valid_secret "$2"; then
    die "The $1 contains unexpected characters (spaces or quotes?). Copy it again."
  fi
  if [[ $2 != "$3"* ]]; then
    warn "The $1 does not start with '$3'; check that you copied the right value."
  fi
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "This installer needs root. Run it with sudo, e.g.: sudo scripts/install.sh"
  fi
}

# --- .env helpers ------------------------------------------------------------------------
# .env is read by python-dotenv (the app) and by systemd (EnvironmentFile=), so these
# helpers only ever write plain KEY=value lines.

env_get() {  # env_get FILE KEY: value of the last active KEY= line, quotes removed
  if [[ ! -f $1 ]]; then
    return 0
  fi
  awk -v key="$2" -v q="'" '
    { sub(/\r$/, "") }
    $0 ~ ("^[[:space:]]*" key "=") {
      value = substr($0, index($0, "=") + 1)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      first = substr(value, 1, 1)
      if (length(value) >= 2 && (first == "\"" || first == q) && substr(value, length(value), 1) == first)
        value = substr(value, 2, length(value) - 2)
      found = value
      seen = 1
    }
    END { if (seen) print found }
  ' "$1"
}

env_has_key() {  # env_has_key FILE KEY: KEY appears, active or commented out
  grep -Eq "^[[:space:]]*#?[[:space:]]*$2=" "$1"
}

env_set() {  # env_set FILE KEY VALUE: replace the active line (dropping duplicates), else
  # uncomment the first "# KEY=" line, else append. Keeps the file's owner and mode.
  local file=$1 key=$2 tmp
  tmp=$(mktemp "$file.XXXXXX")
  ENV_SET_VALUE=$3 awk -v key="$key" '
    function active(line) { return line ~ ("^[[:space:]]*" key "=") }
    function commented(line) { return line ~ ("^[[:space:]]*#[[:space:]]*" key "=") }
    NR == FNR { if (active($0)) n_active++; else if (!first_comment && commented($0)) first_comment = FNR; next }
    active($0) { if (!done) print key "=" ENVIRON["ENV_SET_VALUE"]; done = 1; next }
    !n_active && FNR == first_comment { print key "=" ENVIRON["ENV_SET_VALUE"]; done = 1; next }
    { print }
    END { if (!done) print key "=" ENVIRON["ENV_SET_VALUE"] }
  ' "$file" "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

env_missing_lines() {  # env_missing_lines EXAMPLE FILE: setting lines of EXAMPLE whose key FILE lacks
  local line key key_re='^[[:space:]]*#?[[:space:]]*([A-Z][A-Z0-9_]*)='
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ $key_re ]]; then
      key=${BASH_REMATCH[1]}
      if ! env_has_key "$2" "$key"; then
        printf '%s\n' "$line"
      fi
    fi
  done <"$1"
}

env_append_missing() {  # env_append_missing EXAMPLE FILE: add settings FILE lacks; prints how many
  local missing
  missing=$(env_missing_lines "$1" "$2")
  if [[ -z $missing ]]; then
    echo 0
    return 0
  fi
  if [[ -s $2 && $(tail -c 1 "$2" | wc -l) -eq 0 ]]; then
    printf '\n' >>"$2"
  fi
  {
    printf '\n# --- Added by scripts/install.sh on %s: new settings (see .env.example) ---\n' "$(date +%Y-%m-%d)"
    printf '%s\n' "$missing"
  } >>"$2"
  printf '%s\n' "$missing" | grep -c .
}

render_template() {  # render_template SRC DEST KEY=VALUE...: replace each @KEY@ in SRC
  local src=$1 dest=$2 content pair key value leftover
  shift 2
  content=$(cat "$src")
  for pair in "$@"; do
    key=${pair%%=*}
    value=${pair#*=}
    content=${content//@${key}@/"$value"}
  done
  leftover=$(printf '%s\n' "$content" | grep -o '@[A-Z_][A-Z_]*@' | head -n 1 || true)
  if [[ -n $leftover ]]; then
    die "$src contains the placeholder $leftover, which install.sh does not know."
  fi
  printf '%s\n' "$content" >"$dest"
}

# --- Small system helpers ---------------------------------------------------------------

as_user() {  # run a command as the service user, from the install folder (which must exist)
  # env -C instead of a ( cd ...; ) subshell, so a failure still reaches the ERR trap.
  runuser -u "$SERVICE_USER" -- env -C "$INSTALL_DIR" HOME="$SERVICE_HOME" GIT_TERMINAL_PROMPT=0 "$@"
}

record_state() {  # record_state running|modal: remember the live commit (scripts/update.sh reads it)
  local file="$INSTALL_DIR/.git/basketball-scout-$1"
  as_user git -C "$INSTALL_DIR" rev-parse HEAD >"$file"
  chown "$SERVICE_USER:$SERVICE_GROUP" "$file"
}

as_user_with_env() {  # same, with .env loaded the way the app loads it (python-dotenv)
  as_user "$INSTALL_DIR/.venv/bin/python" -m dotenv -f "$ENV_FILE" run -- "$@"
}

user_home() {
  if id -u "$1" >/dev/null 2>&1; then
    getent passwd "$1" | cut -d: -f6
  fi
}

installed_unit_value() {  # value of KEY= in the installed web unit (empty when not installed)
  if [[ -f $SYSTEMD_DIR/$WEB_UNIT ]]; then
    awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$SYSTEMD_DIR/$WEB_UNIT"
  fi
}

nginx_site_file() {
  if [[ -d /etc/nginx/sites-available ]]; then
    printf '%s' "/etc/nginx/sites-available/$NGINX_SITE_NAME"
  else
    printf '%s' "/etc/nginx/conf.d/$NGINX_SITE_NAME.conf"
  fi
}

existing_nginx_domain() {  # server_name of an installed site ("" for the catch-all "_")
  awk '$1 == "server_name" { sub(/;.*/, "", $2); if ($2 != "_") print $2; exit }' "$(nginx_site_file)"
}

redact_url() {  # hide a token in https://TOKEN@github.com/... URLs
  printf '%s' "$1" | sed -E 's#(://)[^/@]+@#\1***@#'
}

existing_parent() {
  local path=$1
  while [[ ! -e $path ]]; do
    path=$(dirname "$path")
  done
  printf '%s' "$path"
}

os_release_value() {
  sed -n "s/^$1=//p" /etc/os-release | tr -d '"'
}

is_true() {  # pydantic-style booleans
  case $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') in
    true | 1 | yes | on | y | t) return 0 ;;
  esac
  return 1
}

generate_password() {  # 4 groups of 5 easy-to-type characters (about 99 bits)
  python3 - <<'PY'
import secrets
alphabet = "abcdefghjkmnpqrstuvwxyz23456789"
print("-".join("".join(secrets.choice(alphabet) for _ in range(5)) for _ in range(4)))
PY
}

modal_credentials_present() {  # a Modal token in .env, typed in this run, or in ~/.modal.toml
  if [[ -n $MODAL_ID && -n $MODAL_SECRET ]]; then
    return 0
  fi
  if [[ -n $(env_get "$ENV_FILE" MODAL_TOKEN_ID) && -n $(env_get "$ENV_FILE" MODAL_TOKEN_SECRET) ]]; then
    return 0
  fi
  if [[ -n $SERVICE_HOME && -f $SERVICE_HOME/.modal.toml ]]; then
    return 0
  fi
  return 1
}

# --- Steps ------------------------------------------------------------------------------

resolve_settings() {  # fill in options left empty from an earlier install, else defaults
  ENV_FILE="$INSTALL_DIR/.env"
  if [[ -z $SERVICE_USER ]]; then
    SERVICE_USER=$(installed_unit_value User)
    SERVICE_USER=${SERVICE_USER:-$DEFAULT_USER}
  fi
  SERVICE_HOME=$(user_home "$SERVICE_USER")
  SERVICE_HOME=${SERVICE_HOME:-/home/$SERVICE_USER}
  resolve_data_dir
  if [[ -z $PORT ]]; then
    PORT=$(env_get "$ENV_FILE" SCOUT_PORT)
    if [[ -n $PORT ]] && ! valid_port "$PORT"; then
      warn "SCOUT_PORT=$PORT in $ENV_FILE is not usable; using $DEFAULT_PORT."
      PORT=""
    fi
    PORT=${PORT:-$DEFAULT_PORT}
  fi
  if [[ -f $(nginx_site_file) ]]; then
    WITH_NGINX=1
    if [[ -z $DOMAIN ]]; then
      DOMAIN=$(existing_nginx_domain)
    fi
  fi
  if [[ $(env_get "$ENV_FILE" SCOUT_QUEUE_BACKEND) == redis ]]; then
    WITH_REDIS=1
  fi
  if [[ $WITH_NGINX -eq 1 ]]; then
    BIND_HOST=127.0.0.1
  fi
  EFFECTIVE_PROCESSOR=${PROCESSOR:-$(env_get "$ENV_FILE" SCOUT_PROCESSOR)}
  EFFECTIVE_PROCESSOR=${EFFECTIVE_PROCESSOR:-modal}
}

resolve_data_dir() {
  local current relative
  current=$(env_get "$ENV_FILE" SCOUT_DATA_DIR)
  current=$(strip_trailing_slashes "$current")
  relative=${current#./}
  if [[ -f $ENV_FILE && $current != /* && -e $INSTALL_DIR/${relative:-data}/scout.db ]]; then
    # The app reads a relative (or unset, i.e. "data") SCOUT_DATA_DIR from the code folder and
    # its games are there: never switch away from them silently.
    current="$INSTALL_DIR/${relative:-data}"
  fi
  if [[ -z $DATA_DIR ]]; then
    if [[ $current == /* ]]; then
      DATA_DIR=$current
      if ! valid_path "$DATA_DIR"; then
        die "SCOUT_DATA_DIR in $ENV_FILE ('$DATA_DIR') must be an absolute path without spaces. Fix it or pass --data-dir."
      fi
    else
      DATA_DIR=$DEFAULT_DATA_DIR
    fi
  elif [[ $current == /* && $current != "$DATA_DIR" && -e $current/scout.db ]]; then
    warn "$ENV_FILE uses the data folder $current, which holds a database."
    warn "Switching to $DATA_DIR does NOT move the games there (copy them first, see docs/DEPLOYMENT.md)."
    confirm "Use the new data folder $DATA_DIR anyway?" n || die "Nothing was changed. Leave out --data-dir to keep $current."
  fi
  if paths_overlap "$INSTALL_DIR" "$DATA_DIR"; then
    die "Keep the data folder ($DATA_DIR) outside the code folder ($INSTALL_DIR), so updates and uninstalls never touch your games. To move existing games out first, see docs/DEPLOYMENT.md > Moving the data folder."
  fi
}

preflight() {
  step "Checking this machine"
  check_os
  if [[ ! -d /run/systemd/system ]]; then
    die "systemd is not running here. Use a VM or a full Ubuntu install (see docs/PROXMOX.md)."
  fi
  check_disk "$(existing_parent "$INSTALL_DIR")" "$MIN_FREE_GB_CODE" 0 "the code folder"
  check_disk "$(existing_parent "$DATA_DIR")" "$MIN_FREE_GB_DATA" "$RECOMMENDED_FREE_GB_DATA" "the data folder"
  check_internet
  if command -v python3 >/dev/null 2>&1; then
    check_python_version
  fi
}

check_os() {
  local os_id os_like os_version os_name
  if [[ $(uname -s) != Linux ]]; then
    die "This installer is for Ubuntu/Debian servers. On a Mac or for development use scripts/dev.sh."
  fi
  if [[ ! -r /etc/os-release ]]; then
    die "Cannot read /etc/os-release, so this does not look like Ubuntu or Debian."
  fi
  os_id=$(os_release_value ID)
  os_like=$(os_release_value ID_LIKE)
  os_version=$(os_release_value VERSION_ID)
  os_name=$(os_release_value PRETTY_NAME)
  case $os_id in
    ubuntu)
      if [[ $os_version != 24.04 ]]; then
        warn "Tested on Ubuntu 24.04 LTS; this is $os_name."
      fi
      ;;
    debian)
      if [[ ! $os_version =~ ^1[2-9] ]]; then
        warn "Tested on Debian 12; this is $os_name."
      fi
      ;;
    *)
      if [[ $os_like == *debian* || $os_like == *ubuntu* ]]; then
        warn "$os_name is not tested; continuing because it is Debian-based."
      else
        die "$os_name is not supported. Use Ubuntu 24.04 LTS (or Debian 12)."
      fi
      ;;
  esac
  if ! command -v apt-get >/dev/null 2>&1; then
    die "apt-get was not found; this installer needs Ubuntu or Debian."
  fi
  ok "$os_name"
}

check_disk() {  # check_disk PATH MIN_GB RECOMMENDED_GB WHAT
  local free_kb free_gb
  free_kb=$(df -Pk "$1" | awk 'NR == 2 { print $4 }')
  free_gb=$((free_kb / 1024 / 1024))
  if ((free_gb < $2)); then
    die "Only ${free_gb} GB is free on $1 for $4; at least $2 GB is needed."
  fi
  if (($3 > 0 && free_gb < $3)); then
    warn "${free_gb} GB free for $4. Each game needs about 3-8 GB (film plus annotated video), so plan for more."
  else
    ok "${free_gb} GB free for $4 ($1)"
  fi
}

can_reach() {  # can_reach HOST: HTTPS to HOST works (curl honours https_proxy)
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 15 -o /dev/null "https://$1/" 2>/dev/null
  else
    timeout 15 bash -c "exec 3<>/dev/tcp/$1/443" 2>/dev/null
  fi
}

check_internet() {
  local host unreachable=""
  for host in github.com pypi.org; do
    if ! can_reach "$host"; then
      unreachable="$unreachable $host"
    fi
  done
  if [[ -z $unreachable ]]; then
    ok "Internet access to GitHub and PyPI"
    return 0
  fi
  warn "Cannot reach:$unreachable. The install downloads code and Python packages from there."
  warn "Behind a proxy? Run: sudo https_proxy=http://proxy:port http_proxy=http://proxy:port scripts/install.sh"
  confirm "Continue anyway?" n || die "Stopped: no internet access."
}

check_python_version() {
  if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'; then
    die "Python $(python3 -c 'import platform; print(platform.python_version())') is too old: Basketball Scout needs 3.11 or newer (Ubuntu 24.04 has 3.12, Debian 12 has 3.11)."
  fi
}

show_plan() {
  local web queue=sqlite
  if [[ $WITH_NGINX -eq 1 ]]; then
    web="nginx on port 80 (${DOMAIN:-any host name}) -> app on 127.0.0.1:$PORT"
  else
    web="app on port $PORT, all network interfaces (plain http)"
  fi
  if [[ $WITH_REDIS -eq 1 ]]; then
    queue="redis (local redis-server)"
  fi
  step "Basketball Scout will be installed like this"
  info "Code + Python env  $INSTALL_DIR  (from $(redact_url "$REPO_URL"), branch $BRANCH)"
  info "Games, film, DB    $DATA_DIR"
  info "Service user       $SERVICE_USER"
  info "Web address        $web"
  info "Job queue          $queue"
  info "Film processing    $EFFECTIVE_PROCESSOR"
  if [[ -f $ENV_FILE ]]; then
    info "Settings           keeping $ENV_FILE (only missing settings and your options are added)"
  fi
}

ask_for_missing_keys() {
  if ! can_ask; then
    return 0
  fi
  if [[ -z $ANTHROPIC_KEY && -z $(env_get "$ENV_FILE" ANTHROPIC_API_KEY) ]]; then
    step "Claude scouting report"
    info "The written report needs an Anthropic API key (console.anthropic.com > API Keys)."
    ANTHROPIC_KEY=$(ask "Paste the key (input hidden), or press Enter to skip: " secret)
  fi
  if [[ $EFFECTIVE_PROCESSOR == modal ]] && ! modal_credentials_present; then
    step "Modal (serverless GPU)"
    info "Film is analysed on Modal's GPUs. Create a token in the Modal dashboard (Settings > API Tokens)."
    MODAL_ID=$(ask "Token ID (ak-...), or press Enter to skip: ")
    if [[ -n $MODAL_ID ]]; then
      MODAL_SECRET=$(ask "Token secret (as-..., input hidden): " secret)
    fi
    if [[ -z $MODAL_SECRET ]]; then
      MODAL_ID=""
    fi
  fi
  validate_keys
  if [[ $DEPLOY_MODAL -eq 0 && $EFFECTIVE_PROCESSOR == modal ]] && modal_credentials_present; then
    if confirm "Deploy the GPU app to Modal at the end (first time about 10-20 minutes)?" n; then
      DEPLOY_MODAL=1
    fi
  fi
}

install_packages() {
  local packages=$APT_PACKAGES pkg status missing=""
  if [[ $WITH_REDIS -eq 1 ]]; then
    packages="$packages redis-server"
  fi
  if [[ $WITH_NGINX -eq 1 ]]; then
    packages="$packages nginx"
  fi
  step "System packages"
  for pkg in $packages; do
    status=$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)
    if [[ $status != *"ok installed"* ]]; then
      missing="$missing $pkg"
    fi
  done
  if [[ -z $missing ]]; then
    # shellcheck disable=SC2086  # $packages is a space-separated list, split on purpose
    ok "Already installed:$(printf ' %s' $packages)"
    return 0
  fi
  info "Installing:$missing"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  # shellcheck disable=SC2086 # word splitting of the package list is intended
  apt-get install -y -q --no-install-recommends $missing
  ok "Packages installed"
}

check_python() {
  check_python_version
  if ! python3 -c 'import ensurepip, venv' 2>/dev/null; then
    die "Python's venv module is missing. Install it with: sudo apt-get install python3-venv"
  fi
  ok "Python $(python3 -c 'import platform; print(platform.python_version())')"
}

ensure_service_user() {
  step "Service user"
  if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    ok "User $SERVICE_USER exists"
  else
    local group_option="--user-group"
    if getent group "$SERVICE_USER" >/dev/null 2>&1; then
      group_option="--gid=$SERVICE_USER"
    fi
    useradd --system --create-home --home-dir "/home/$SERVICE_USER" --shell /usr/sbin/nologin \
      "$group_option" --comment "$USER_COMMENT" "$SERVICE_USER"
    ok "Created system user $SERVICE_USER (no login shell)"
  fi
  SERVICE_GROUP=$(id -gn "$SERVICE_USER")
  SERVICE_HOME=$(user_home "$SERVICE_USER")
  if [[ $SERVICE_HOME != /?* || $SERVICE_HOME == / ]]; then
    die "User $SERVICE_USER has no usable home folder ('$SERVICE_HOME'). Use --user with a dedicated user."
  fi
  if [[ ! -d $SERVICE_HOME ]]; then
    die "The home folder $SERVICE_HOME of user $SERVICE_USER does not exist. Create it or use another --user."
  fi
}

install_code() {
  step "Code ($INSTALL_DIR)"
  if [[ -d $INSTALL_DIR/.git ]]; then
    update_checkout
  else
    if [[ -e $INSTALL_DIR && -n $(ls -A "$INSTALL_DIR" 2>/dev/null) ]]; then
      die "$INSTALL_DIR exists, is not empty and is not a git checkout. Move it away or choose another --dir."
    fi
    install -d -m 755 "$INSTALL_DIR"
    chown "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"
    info "Cloning $(redact_url "$REPO_URL") (branch $BRANCH)"
    if ! as_user git clone --quiet --branch "$BRANCH" -- "$REPO_URL" "$INSTALL_DIR"; then
      die "git clone failed. Check the URL and branch. A private repository needs a deploy key or a token in --repo."
    fi
  fi
  ok "Version $(as_user git -C "$INSTALL_DIR" log -1 --format='%h %s (%cs)')"
}

update_checkout() {
  local origin current
  # A checkout cloned by root must belong to the service user, which runs all git commands.
  chown -hR "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"
  origin=$(as_user git -C "$INSTALL_DIR" remote get-url origin 2>/dev/null || true)
  if [[ $REPO_GIVEN -eq 1 && $origin != "$REPO_URL" ]]; then
    warn "$INSTALL_DIR already tracks $(redact_url "$origin"); --repo is ignored for an existing checkout."
  fi
  info "Fetching updates"
  if ! as_user git -C "$INSTALL_DIR" fetch --quiet --prune origin; then
    die "git fetch failed. Check the internet connection (and credentials for a private repository)."
  fi
  current=$(as_user git -C "$INSTALL_DIR" rev-parse --abbrev-ref HEAD)
  if [[ $current != "$BRANCH" ]]; then
    info "Switching from branch $current to $BRANCH"
    if as_user git -C "$INSTALL_DIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
      as_user git -C "$INSTALL_DIR" checkout --quiet "$BRANCH"
    else
      as_user git -C "$INSTALL_DIR" checkout --quiet -b "$BRANCH" --track "origin/$BRANCH"
    fi
  fi
  if ! as_user git -C "$INSTALL_DIR" merge --quiet --ff-only "origin/$BRANCH"; then
    die "Could not fast-forward $INSTALL_DIR to origin/$BRANCH (local changes?). See: sudo -u $SERVICE_USER git -C $INSTALL_DIR status. scripts/update.sh --force saves local changes and updates."
  fi
}

install_python_env() {
  local venv="$INSTALL_DIR/.venv"
  step "Python environment ($venv)"
  if [[ -e $venv ]] && ! as_user "$venv/bin/python" -c 'import sys' >/dev/null 2>&1; then
    warn "The existing environment does not work (was Python upgraded?); building a new one."
    rm -rf "$venv"
  fi
  if [[ ! -e $venv ]]; then
    as_user python3 -m venv "$venv"
    as_user "$venv/bin/python" -m pip install --quiet --disable-pip-version-check --upgrade pip wheel
    ok "Created $venv"
  fi
  info "Installing Python packages from requirements.txt (a few minutes the first time)"
  as_user "$venv/bin/python" -m pip install --quiet --disable-pip-version-check -r "$INSTALL_DIR/requirements.txt"
  ok "Python packages installed"
}

ensure_data_dir() {
  step "Data folder ($DATA_DIR)"
  install -d -m 750 "$DATA_DIR"
  chown "$SERVICE_USER:$SERVICE_GROUP" "$DATA_DIR"
  chmod 750 "$DATA_DIR"
  # Files restored from a backup or left by an earlier install may belong to another user.
  if [[ -n $(find "$DATA_DIR" -xdev ! -user "$SERVICE_USER" -print -quit 2>/dev/null) ]]; then
    chown -hR "$SERVICE_USER:$SERVICE_GROUP" "$DATA_DIR"
    info "Gave the existing files to $SERVICE_USER"
  fi
  ok "Owned by $SERVICE_USER, private to the service (mode 750)"
}

latest_env_backup() {  # newest .env saved by uninstall.sh in the data folder (names sort by date)
  local file latest=""
  for file in "$DATA_DIR"/backups/env-*; do
    if [[ -f $file ]]; then
      latest=$file
    fi
  done
  printf '%s' "$latest"
}

backup_env_once() {
  if [[ $ENV_BACKED_UP -eq 0 ]]; then
    local backup
    backup="$ENV_FILE.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$ENV_FILE" "$backup"
    chmod 600 "$backup"
    info "Saved a copy of the current settings as $backup"
    ENV_BACKED_UP=1
  fi
}

env_update() {  # env_update KEY VALUE [secret]: set KEY in .env when it differs
  local shown=$2
  if [[ $(env_get "$ENV_FILE" "$1") == "$2" ]]; then
    return 0
  fi
  if [[ ${3:-} == secret ]]; then
    shown="(hidden)"
  fi
  backup_env_once
  env_set "$ENV_FILE" "$1" "$2"
  ok "$1=$shown"
}

configure_env() {
  local backup added
  step "Settings ($ENV_FILE)"
  if [[ ! -f $ENV_FILE ]]; then
    backup=$(latest_env_backup)
    if [[ -n $backup ]]; then
      cp "$backup" "$ENV_FILE"
      ok "Restored the settings saved by uninstall.sh ($backup)"
    else
      cp "$INSTALL_DIR/.env.example" "$ENV_FILE"
      ok "Created from .env.example"
    fi
    ENV_BACKED_UP=1
  fi
  chown "$SERVICE_USER:$SERVICE_GROUP" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  if [[ -n $(env_missing_lines "$INSTALL_DIR/.env.example" "$ENV_FILE") ]]; then
    backup_env_once
    added=$(env_append_missing "$INSTALL_DIR/.env.example" "$ENV_FILE")
    ok "Added $added new setting(s) from .env.example with their defaults"
  fi
  env_update SCOUT_DATA_DIR "$DATA_DIR"
  env_update SCOUT_HOST "$BIND_HOST"
  env_update SCOUT_PORT "$PORT"
  if [[ -n $PROCESSOR ]]; then
    env_update SCOUT_PROCESSOR "$PROCESSOR"
  fi
  if [[ $WITH_REDIS -eq 1 ]]; then
    env_update SCOUT_QUEUE_BACKEND redis
  fi
  if [[ -n $ANTHROPIC_KEY ]]; then
    env_update ANTHROPIC_API_KEY "$ANTHROPIC_KEY" secret
  fi
  if [[ -n $MODAL_ID ]]; then
    env_update MODAL_TOKEN_ID "$MODAL_ID" secret
    env_update MODAL_TOKEN_SECRET "$MODAL_SECRET" secret
  fi
  ensure_password
  chown "$SERVICE_USER:$SERVICE_GROUP" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "Readable only by $SERVICE_USER and root (mode 600)"
}

ensure_password() {
  if is_true "$(env_get "$ENV_FILE" SCOUT_AUTH_DISABLED)"; then
    warn "Sign-in is switched off (SCOUT_AUTH_DISABLED=true): anyone who can reach the server sees every game."
    return 0
  fi
  if [[ -n $(env_get "$ENV_FILE" SCOUT_AUTH_PASSWORD) || -n $(env_get "$ENV_FILE" SCOUT_AUTH_PASSWORD_HASH) ]]; then
    ok "Sign-in password already set (kept)"
    return 0
  fi
  NEW_PASSWORD=$(generate_password)
  backup_env_once
  env_set "$ENV_FILE" SCOUT_AUTH_PASSWORD "$NEW_PASSWORD"
  ok "Generated a sign-in password (shown at the end)"
}

install_gpu_packages() {  # only for SCOUT_PROCESSOR=local
  local requirements="$INSTALL_DIR/modal_app/requirements-gpu.txt" ohv_home
  if [[ $EFFECTIVE_PROCESSOR != local ]]; then
    return 0
  fi
  step "Local GPU pipeline (SCOUT_PROCESSOR=local)"
  if command -v nvidia-smi >/dev/null 2>&1; then
    # The sandboxed worker cannot load kernel modules, so CUDA's nvidia_uvm loads at boot.
    printf 'nvidia\nnvidia_uvm\n' >/etc/modules-load.d/basketball-scout-nvidia.conf
    modprobe nvidia_uvm 2>/dev/null || warn "Could not load nvidia_uvm now; it loads at the next boot."
  else
    warn "nvidia-smi was not found: the local processor needs an NVIDIA GPU and its driver (docs/PROXMOX.md > GPU passthrough)."
  fi
  if [[ ! -f $requirements ]]; then
    warn "$requirements is missing; skipping the GPU packages."
    return 0
  fi
  ohv_home=$(env_get "$ENV_FILE" OHV_HOME)
  ohv_home=${ohv_home:-/opt/openhoopvision}
  if ! valid_path "$ohv_home"; then
    die "OHV_HOME in $ENV_FILE ('$ohv_home') must be an absolute path without spaces."
  fi
  # The folder is given to the service user (and uninstall.sh deletes it): never a shared one like /opt.
  if [[ -e $ohv_home && ! -d $ohv_home/.git && -n $(ls -A "$ohv_home" 2>/dev/null) ]]; then
    die "OHV_HOME in $ENV_FILE ('$ohv_home') already holds other files. Use a folder of its own, such as /opt/openhoopvision."
  fi
  install_opencv_libraries
  info "Installing the GPU packages (several GB, this takes a while)"
  as_user "$INSTALL_DIR/.venv/bin/python" -m pip install --quiet --disable-pip-version-check -r "$requirements"
  install -d -m 755 "$ohv_home"
  chown "$SERVICE_USER:$SERVICE_GROUP" "$ohv_home"
  info "Installing OpenHoopVision and its model weights into $ohv_home"
  as_user "$INSTALL_DIR/.venv/bin/python" -m modal_app.pipeline.ohv install --home "$ohv_home"
  ok "Local GPU pipeline installed"
}

install_opencv_libraries() {  # OpenCV's cv2 (opencv-python, the GUI build OHV pins) needs libGL.so.1 and glib
  local glib=libglib2.0-0t64  # Ubuntu 24.04 and Debian 13; Debian 12 still calls it libglib2.0-0
  info "Installing the libraries OpenCV needs (libgl1, glib)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  if ! apt-cache show "$glib" >/dev/null 2>&1; then
    glib=libglib2.0-0
  fi
  apt-get install -y -q --no-install-recommends libgl1 "$glib"
}

install_services() {
  local unit
  step "Services (systemd)"
  if [[ $WITH_REDIS -eq 1 ]]; then
    systemctl enable --now --quiet redis-server
    ok "Redis is running"
  fi
  for unit in "$WEB_UNIT" "$WORKER_UNIT"; do
    render_template "$INSTALL_DIR/deploy/systemd/$unit" "$SYSTEMD_DIR/$unit" \
      "USER=$SERVICE_USER" "GROUP=$SERVICE_GROUP" "DIR=$INSTALL_DIR" "HOST=$BIND_HOST" \
      "PORT=$PORT" "DATA_DIR=$DATA_DIR" "HOME=$SERVICE_HOME"
    chmod 644 "$SYSTEMD_DIR/$unit"
  done
  if [[ $WITH_REDIS -eq 1 ]]; then
    write_redis_dropins
  fi
  systemctl daemon-reload
  systemctl enable --quiet "$WEB_UNIT" "$WORKER_UNIT"
  systemctl restart "$WEB_UNIT" "$WORKER_UNIT"
  ok "Installed and (re)started $WEB_UNIT and $WORKER_UNIT"
}

write_redis_dropins() {  # web (enqueues jobs) and worker (claims them) both need Redis
  local unit
  for unit in "$WEB_UNIT" "$WORKER_UNIT"; do
    install -d -m 755 "$SYSTEMD_DIR/$unit.d"
    cat >"$SYSTEMD_DIR/$unit.d/10-redis.conf" <<'EOF'
# Written by scripts/install.sh --with-redis: start after the local Redis server
# (SCOUT_QUEUE_BACKEND=redis). Delete this file if Redis runs on another machine.
[Unit]
After=redis-server.service
Wants=redis-server.service
EOF
  done
}

configure_nginx() {
  local site enabled previous="" server_name="_" default_server=""
  step "nginx"
  site=$(nginx_site_file)
  if [[ -f $site ]] && grep -q "Certbot" "$site"; then
    warn "$site was changed by certbot (HTTPS); leaving it as it is."
    if ! grep -q "127.0.0.1:$PORT" "$site"; then
      warn "Its proxy_pass does not point at port $PORT; edit $site by hand."
    fi
  else
    if [[ -n $DOMAIN ]]; then
      server_name=$DOMAIN
    else
      default_server=" default_server"
      disable_stock_nginx_site
    fi
    if [[ -f $site ]]; then
      previous=$(mktemp)
      cp "$site" "$previous"
    fi
    render_template "$INSTALL_DIR/deploy/nginx/basketball-scout.conf" "$site" \
      "SERVER_NAME=$server_name" "DEFAULT_SERVER=$default_server" "PORT=$PORT"
    chmod 644 "$site"
    if [[ $site == /etc/nginx/sites-available/* ]]; then
      enabled="/etc/nginx/sites-enabled/$NGINX_SITE_NAME"
      ln -sfn "$site" "$enabled"
    fi
  fi
  # Test before (re)starting nginx, so a bad file never takes down a running nginx.
  if ! nginx -t >/dev/null 2>&1; then
    nginx -t || true
    if [[ -n $previous ]]; then
      cp "$previous" "$site"
      rm -f "$previous"
    else
      rm -f "$site" "/etc/nginx/sites-enabled/$NGINX_SITE_NAME"
    fi
    if [[ $STOCK_SITE_DISABLED -eq 1 ]]; then
      ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    fi
    die "nginx rejected the configuration (see above), so the Basketball Scout site was not changed. If another site is already the default server, use --domain NAME."
  fi
  if [[ -n $previous ]]; then
    rm -f "$previous"
  fi
  systemctl enable --now --quiet nginx
  systemctl reload nginx
  ok "nginx serves ${DOMAIN:-this server} on port 80 and forwards to 127.0.0.1:$PORT"
}

disable_stock_nginx_site() {  # Debian's "Welcome to nginx" site would win requests by IP address
  local stock=/etc/nginx/sites-enabled/default
  if [[ -L $stock ]]; then
    rm -f "$stock"
    STOCK_SITE_DISABLED=1
    info "Disabled nginx's stock welcome site (the file stays in /etc/nginx/sites-available)"
  elif [[ -e $stock ]]; then
    warn "$stock is a custom site; leaving it alone. If nginx reports a duplicate default server, use --domain NAME."
  fi
}

wait_for_health() {
  local url="http://127.0.0.1:$PORT/api/health/live" deadline=$((SECONDS + HEALTH_TIMEOUT_S))
  step "Checking that the app answers"
  until curl -fsS --max-time 5 -o /dev/null "$url" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      systemctl --no-pager --lines=30 status "$WEB_UNIT" >&2 || true
      die "The web app did not answer on $url within $HEALTH_TIMEOUT_S seconds. Logs: journalctl -u ${WEB_UNIT%.service} -n 100"
    fi
    sleep 2
  done
  ok "Web app answers on $url"
  if systemctl is-active --quiet "$WORKER_UNIT"; then
    ok "Worker is running"
  else
    warn "The worker is not running. Logs: journalctl -u ${WORKER_UNIT%.service} -n 100"
  fi
  if [[ $WITH_NGINX -eq 1 ]]; then
    if curl -fsS --max-time 5 -o /dev/null -H "Host: ${DOMAIN:-localhost}" "http://127.0.0.1/api/health/live" 2>/dev/null; then
      ok "nginx forwards to the app"
    else
      warn "The app does not answer through nginx on port 80. Check: sudo nginx -t; journalctl -u nginx -n 50"
    fi
  fi
}

run_modal_deploy() {
  local modal_env
  step "Deploying the GPU app to Modal"
  if ! modal_credentials_present; then
    warn "No Modal credentials, so the GPU app was not deployed (see the next steps below)."
    MODAL_DEPLOY_RESULT=skipped
    return 0
  fi
  info "The first deploy builds the GPU image (about 10-20 minutes); later deploys are quicker."
  # --env: deploy into the environment the worker looks in, even if MODAL_ENVIRONMENT is not set.
  modal_env=$(env_get "$ENV_FILE" SCOUT_MODAL_ENVIRONMENT)
  if as_user_with_env "$INSTALL_DIR/.venv/bin/modal" deploy ${modal_env:+--env "$modal_env"} modal_app/app.py; then
    record_state modal
    MODAL_DEPLOY_RESULT=deployed
    ok "GPU app deployed"
  else
    MODAL_DEPLOY_RESULT=failed
    warn "modal deploy failed (see above). Try again with: sudo $INSTALL_DIR/scripts/update.sh --deploy-modal"
  fi
}

# --- Summary -----------------------------------------------------------------------------

app_url() {
  local address site
  address=$(hostname -I 2>/dev/null | awk '{ print $1 }' || true)
  address=${address:-$(hostname)}
  site=$(nginx_site_file)
  if [[ -n $DOMAIN ]] && [[ -f $site ]] && grep -q "managed by Certbot" "$site"; then
    printf 'https://%s/' "$DOMAIN"
  elif [[ -n $DOMAIN ]]; then
    printf 'http://%s/' "$DOMAIN"
  elif [[ $WITH_NGINX -eq 1 ]]; then
    printf 'http://%s/' "$address"
  else
    printf 'http://%s:%s/' "$address" "$PORT"
  fi
}

next_step() {  # next_step FIRST_LINE [MORE_LINES...]: numbered item under "Next steps"
  local line
  NEXT_STEP=$((NEXT_STEP + 1))
  printf '  %d. %s\n' "$NEXT_STEP" "$1"
  shift
  for line in "$@"; do
    printf '       %s\n' "$line"
  done
}

print_summary() {
  local user rule="$PORT/tcp" venv="$INSTALL_DIR/.venv"
  user=$(env_get "$ENV_FILE" SCOUT_AUTH_USERNAME)
  printf '\n%s======================================================================%s\n' "$C_GREEN" "$C_OFF"
  printf '%s  Basketball Scout is installed and running%s\n' "$C_BOLD" "$C_OFF"
  printf '%s======================================================================%s\n\n' "$C_GREEN" "$C_OFF"
  printf '  Open        %s\n' "$(app_url)"
  printf '  Username    %s\n' "${user:-coach}"
  if [[ -n $NEW_PASSWORD ]]; then
    printf '  Password    %s%s%s\n' "$C_BOLD" "$NEW_PASSWORD" "$C_OFF"
    printf '              New, and shown only this once: write it down. It is kept in\n'
    printf '              %s (readable only by root and %s).\n' "$ENV_FILE" "$SERVICE_USER"
  else
    printf '  Password    unchanged (SCOUT_AUTH_PASSWORD in %s)\n' "$ENV_FILE"
  fi
  printf '  Code        %s\n' "$INSTALL_DIR"
  printf '  Data        %s\n' "$DATA_DIR"
  printf '  Logs        journalctl -u basketball-scout-web -u basketball-scout-worker -f\n'
  printf '\n  Next steps\n'
  if [[ $EFFECTIVE_PROCESSOR == modal ]]; then
    if ! modal_credentials_present; then
      next_step "Connect Modal (film is analysed on its GPUs). Either run" \
        "sudo -u $SERVICE_USER -H $venv/bin/modal token new" \
        "or put MODAL_TOKEN_ID and MODAL_TOKEN_SECRET in $ENV_FILE. Then:" \
        "sudo systemctl restart basketball-scout-worker"
    fi
    if [[ $MODAL_DEPLOY_RESULT != deployed ]]; then
      next_step "Deploy the GPU app, unless you already did (first time about 10-20 minutes):" \
        "sudo $INSTALL_DIR/scripts/update.sh --deploy-modal"
    fi
    next_step "Optional GPU check (starts one GPU container for a few minutes):" \
      "cd $INSTALL_DIR && sudo -u $SERVICE_USER -H .venv/bin/python -m dotenv -f .env run -- .venv/bin/modal run modal_app/app.py::warmup"
  elif [[ $EFFECTIVE_PROCESSOR == mock ]]; then
    next_step "Demo mode: every film gets synthetic data. For real analysis set SCOUT_PROCESSOR=modal" \
      "in $ENV_FILE (or run: sudo $INSTALL_DIR/scripts/install.sh --processor modal)."
  fi
  if [[ -z $(env_get "$ENV_FILE" ANTHROPIC_API_KEY) ]]; then
    next_step "For the Claude scouting report, put ANTHROPIC_API_KEY=sk-ant-... in $ENV_FILE, then:" \
      "sudo systemctl restart basketball-scout-worker"
  fi
  if [[ -n $DOMAIN ]] && [[ $(app_url) == http://* ]]; then
    next_step "Turn on HTTPS (needs public DNS for $DOMAIN and port 80 open to the internet):" \
      "sudo apt-get install -y certbot python3-certbot-nginx && sudo certbot --nginx -d $DOMAIN" \
      "LAN-only server? See README.md > Security for Tailscale or your own certificate."
  elif [[ $WITH_NGINX -eq 0 ]]; then
    next_step "This address is plain http, so the password crosses the network unencrypted. For HTTPS run" \
      "sudo $INSTALL_DIR/scripts/install.sh --with-nginx --domain scout.yourschool.org" \
      "or use Tailscale (README.md > Security)."
  fi
  if [[ $WITH_NGINX -eq 1 ]]; then
    rule="80/tcp"
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    next_step "The ufw firewall is on. Let coaches in with:" "sudo ufw allow $rule"
  else
    next_step "Optional firewall (allows SSH first so you do not lock yourself out):" \
      "sudo ufw allow OpenSSH && sudo ufw allow $rule && sudo ufw enable"
  fi
  next_step "Later: update with  sudo $INSTALL_DIR/scripts/update.sh" \
    "remove with  sudo $INSTALL_DIR/scripts/uninstall.sh   (keeps the data unless --purge)"
  printf '\n  Guide: README.md (using the app, troubleshooting by error code) and docs/DEPLOYMENT.md\n\n'
}

main() {
  setup_colors
  parse_args "$@"
  validate_args
  require_root
  trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
  resolve_settings
  preflight
  show_plan
  confirm "Continue?" y || die "Nothing was changed."
  ask_for_missing_keys
  install_packages
  check_python
  ensure_service_user
  install_code
  install_python_env
  ensure_data_dir
  configure_env
  install_gpu_packages
  install_services
  if [[ $WITH_NGINX -eq 1 ]]; then
    configure_nginx
  fi
  wait_for_health
  record_state running
  if [[ $DEPLOY_MODAL -eq 1 ]]; then
    run_modal_deploy
  fi
  print_summary
  if [[ $MODAL_DEPLOY_RESULT == failed ]]; then
    die "Installed, but the Modal deploy failed (see above)."
  fi
}

# Run main unless the file is being sourced (tests/test_ops.py sources it to call the
# .env and template helpers). Do not source it in your own shell: it turns on `set -e`.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
