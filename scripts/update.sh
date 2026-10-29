#!/usr/bin/env bash
# Update Basketball Scout from GitHub and redeploy.
#
#   sudo /opt/basketball-scout/scripts/update.sh [options]
#
# Steps: check the checkout, stop if the code has local changes (--force saves them,
# updates and puts them back on top), git fetch + fast-forward (git runs as the service
# user), install the Python requirements (with SCOUT_PROCESSOR=local also the GPU packages
# and the pinned OpenHoopVision commit, when they changed), run the database migrations,
# redeploy the GPU app to Modal when modal_app/ changed, restart both services, check
# that the web app answers and show what changed. It prints the commands that go back to
# the previous version at the end, and when a step fails.
#
# The steps run inside main(), called on the last line: git may replace this file while
# it runs, and bash has already read all of it by then.

set -Eeuo pipefail

DEFAULT_DIR=/opt/basketball-scout
DEFAULT_DATA_DIR=/var/lib/basketball-scout
WEB_UNIT=basketball-scout-web.service
WORKER_UNIT=basketball-scout-worker.service
SYSTEMD_DIR=/etc/systemd/system
HEALTH_TIMEOUT_S=90

# Options (see usage).
INSTALL_DIR=""
BRANCH=""
DEPLOY_MODE=auto
FORCE=0
SKIP_RESTART=0

# Worked out while the script runs.
SERVICE_USER=""
SERVICE_HOME=""
ENV_FILE=""
OLD_HEAD=""      # checked out before this run
NEW_HEAD=""      # checked out after the pull
RUNNING_HEAD=""  # what the services last started on (an earlier update may have stopped halfway)
MODAL_HEAD=""    # what was last deployed to Modal by install.sh / update.sh ("" = unknown)
CODE_CHANGED=0
RESTARTED=0      # restart_services restarted the services (on NEW_HEAD)
GPU_UPDATED=0    # this run installed modal_app/requirements-gpu.txt (SCOUT_PROCESSOR=local)
OHV_UPDATED=""   # the OpenHoopVision folder this run checked out again (SCOUT_PROCESSOR=local)
MODAL_DEPLOYED=0
MODAL_SUMMARY="not needed"
MODAL_ENV=""     # SCOUT_MODAL_ENVIRONMENT: the Modal environment the worker looks in ("" = default)
SAVE_CHANGES=0   # --force and the checkout has local changes
STASH_COMMIT=""  # the stash holding them while the code is updated ("" = nothing saved)
LOCAL_PATCH=""   # the same changes as a .patch file in <data>/backups/

C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD="" C_OFF=""

usage() {
  cat <<EOF
Update Basketball Scout to the latest version from GitHub and restart it.

Usage: sudo scripts/update.sh [options]

  --dir DIR           installation to update (default: the installed one, else $DEFAULT_DIR)
  --branch NAME       branch to follow (default: the branch that is checked out)
  --deploy-modal      always redeploy the GPU app to Modal
  --no-deploy-modal   never redeploy the GPU app
                      (default: redeploy when modal_app/ changed, SCOUT_PROCESSOR=modal
                      and Modal credentials exist)
  --force             update although the code has local changes (e.g. edited
                      config/*.yaml): save them (git stash + a .patch file), update,
                      then put them back
  --skip-restart      update the files only; restart the services yourself later
  -h, --help          show this help

Examples:
  sudo /opt/basketball-scout/scripts/update.sh
  sudo /opt/basketball-scout/scripts/update.sh --deploy-modal
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
  print_rollback_help >&2
  exit 1
}

on_error() {  # ERR trap: where it stopped, and how to go back when the code already changed
  local status=$1 line=$2 command=$3
  if [[ $BASH_SUBSHELL -gt 0 ]]; then
    return 0
  fi
  printf '\n%s[error]%s update.sh stopped at line %s (exit code %s) while running:\n    %s\n' \
    "$C_RED" "$C_OFF" "$line" "$status" "$command" >&2
  print_rollback_help >&2
}

print_rollback_help() {
  if [[ $CODE_CHANGED -eq 0 || -z $RUNNING_HEAD ]]; then
    return 0
  fi
  if [[ $RESTARTED -eq 1 ]]; then
    printf '\n  The code was already updated and the services were restarted on the new version.\n'
    printf '  Fix the problem shown above and run update.sh again (it restarts and checks them\n'
    printf '  again), or go back to the version that ran before this update (%s):\n' "${RUNNING_HEAD:0:12}"
  else
    printf '\n  The code was already updated. Running update.sh again finishes the update; the\n'
    printf '  services keep running the old version until they are restarted.\n'
    printf '  To go back to the version that ran before this update (%s) instead:\n' "${RUNNING_HEAD:0:12}"
  fi
  print_rollback_commands
}

print_rollback_commands() {  # the commands that return the code, packages, GPU app and services to RUNNING_HEAD
  local forget
  printf '    sudo -u %s git -C %s reset --hard %s\n' "$SERVICE_USER" "$INSTALL_DIR" "$RUNNING_HEAD"
  if [[ -n $STASH_COMMIT ]]; then
    printf '    sudo -u %s git -C %s stash apply %s   # your local changes (also in %s)\n' \
      "$SERVICE_USER" "$INSTALL_DIR" "${STASH_COMMIT:0:12}" "$LOCAL_PATCH"
  fi
  printf '    sudo -u %s -H %s/.venv/bin/python -m pip install -r %s/requirements.txt\n' "$SERVICE_USER" "$INSTALL_DIR" "$INSTALL_DIR"
  if [[ $GPU_UPDATED -eq 1 ]]; then
    printf '    sudo -u %s -H %s/.venv/bin/python -m pip install -r %s/modal_app/requirements-gpu.txt\n' \
      "$SERVICE_USER" "$INSTALL_DIR" "$INSTALL_DIR"
  fi
  if [[ -n $OHV_UPDATED ]]; then  # the old modal_app/pipeline/ohv.py checks out the OpenHoopVision commit it pins
    printf '    cd %s && sudo -u %s -H .venv/bin/python -m modal_app.pipeline.ohv install --home %s\n' \
      "$INSTALL_DIR" "$SERVICE_USER" "$OHV_UPDATED"
  fi
  forget=$(state_file running)
  if [[ $MODAL_DEPLOYED -eq 1 ]]; then
    printf '    cd %s && sudo -u %s -H .venv/bin/python -m dotenv -f .env run -- .venv/bin/modal deploy%s modal_app/app.py\n' \
      "$INSTALL_DIR" "$SERVICE_USER" "${MODAL_ENV:+ --env $MODAL_ENV}"
    forget="$forget $(state_file modal)"
  fi
  # The records of what the services and Modal run would be wrong after going back by hand: the
  # next update would then skip the restart or the GPU redeploy. Without them it compares with
  # the version checked out.
  printf '    sudo rm -f %s\n' "$forget"
  printf '    sudo systemctl restart basketball-scout-web basketball-scout-worker\n'
}

# --- Arguments -------------------------------------------------------------------------

need_value() {  # need_value OPTION [VALUE]: the option got a value
  if [[ $# -lt 2 || -z $2 || $2 == --* ]]; then
    die "$1 needs a value (see --help)"
  fi
}

parse_args() {
  local deploy_flag=""
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
      --branch) need_value "$@"; BRANCH=$2; shift ;;
      --deploy-modal | --no-deploy-modal)
        if [[ -n $deploy_flag && $deploy_flag != "$1" ]]; then
          die "Use either --deploy-modal or --no-deploy-modal, not both."
        fi
        deploy_flag=$1
        if [[ $1 == --deploy-modal ]]; then DEPLOY_MODE=yes; else DEPLOY_MODE=no; fi
        ;;
      --force) FORCE=1 ;;
      --skip-restart) SKIP_RESTART=1 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  local branch_re='^[A-Za-z0-9._/][A-Za-z0-9._/-]*$'
  if [[ -n $BRANCH && ! $BRANCH =~ $branch_re ]]; then
    die "--branch '$BRANCH' is not a valid branch name."
  fi
  if [[ -n $INSTALL_DIR && $INSTALL_DIR != /* ]]; then
    die "--dir must be an absolute path (got '$INSTALL_DIR')."
  fi
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "update.sh needs root (it runs git as the service user and restarts the services). Run: sudo $0"
  fi
}

# --- Helpers ----------------------------------------------------------------------------

as_user() {  # run a command as the service user, from the install folder
  # env -C instead of a ( cd ...; ) subshell, so a failure still reaches the ERR trap.
  runuser -u "$SERVICE_USER" -- env -C "$INSTALL_DIR" HOME="$SERVICE_HOME" GIT_TERMINAL_PROMPT=0 "$@"
}

as_user_with_env() {  # same, with .env loaded the way the app loads it (python-dotenv)
  as_user "$INSTALL_DIR/.venv/bin/python" -m dotenv -f "$ENV_FILE" run -- "$@"
}

git_user() { as_user git -C "$INSTALL_DIR" "$@"; }

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

default_install_dir() {  # the installed copy, else the checkout holding this script, else /opt
  local dir script_dir
  dir=$(installed_unit_value WorkingDirectory)
  if [[ -n $dir ]]; then
    printf '%s' "$dir"
    return 0
  fi
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
  if [[ -n $script_dir && -d $script_dir/../.git ]]; then
    (cd "$script_dir/.." && pwd)
    return 0
  fi
  printf '%s' "$DEFAULT_DIR"
}

changed_since() {  # changed_since BASE PATH...: files under PATH differ between BASE and NEW_HEAD
  local base=$1
  shift
  if [[ $base == "$NEW_HEAD" ]]; then
    return 1
  fi
  if git_user diff --quiet "$base" "$NEW_HEAD" -- "$@"; then
    return 1
  fi
  return 0
}

state_file() { printf '%s' "$INSTALL_DIR/.git/basketball-scout-$1"; }

read_state() {  # read_state running|modal: the commit install.sh / update.sh recorded, if still known to git
  local commit=""
  if [[ -f $(state_file "$1") ]]; then
    commit=$(head -n 1 "$(state_file "$1")")
  fi
  if [[ -n $commit ]] && git_user cat-file -e "$commit^{commit}" 2>/dev/null; then
    printf '%s' "$commit"
  fi
}

record_state() {  # record_state running|modal: remember that NEW_HEAD is live there
  printf '%s\n' "$NEW_HEAD" >"$(state_file "$1")"
  chown "$SERVICE_USER:$(id -gn "$SERVICE_USER")" "$(state_file "$1")"
}

modal_credentials_present() {
  if [[ -n $(env_get "$ENV_FILE" MODAL_TOKEN_ID) && -n $(env_get "$ENV_FILE" MODAL_TOKEN_SECRET) ]]; then
    return 0
  fi
  if [[ -f $SERVICE_HOME/.modal.toml ]]; then
    return 0
  fi
  return 1
}

data_dir() {
  local dir
  dir=$(env_get "$ENV_FILE" SCOUT_DATA_DIR)
  if [[ $dir == /* ]]; then
    printf '%s' "$dir"
  else
    printf '%s' "$DEFAULT_DATA_DIR"
  fi
}

web_port() {  # the port in the installed unit's ExecStart (--port N), else .env, else 8000
  local port=""
  if [[ -f $SYSTEMD_DIR/$WEB_UNIT ]]; then
    port=$(sed -n 's/.*--port \([0-9][0-9]*\).*/\1/p' "$SYSTEMD_DIR/$WEB_UNIT")
  fi
  if [[ -z $port ]]; then
    port=$(env_get "$ENV_FILE" SCOUT_PORT)
  fi
  printf '%s' "${port:-8000}"
}

# --- Steps ------------------------------------------------------------------------------

check_checkout() {
  local owner
  INSTALL_DIR=${INSTALL_DIR:-$(default_install_dir)}
  ENV_FILE="$INSTALL_DIR/.env"
  step "Checking $INSTALL_DIR"
  if [[ ! -d $INSTALL_DIR/.git ]]; then
    die "$INSTALL_DIR is not a git checkout of Basketball Scout. Install it with scripts/install.sh, or pass --dir."
  fi
  if [[ ! -f $ENV_FILE ]]; then
    die "$ENV_FILE is missing. Run: sudo $INSTALL_DIR/scripts/install.sh (it keeps your data)."
  fi
  if [[ ! -x $INSTALL_DIR/.venv/bin/python ]]; then
    die "The Python environment $INSTALL_DIR/.venv is missing. Run: sudo $INSTALL_DIR/scripts/install.sh"
  fi
  owner=$(stat -c %U "$INSTALL_DIR")
  SERVICE_USER=$(installed_unit_value User)
  SERVICE_USER=${SERVICE_USER:-$owner}
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    die "The service user '$SERVICE_USER' does not exist. Run: sudo $INSTALL_DIR/scripts/install.sh"
  fi
  SERVICE_HOME=$(getent passwd "$SERVICE_USER" | cut -d: -f6)
  if [[ $owner != "$SERVICE_USER" ]]; then
    info "Giving $INSTALL_DIR to $SERVICE_USER, which runs git and the services"
    chown -hR "$SERVICE_USER:$(id -gn "$SERVICE_USER")" "$INSTALL_DIR"
  fi
  if [[ -z $BRANCH ]]; then
    BRANCH=$(git_user symbolic-ref --quiet --short HEAD || true)
    BRANCH=${BRANCH:-main}
  fi
  OLD_HEAD=$(git_user rev-parse HEAD)
  RUNNING_HEAD=$(read_state running)
  RUNNING_HEAD=${RUNNING_HEAD:-$OLD_HEAD}
  MODAL_HEAD=$(read_state modal)
  ok "On branch $BRANCH at $(git_user log -1 --format='%h %s (%cs)')"
}

check_local_changes() {
  local changes
  changes=$(git_user status --porcelain --untracked-files=no)
  if [[ -z $changes ]]; then
    return 0
  fi
  if [[ $FORCE -eq 0 ]]; then
    printf '%s\n' "$changes" >&2
    die "The code in $INSTALL_DIR has local changes (listed above). Undo them, or run update.sh --force: it saves them (git stash and a .patch file), updates and puts them back."
  fi
  SAVE_CHANGES=1  # saved by pull_code right before the update, so a failed fetch changes nothing
}

save_local_changes() {
  local stamp backup_dir before
  stamp=$(date +%Y%m%d-%H%M%S)
  backup_dir="$(data_dir)/backups"
  LOCAL_PATCH="$backup_dir/local-changes-$stamp.patch"
  install -d -m 700 "$backup_dir"
  git_user diff HEAD >"$LOCAL_PATCH"
  chmod 600 "$LOCAL_PATCH"
  # Only changes to tracked files (what blocked the update); untracked files stay put.
  before=$(git_user rev-parse --verify --quiet refs/stash || true)
  git_user -c user.name="update.sh" -c user.email="update.sh@localhost" stash push --quiet -m "update.sh $stamp"
  STASH_COMMIT=$(git_user rev-parse --verify --quiet refs/stash || true)
  if [[ $STASH_COMMIT == "$before" ]]; then
    STASH_COMMIT=""  # nothing was stashed: never re-apply an older stash
  fi
  warn "Local changes saved: git stash 'update.sh $stamp' and $LOCAL_PATCH"
  info "See them with: sudo -u $SERVICE_USER git -C $INSTALL_DIR stash show -p"
}

restore_local_changes() {  # put the changes saved by --force back on top of the checked-out code
  local output
  if [[ -z $STASH_COMMIT ]]; then
    return 0
  fi
  if output=$(git_user stash apply "$STASH_COMMIT" 2>&1); then
    ok "Put your local changes back (a copy stays in git stash and $LOCAL_PATCH)"
  else
    printf '%s\n' "$output" | grep -E '^(CONFLICT|error|fatal)' >&2 || true  # which files clash
    # A clash leaves half-merged files behind: go back to the clean new version (the stash keeps the changes).
    git_user reset --quiet --hard HEAD
    warn "Your local changes clash with the new version, so they are NOT in use now (for example edits to config/*.yaml)."
    warn "Make them again by hand; they are kept in git stash and in $LOCAL_PATCH."
  fi
}

pull_code() {
  local current
  step "Fetching from GitHub (branch $BRANCH)"
  if ! git_user fetch --quiet --prune origin; then
    die "git fetch failed. Check the internet connection (and credentials, if the repository is private)."
  fi
  if ! git_user rev-parse --verify --quiet "refs/remotes/origin/$BRANCH" >/dev/null; then
    die "There is no branch '$BRANCH' on origin."
  fi
  if [[ $SAVE_CHANGES -eq 1 ]]; then
    save_local_changes
  fi
  current=$(git_user rev-parse --abbrev-ref HEAD)
  if [[ $current != "$BRANCH" ]]; then
    info "Switching from $current to $BRANCH"
    if git_user show-ref --verify --quiet "refs/heads/$BRANCH"; then
      git_user checkout --quiet "$BRANCH"
    else
      git_user checkout --quiet -b "$BRANCH" --track "origin/$BRANCH"
    fi
  fi
  if ! git_user merge --quiet --ff-only "origin/$BRANCH"; then
    restore_local_changes
    die "Cannot fast-forward to origin/$BRANCH: this checkout has commits that GitHub does not have. Look at: sudo -u $SERVICE_USER git -C $INSTALL_DIR log origin/$BRANCH..HEAD"
  fi
  NEW_HEAD=$(git_user rev-parse HEAD)
  # The files on disk changed (OLD_HEAD), or the services run another version (RUNNING_HEAD):
  # either way they need a restart.
  # shellcheck disable=SC2055  # || on purpose: a difference from either one counts
  if [[ $NEW_HEAD != "$RUNNING_HEAD" || $NEW_HEAD != "$OLD_HEAD" ]]; then
    CODE_CHANGED=1
  fi
  if [[ $OLD_HEAD != "$NEW_HEAD" ]]; then
    ok "Updated ${OLD_HEAD:0:12} -> ${NEW_HEAD:0:12} ($(git_user rev-list --count "$OLD_HEAD..$NEW_HEAD") new commit(s))"
  elif [[ $CODE_CHANGED -eq 1 ]]; then
    warn "The code is at ${NEW_HEAD:0:12} but the services last started on ${RUNNING_HEAD:0:12} (an earlier update did not finish); finishing it now."
  else
    ok "Already up to date (${NEW_HEAD:0:12})"
  fi
  restore_local_changes
}

install_requirements() {
  local gpu_requirements="$INSTALL_DIR/modal_app/requirements-gpu.txt" ohv_home
  step "Python packages"
  as_user "$INSTALL_DIR/.venv/bin/python" -m pip install --quiet --disable-pip-version-check -r "$INSTALL_DIR/requirements.txt"
  ok "requirements.txt installed"
  if [[ $(env_get "$ENV_FILE" SCOUT_PROCESSOR) != local ]]; then
    return 0
  fi
  if [[ -f $gpu_requirements ]] && changed_since "$RUNNING_HEAD" modal_app/requirements-gpu.txt; then
    info "modal_app/requirements-gpu.txt changed: updating the local GPU packages"
    GPU_UPDATED=1
    as_user "$INSTALL_DIR/.venv/bin/python" -m pip install --quiet --disable-pip-version-check -r "$gpu_requirements"
    ok "GPU packages installed"
  fi
  # ohv.py pins the OpenHoopVision commit (and its weights): check the new one out, as install.sh does.
  if changed_since "$RUNNING_HEAD" modal_app/pipeline/ohv.py; then
    ohv_home=$(env_get "$ENV_FILE" OHV_HOME)
    ohv_home=${ohv_home:-/opt/openhoopvision}
    info "modal_app/pipeline/ohv.py changed: updating OpenHoopVision in $ohv_home"
    OHV_UPDATED=$ohv_home
    as_user "$INSTALL_DIR/.venv/bin/python" -m modal_app.pipeline.ohv install --home "$ohv_home"
    ok "OpenHoopVision is at the pinned commit"
  fi
}

run_migrations() {
  step "Database migrations"
  as_user_with_env "$INSTALL_DIR/.venv/bin/python" -c "from scout import db; db.init_db()"
  ok "Database schema is up to date"
}

deploy_modal() {
  local processor
  local base=${MODAL_HEAD:-$RUNNING_HEAD}  # compare with what Modal runs, when we know it
  processor=$(env_get "$ENV_FILE" SCOUT_PROCESSOR)
  processor=${processor:-modal}
  case $DEPLOY_MODE in
    no)
      MODAL_SUMMARY="skipped (--no-deploy-modal)"
      if changed_since "$base" modal_app/; then
        warn "modal_app/ changed but --no-deploy-modal was given: deploy it before analysing new film."
      fi
      return 0
      ;;
    auto)
      if ! changed_since "$base" modal_app/; then
        return 0
      fi
      if [[ $processor != modal ]]; then
        MODAL_SUMMARY="not deployed (SCOUT_PROCESSOR=$processor)"
        return 0
      fi
      if ! modal_credentials_present; then
        MODAL_SUMMARY="NOT deployed: no Modal credentials"
        warn "modal_app/ changed, but there are no Modal credentials; deploy later with update.sh --deploy-modal."
        return 0
      fi
      ;;
    yes)
      if ! modal_credentials_present; then
        die "--deploy-modal needs Modal credentials: MODAL_TOKEN_ID/MODAL_TOKEN_SECRET in $ENV_FILE, or run: sudo -u $SERVICE_USER -H $INSTALL_DIR/.venv/bin/modal token new"
      fi
      ;;
  esac
  step "Deploying the GPU app to Modal"
  info "A rebuilt GPU image can take 10-20 minutes; otherwise this takes a minute or two."
  # --env: deploy into the environment the worker looks in, even if MODAL_ENVIRONMENT is not set.
  MODAL_ENV=$(env_get "$ENV_FILE" SCOUT_MODAL_ENVIRONMENT)
  as_user_with_env "$INSTALL_DIR/.venv/bin/modal" deploy ${MODAL_ENV:+--env "$MODAL_ENV"} modal_app/app.py
  record_state modal
  MODAL_DEPLOYED=1
  MODAL_SUMMARY="deployed"
  ok "GPU app deployed"
}

services_active() {
  systemctl is-active --quiet "$WEB_UNIT" && systemctl is-active --quiet "$WORKER_UNIT"
}

restart_services() {
  if [[ $SKIP_RESTART -eq 1 ]]; then
    warn "Not restarting (--skip-restart). When ready: sudo systemctl restart basketball-scout-web basketball-scout-worker"
    return 0
  fi
  if [[ ! -f $SYSTEMD_DIR/$WEB_UNIT ]]; then
    warn "The systemd services are not installed here; restart the web app and the worker yourself."
    return 0
  fi
  step "Restarting the services"
  if [[ $CODE_CHANGED -eq 0 ]] && services_active; then
    ok "Nothing new: the services keep running"
    return 0
  fi
  systemctl daemon-reload
  RESTARTED=1  # set first: a failed restart has stopped the old processes too
  systemctl restart "$WEB_UNIT" "$WORKER_UNIT"
  ok "Restarted $WEB_UNIT and $WORKER_UNIT"
  wait_for_health
  record_state running
}

wait_for_health() {
  local url deadline=$((SECONDS + HEALTH_TIMEOUT_S))
  url="http://127.0.0.1:$(web_port)/api/health/live"
  until curl -fsS --max-time 5 -o /dev/null "$url" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      systemctl --no-pager --lines=30 status "$WEB_UNIT" >&2 || true
      die "The web app did not answer on $url within $HEALTH_TIMEOUT_S seconds. Logs: journalctl -u basketball-scout-web -n 100"
    fi
    sleep 2
  done
  ok "Web app answers on $url"
  if systemctl is-active --quiet "$WORKER_UNIT"; then
    ok "Worker is running"
  else
    die "The worker did not start. Logs: journalctl -u basketball-scout-worker -n 100"
  fi
}

check_deploy_templates() {  # said before the restart, so the hint is there even when the restart fails
  if changed_since "$RUNNING_HEAD" deploy/; then
    warn "The systemd/nginx templates in deploy/ changed. Apply them with: sudo $INSTALL_DIR/scripts/install.sh (keeps your settings and data)."
  fi
}

print_notices() {
  local key key_re='^[[:space:]]*#?[[:space:]]*([A-Z][A-Z0-9_]*)=' line new_keys=""
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ $key_re ]]; then
      key=${BASH_REMATCH[1]}
      if ! grep -Eq "^[[:space:]]*#?[[:space:]]*$key=" "$ENV_FILE"; then
        new_keys="$new_keys $key"
      fi
    fi
  done <"$INSTALL_DIR/.env.example"
  if [[ -n $new_keys ]]; then
    info "New settings (their defaults apply until you set them):$new_keys"
    info "See .env.example; sudo $INSTALL_DIR/scripts/install.sh adds them to .env for you."
  fi
}

print_summary() {
  printf '\n%s======================================================================%s\n' "$C_GREEN" "$C_OFF"
  if [[ $RUNNING_HEAD == "$NEW_HEAD" ]]; then
    printf '%s  Basketball Scout is up to date (%s)%s\n' "$C_BOLD" "${NEW_HEAD:0:12}" "$C_OFF"
  else
    printf '%s  Basketball Scout updated: %s -> %s%s\n' "$C_BOLD" "${RUNNING_HEAD:0:12}" "${NEW_HEAD:0:12}" "$C_OFF"
  fi
  printf '%s======================================================================%s\n' "$C_GREEN" "$C_OFF"
  printf '  GPU app (Modal): %s\n' "$MODAL_SUMMARY"
  if [[ $RUNNING_HEAD != "$NEW_HEAD" ]]; then
    printf '\n  Changes since the version that was running (%s):\n' "${RUNNING_HEAD:0:12}"
    git_user log --no-decorate --format='    %h %s (%an, %cs)' --max-count=40 "$RUNNING_HEAD..$NEW_HEAD"
    printf '\n  Problems with the new version? To go back to %s:\n' "${RUNNING_HEAD:0:12}"
    print_rollback_commands
  fi
  printf '\n  Logs: journalctl -u basketball-scout-web -u basketball-scout-worker -f\n\n'
}

main() {
  setup_colors
  parse_args "$@"
  require_root
  trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
  check_checkout
  check_local_changes
  pull_code
  install_requirements
  run_migrations
  deploy_modal
  check_deploy_templates
  restart_services
  print_notices
  print_summary
}

# Run main unless the file is being sourced (tests do that). Do not source it yourself.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
