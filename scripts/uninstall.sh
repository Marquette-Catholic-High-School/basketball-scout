#!/usr/bin/env bash
# Remove Basketball Scout from this server.
#
#   sudo /opt/basketball-scout/scripts/uninstall.sh [options]
#
# Stops and removes the two systemd services, removes the nginx site and deletes the
# code folder (code + Python environment), and for SCOUT_PROCESSOR=local the
# OpenHoopVision checkout and the NVIDIA module list that install.sh added. The data
# folder (games, film, database) stays, with a copy of .env in <data folder>/backups/, so
# running install.sh again brings everything back. --purge deletes the data as well.
# Safe to run more than once.
#
# The steps run inside main(), called on the last line, because this script deletes the
# folder it lives in.

set -Eeuo pipefail

DEFAULT_DIR=/opt/basketball-scout
DEFAULT_DATA_DIR=/var/lib/basketball-scout
DEFAULT_USER=scout
WEB_UNIT=basketball-scout-web.service
WORKER_UNIT=basketball-scout-worker.service
SYSTEMD_DIR=/etc/systemd/system
NGINX_SITE_NAME=basketball-scout
USER_COMMENT="Basketball Scout service"
DEFAULT_OHV_HOME=/opt/openhoopvision
NVIDIA_MODULES_FILE=/etc/modules-load.d/basketball-scout-nvidia.conf  # install.sh --processor local

# Options (see usage).
INSTALL_DIR=""
DATA_DIR=""
SERVICE_USER=""
PURGE=0
REMOVE_USER=0
REMOVE_MODAL=0
ASSUME_YES=0

# Worked out while the script runs.
ENV_FILE=""
SERVICE_HOME=""
QUEUE_BACKEND=sqlite
MODAL_APP=basketball-scout
MODAL_VOLUME=basketball-scout-data
MODAL_DICT=basketball-scout-progress
MODAL_ENV=""  # SCOUT_MODAL_ENVIRONMENT ("" = the workspace default)
OHV_DIR=""    # SCOUT_PROCESSOR=local: the OpenHoopVision checkout (OHV_HOME) install.sh made ("" = none)
OHV_KEPT=""   # why OHV_DIR is not deleted ("" = it is)
REMOVED_LOCAL_GPU=""  # what remove_local_gpu deleted, for the summary

C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD="" C_OFF=""

usage() {
  cat <<EOF
Remove Basketball Scout from this server.

Usage: sudo scripts/uninstall.sh [options]

  --dir DIR         installation to remove (default: the installed one, else $DEFAULT_DIR)
  --data-dir DIR    data folder (default: SCOUT_DATA_DIR from .env, else $DEFAULT_DATA_DIR)
  --user NAME       service user (default: the user in the installed services)
  --purge           ALSO delete the data folder: every game, film, roster and report
  --remove-user     also delete the service user and its home folder (with ~/.modal.toml)
  --remove-modal    also stop the GPU app on Modal and offer to delete its storage volume
  -y, --yes         do not ask for confirmation (not even for --purge)
  -h, --help        show this help

Kept unless you ask: the data folder (plus a copy of .env in its backups/ folder), the
service user, the Modal app, and nginx / Redis themselves (other software may use them).
With SCOUT_PROCESSOR=local the OpenHoopVision checkout (OHV_HOME) goes with the code.
Reinstall later with scripts/install.sh: it finds the kept data and settings.
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
  printf '\n%s[error]%s uninstall.sh stopped at line %s (exit code %s) while running:\n    %s\n' \
    "$C_RED" "$C_OFF" "$line" "$status" "$command" >&2
  printf '    Fix the problem shown above and run the same command again; it skips what is already removed.\n' >&2
}

tty_available() { { : </dev/tty; } 2>/dev/null; }

confirm() {  # confirm QUESTION: -y answers yes; otherwise ask on the terminal (default no)
  local answer=""
  if [[ $ASSUME_YES -eq 1 ]]; then
    return 0
  fi
  if tty_available; then
    printf '    %s [y/N] ' "$1" >/dev/tty
    IFS= read -r answer </dev/tty || answer=""
  fi
  case $answer in
    [Yy] | [Yy][Ee][Ss]) return 0 ;;
  esac
  return 1
}

# --- Arguments -------------------------------------------------------------------------

need_value() {  # need_value OPTION [VALUE]: the option got a value
  if [[ $# -lt 2 || -z $2 || $2 == --* ]]; then
    die "$1 needs a value (see --help)"
  fi
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
      --purge) PURGE=1 ;;
      --remove-user) REMOVE_USER=1 ;;
      --remove-modal) REMOVE_MODAL=1 ;;
      -y | --yes) ASSUME_YES=1 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  if [[ -n $INSTALL_DIR && $INSTALL_DIR != /* ]]; then
    die "--dir must be an absolute path (got '$INSTALL_DIR')."
  fi
  if [[ -n $DATA_DIR && $DATA_DIR != /* ]]; then
    die "--data-dir must be an absolute path (got '$DATA_DIR')."
  fi
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "uninstall.sh needs root. Run: sudo $0"
  fi
}

# --- Helpers ----------------------------------------------------------------------------

strip_trailing_slashes() {
  local path=$1
  while [[ $path == */ && $path != / ]]; do
    path=${path%/}
  done
  printf '%s' "$path"
}

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

installed_unit_value() {  # value of KEY= in the installed web unit (empty when not installed)
  if [[ -f $SYSTEMD_DIR/$WEB_UNIT ]]; then
    awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$SYSTEMD_DIR/$WEB_UNIT"
  fi
}

user_home() {
  if id -u "$1" >/dev/null 2>&1; then
    getent passwd "$1" | cut -d: -f6
  fi
}

default_install_dir() {  # the installed copy, else the checkout holding this script, else /opt
  local dir script_dir
  dir=$(installed_unit_value WorkingDirectory)
  if [[ -n $dir ]]; then
    printf '%s' "$dir"
    return 0
  fi
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
  if [[ -n $script_dir && -d $script_dir/../.git && -f $script_dir/../scout/main.py ]]; then
    (cd "$script_dir/.." && pwd)
    return 0
  fi
  printf '%s' "$DEFAULT_DIR"
}

protected_reason() {  # protected_reason PATH: why PATH must never be deleted ("" = it may be)
  local protected
  for protected in / /bin /boot /dev /etc /home /lib /lib64 /media /mnt /opt /proc /root /run \
    /sbin /snap /srv /sys /tmp /usr /usr/local /var /var/lib /var/log; do
    if [[ $1 == "$protected" ]]; then
      printf 'a system folder'
      return 0
    fi
  done
  if [[ $1 != /*/* ]]; then
    printf 'expected a folder like %s' "$DEFAULT_DIR"
  fi
}

check_removable() {  # check_removable PATH WHAT: never delete a system folder
  local reason
  reason=$(protected_reason "$1")
  if [[ -n $reason ]]; then
    die "Refusing to delete $1 ($2): $reason."
  fi
}

inside() {  # inside PATH DIR: PATH is DIR or lies inside it
  [[ $1 == "$2" || $1 == "$2"/* ]]
}

modal_cli() {  # the Modal CLI as the service user, with .env loaded (credentials), in the app's environment
  runuser -u "$SERVICE_USER" -- env -C "$INSTALL_DIR" HOME="$SERVICE_HOME" \
    "$INSTALL_DIR/.venv/bin/python" -m dotenv -f "$ENV_FILE" run -- "$INSTALL_DIR/.venv/bin/modal" "$@" \
    ${MODAL_ENV:+--env "$MODAL_ENV"}
}

# --- Steps ------------------------------------------------------------------------------

resolve() {
  local value
  INSTALL_DIR=$(strip_trailing_slashes "${INSTALL_DIR:-$(default_install_dir)}")
  ENV_FILE="$INSTALL_DIR/.env"
  if [[ -z $DATA_DIR ]]; then
    DATA_DIR=$(env_get "$ENV_FILE" SCOUT_DATA_DIR)
    value=${DATA_DIR#./}
    value="$INSTALL_DIR/${value:-data}"
    if [[ -f $ENV_FILE && $DATA_DIR != /* ]] && [[ -e $value/scout.db || -d $value/games ]]; then
      # The app reads a relative (or unset, i.e. "data") SCOUT_DATA_DIR from the code folder,
      # and games are there.
      DATA_DIR=$value
    elif [[ $DATA_DIR != /* ]]; then
      DATA_DIR=$DEFAULT_DATA_DIR
    fi
  fi
  DATA_DIR=$(strip_trailing_slashes "$DATA_DIR")
  if [[ -z $SERVICE_USER ]]; then
    SERVICE_USER=$(installed_unit_value User)
  fi
  if [[ -z $SERVICE_USER && -d $INSTALL_DIR ]]; then
    SERVICE_USER=$(stat -c %U "$INSTALL_DIR")
  fi
  SERVICE_USER=${SERVICE_USER:-$DEFAULT_USER}
  SERVICE_HOME=$(user_home "$SERVICE_USER")
  value=$(env_get "$ENV_FILE" SCOUT_QUEUE_BACKEND)
  QUEUE_BACKEND=${value:-sqlite}
  value=$(env_get "$ENV_FILE" SCOUT_MODAL_APP_NAME)
  MODAL_APP=${value:-$MODAL_APP}
  value=$(env_get "$ENV_FILE" SCOUT_MODAL_VOLUME_NAME)
  MODAL_VOLUME=${value:-$MODAL_VOLUME}
  value=$(env_get "$ENV_FILE" SCOUT_MODAL_PROGRESS_DICT)
  MODAL_DICT=${value:-$MODAL_DICT}
  MODAL_ENV=$(env_get "$ENV_FILE" SCOUT_MODAL_ENVIRONMENT)

  check_removable "$INSTALL_DIR" "--dir"
  if [[ -d $INSTALL_DIR && ! -f $INSTALL_DIR/scout/main.py && ! -f $INSTALL_DIR/deploy/systemd/$WEB_UNIT ]]; then
    die "$INSTALL_DIR does not look like a Basketball Scout installation; nothing was removed. Use --dir."
  fi
  if [[ $DATA_DIR == "$INSTALL_DIR" || $DATA_DIR == "$INSTALL_DIR"/* ]] && [[ $PURGE -eq 0 ]]; then
    die "The data folder $DATA_DIR is inside $INSTALL_DIR, so removing the code would delete the games. Move the data first, or use --purge."
  fi
  # The app's default folder <code>/data (SCOUT_DATA_DIR unset, no .env, or an earlier
  # relative setting) may still hold games although .env now points elsewhere.
  if [[ $PURGE -eq 0 ]] && [[ -e $INSTALL_DIR/data/scout.db || -d $INSTALL_DIR/data/games ]]; then
    die "$INSTALL_DIR/data holds games (scout.db or games/), so removing the code would delete them. Move or delete them first (docs/DEPLOYMENT.md > Moving the data folder), or use --purge."
  fi
  # userdel --remove deletes the home folder, and with it a data folder kept inside it.
  if [[ $REMOVE_USER -eq 1 && $PURGE -eq 0 && -n $SERVICE_HOME ]] &&
    [[ $DATA_DIR == "$SERVICE_HOME" || $DATA_DIR == "$SERVICE_HOME"/* ]]; then
    die "The data folder $DATA_DIR is inside $SERVICE_HOME, the home folder that --remove-user deletes. Move the data first, leave out --remove-user, or use --purge."
  fi
  if [[ $PURGE -eq 1 ]]; then
    check_removable "$DATA_DIR" "--data-dir"
  fi
  if [[ $(env_get "$ENV_FILE" SCOUT_PROCESSOR) == local ]]; then
    resolve_ohv_dir
  fi
}

resolve_ohv_dir() {  # the OpenHoopVision checkout install.sh made in OHV_HOME: derived, so it goes with the code
  local value
  value=$(env_get "$ENV_FILE" OHV_HOME)
  OHV_DIR=$(strip_trailing_slashes "${value:-$DEFAULT_OHV_HOME}")
  if [[ $OHV_DIR != /* ]]; then
    OHV_DIR="$INSTALL_DIR/$OHV_DIR"  # read from the code folder, like the app does
  fi
  if [[ ! -e $OHV_DIR ]] || inside "$OHV_DIR" "$INSTALL_DIR"; then
    OHV_DIR=""  # nothing there, or it is deleted with the code folder anyway
    return 0
  fi
  OHV_KEPT=$(protected_reason "$OHV_DIR")
  if [[ -n $OHV_KEPT ]]; then
    return 0
  fi
  if [[ ! -d $OHV_DIR/.git || ! -f $OHV_DIR/main.py ]]; then
    OHV_KEPT="it does not look like an OpenHoopVision checkout"
  elif inside "$DATA_DIR" "$OHV_DIR" || inside "$INSTALL_DIR" "$OHV_DIR"; then
    OHV_KEPT="the data or code folder is inside it"
  fi
}

show_plan() {
  step "Basketball Scout will be removed"
  info "Services     basketball-scout-web and basketball-scout-worker: stopped, disabled, deleted"
  info "nginx        the basketball-scout site, if there is one (nginx itself stays)"
  info "Code         $INSTALL_DIR (code and Python environment)"
  if [[ -n $OHV_DIR && -z $OHV_KEPT ]]; then
    info "Local GPU    $OHV_DIR (OpenHoopVision and its model weights)"
  elif [[ -n $OHV_DIR ]]; then
    info "Local GPU    kept: $OHV_DIR ($OHV_KEPT)"
  fi
  if [[ -e $NVIDIA_MODULES_FILE ]]; then
    info "Boot config  $NVIDIA_MODULES_FILE (loads the NVIDIA modules for the worker)"
  fi
  if [[ $PURGE -eq 1 ]]; then
    info "Data         ${C_RED}DELETED${C_OFF}: $DATA_DIR (every game, film, roster and report)"
  else
    info "Data         kept: $DATA_DIR (with a copy of .env in $DATA_DIR/backups/)"
  fi
  if [[ $REMOVE_USER -eq 1 ]]; then
    info "User         deleted: $SERVICE_USER and its home folder ${SERVICE_HOME:-}"
  else
    info "User         kept: $SERVICE_USER"
  fi
  if [[ $REMOVE_MODAL -eq 1 ]]; then
    info "Modal        the app $MODAL_APP is stopped; you are asked about the volume $MODAL_VOLUME"
  else
    info "Modal        kept (the GPU app costs nothing while idle)"
  fi
}

confirm_removal() {
  local answer=""
  if [[ $ASSUME_YES -eq 1 ]]; then
    return 0
  fi
  if ! tty_available; then
    die "There is no terminal to confirm on; run again with --yes."
  fi
  if [[ $PURGE -eq 1 ]]; then
    printf '\n    %sThis permanently deletes all games and film in %s.%s\n' "$C_RED" "$DATA_DIR" "$C_OFF" >/dev/tty
    printf '    Type DELETE to continue: ' >/dev/tty
    IFS= read -r answer </dev/tty || answer=""
    if [[ $answer != DELETE ]]; then
      die "Nothing was removed."
    fi
  elif ! confirm "Remove Basketball Scout?"; then
    die "Nothing was removed."
  fi
}

remove_modal() {
  step "Modal"
  if [[ ! -x $INSTALL_DIR/.venv/bin/modal || ! -f $ENV_FILE || -z $SERVICE_HOME ]]; then
    warn "The Modal tool is not available here any more. From any computer with Modal set up, run:"
    info "modal app stop $MODAL_APP -y${MODAL_ENV:+ --env $MODAL_ENV}"
    info "modal volume delete $MODAL_VOLUME -y${MODAL_ENV:+ --env $MODAL_ENV}"
    info "modal dict delete $MODAL_DICT -y${MODAL_ENV:+ --env $MODAL_ENV}"
    return 0
  fi
  if modal_cli app stop "$MODAL_APP" -y; then
    ok "Stopped the Modal app $MODAL_APP"
  else
    warn "Could not stop the Modal app $MODAL_APP (already stopped, or no Modal credentials)."
  fi
  if confirm "Also delete the Modal volume $MODAL_VOLUME and the dict $MODAL_DICT (film and results stored on Modal)?"; then
    if modal_cli volume delete "$MODAL_VOLUME" -y; then
      ok "Deleted the Modal volume $MODAL_VOLUME"
    else
      warn "Could not delete the Modal volume $MODAL_VOLUME (maybe it does not exist)."
    fi
    if modal_cli dict delete "$MODAL_DICT" -y; then
      ok "Deleted the Modal dict $MODAL_DICT"
    else
      warn "Could not delete the Modal dict $MODAL_DICT (maybe it does not exist)."
    fi
  else
    info "Kept the Modal volume. Delete it later with: modal volume delete $MODAL_VOLUME -y${MODAL_ENV:+ --env $MODAL_ENV}"
  fi
}

remove_services() {
  local unit
  step "Services"
  for unit in "$WORKER_UNIT" "$WEB_UNIT"; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/$unit"
    if [[ -d $SYSTEMD_DIR/$unit.d ]]; then
      rm -r "$SYSTEMD_DIR/$unit.d"
    fi
  done
  systemctl daemon-reload
  systemctl reset-failed "$WEB_UNIT" "$WORKER_UNIT" >/dev/null 2>&1 || true
  ok "basketball-scout-web and basketball-scout-worker are stopped and removed"
}

remove_nginx_site() {
  local site found="" had_certbot=0
  local enabled="/etc/nginx/sites-enabled/$NGINX_SITE_NAME"
  for site in "/etc/nginx/sites-available/$NGINX_SITE_NAME" "/etc/nginx/conf.d/$NGINX_SITE_NAME.conf"; do
    if [[ -f $site ]]; then
      found="$found $site"
    fi
  done
  if [[ -z $found && ! -L $enabled && ! -e $enabled ]]; then
    return 0
  fi
  step "nginx"
  for site in $found; do
    if grep -q "Certbot" "$site"; then
      had_certbot=1
    fi
    rm -f "$site"
  done
  rm -f "$enabled"
  restore_stock_nginx_site
  if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx
      ok "Removed the basketball-scout site and reloaded nginx"
    else
      warn "Removed the site, but nginx -t reports a problem elsewhere; fix it, then: sudo systemctl reload nginx"
    fi
  else
    ok "Removed the basketball-scout site"
  fi
  if [[ $had_certbot -eq 1 ]]; then
    info "The HTTPS certificate is still installed. Remove it with: sudo certbot delete"
  fi
}

restore_stock_nginx_site() {  # install.sh disabled the welcome site; restore it if nothing else is enabled
  local enabled_dir=/etc/nginx/sites-enabled
  if [[ -d $enabled_dir && -f /etc/nginx/sites-available/default && -z $(ls -A "$enabled_dir") ]]; then
    ln -s /etc/nginx/sites-available/default "$enabled_dir/default"
    info "Re-enabled nginx's default site"
  fi
}

backup_env() {
  local backup
  if [[ ! -f $ENV_FILE ]]; then
    return 0
  fi
  step "Settings"
  install -d -m 700 "$DATA_DIR/backups"
  backup="$DATA_DIR/backups/env-$(date +%Y%m%d-%H%M%S)"
  cp "$ENV_FILE" "$backup"
  chmod 600 "$backup"
  ok "Saved .env (passwords and keys) as $backup"
}

remove_local_gpu() {  # SCOUT_PROCESSOR=local: install.sh's OpenHoopVision checkout and NVIDIA module list
  if [[ -z $OHV_DIR && ! -e $NVIDIA_MODULES_FILE ]]; then
    return 0
  fi
  step "Local GPU pipeline"
  if [[ -n $OHV_DIR && -n $OHV_KEPT ]]; then
    warn "Kept $OHV_DIR (OHV_HOME): $OHV_KEPT."
  elif [[ -n $OHV_DIR ]]; then
    rm -rf --one-file-system "$OHV_DIR"
    REMOVED_LOCAL_GPU="the OpenHoopVision checkout $OHV_DIR"
    ok "Deleted $OHV_DIR (OpenHoopVision and its model weights)"
  fi
  if [[ -e $NVIDIA_MODULES_FILE ]]; then
    rm -f "$NVIDIA_MODULES_FILE"
    REMOVED_LOCAL_GPU="${REMOVED_LOCAL_GPU:+$REMOVED_LOCAL_GPU and }$NVIDIA_MODULES_FILE"
    ok "Deleted $NVIDIA_MODULES_FILE (it loaded the NVIDIA modules at boot for the worker)"
  fi
}

remove_code() {
  step "Code"
  if [[ ! -e $INSTALL_DIR ]]; then
    ok "$INSTALL_DIR is already gone"
    return 0
  fi
  rm -rf --one-file-system "$INSTALL_DIR"
  ok "Deleted $INSTALL_DIR"
}

remove_data() {
  local entry
  step "Data"
  if [[ ! -e $DATA_DIR ]]; then
    ok "$DATA_DIR is already gone"
    return 0
  fi
  if [[ -n $(ls -A "$DATA_DIR") && ! -e $DATA_DIR/scout.db && ! -d $DATA_DIR/games && ! -d $DATA_DIR/backups ]]; then
    die "$DATA_DIR does not look like a Basketball Scout data folder (no scout.db or games/); not deleting it."
  fi
  if mountpoint -q "$DATA_DIR" 2>/dev/null; then
    # A disk of its own (docs/PROXMOX.md > Storage sizing): a mount point cannot be deleted
    # ("Device or resource busy"), so empty it and leave the disk mounted.
    for entry in "$DATA_DIR"/* "$DATA_DIR"/.[!.]* "$DATA_DIR"/..?*; do
      if [[ -e $entry || -L $entry ]]; then
        rm -rf --one-file-system "$entry"
      fi
    done
    ok "Emptied $DATA_DIR (games, film, database, settings backups); the disk mounted there stays"
  else
    rm -rf --one-file-system "$DATA_DIR"
    ok "Deleted $DATA_DIR (games, film, database, settings backups)"
  fi
  if [[ $QUEUE_BACKEND == redis ]]; then
    info "Redis still holds a few queue keys. Remove them with:"
    info "redis-cli --scan --pattern 'scout:*' | xargs -r redis-cli del"
  fi
}

remove_user() {
  local uid comment
  step "Service user"
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    ok "User $SERVICE_USER is already gone"
    return 0
  fi
  uid=$(id -u "$SERVICE_USER")
  comment=$(getent passwd "$SERVICE_USER" | cut -d: -f5)
  if [[ $uid -eq 0 || $comment != "$USER_COMMENT" ]]; then
    warn "Not deleting $SERVICE_USER: it was not created by install.sh (description: '$comment')."
    return 0
  fi
  if userdel --remove "$SERVICE_USER"; then
    ok "Deleted user $SERVICE_USER and its home folder (Modal token file included)"
    if [[ $PURGE -eq 0 && -d $DATA_DIR ]]; then
      info "The kept data folder now belongs to a user ID without a name; install.sh fixes that on reinstall."
    fi
  else
    warn "userdel failed. Is something still running as $SERVICE_USER? Check: ps -u $SERVICE_USER"
  fi
}

print_summary() {
  printf '\n%s======================================================================%s\n' "$C_GREEN" "$C_OFF"
  printf '%s  Basketball Scout was removed%s\n' "$C_BOLD" "$C_OFF"
  printf '%s======================================================================%s\n' "$C_GREEN" "$C_OFF"
  if [[ $PURGE -eq 0 ]]; then
    printf '  Your games are still in %s.\n' "$DATA_DIR"
    printf '  Reinstall with scripts/install.sh to use them again, or delete them: sudo rm -r %s\n' "$DATA_DIR"
  fi
  if [[ -n $REMOVED_LOCAL_GPU ]]; then
    printf '  Local GPU: deleted %s; the NVIDIA driver stays installed.\n' "$REMOVED_LOCAL_GPU"
  fi
  if [[ -n $OHV_DIR && -n $OHV_KEPT ]]; then
    printf '  Local GPU: OHV_HOME (%s) was not deleted: %s.\n' "$OHV_DIR" "$OHV_KEPT"
  fi
  printf '  System packages (nginx, redis-server, ffmpeg, python3) were left installed.\n'
  printf '  Remove the ones nothing else needs with: sudo apt-get purge nginx redis-server\n'
  if [[ $REMOVE_MODAL -eq 0 ]]; then
    printf '  The GPU app is still deployed on Modal. Remove it with: modal app stop %s -y%s\n' \
      "$MODAL_APP" "${MODAL_ENV:+ --env $MODAL_ENV}"
  fi
  printf '  No longer needed? Revoke the Modal token (Modal dashboard) and the Anthropic API key\n'
  printf '  (console.anthropic.com) that this server used.\n\n'
}

main() {
  setup_colors
  parse_args "$@"
  require_root
  trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
  resolve
  show_plan
  confirm_removal
  if [[ $REMOVE_MODAL -eq 1 ]]; then
    remove_modal
  fi
  remove_services
  remove_nginx_site
  if [[ $PURGE -eq 0 ]]; then
    backup_env
  fi
  remove_local_gpu  # before the code, so a re-run after a failure still finds OHV_HOME in .env
  remove_code
  if [[ $PURGE -eq 1 ]]; then
    remove_data
  fi
  if [[ $REMOVE_USER -eq 1 ]]; then
    remove_user
  fi
  print_summary
}

# Run main unless the file is being sourced (tests do that). Do not source it yourself.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
