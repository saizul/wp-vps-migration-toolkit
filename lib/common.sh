#!/usr/bin/env bash
# lib/common.sh - helpers shared by every script in wp-vps-migration-toolkit.
# Source this file; do not execute it. Compatible with bash 3.2+.
# shellcheck shell=bash

if [ -n "${WPVM_COMMON_LOADED:-}" ]; then
  return 0
fi
WPVM_COMMON_LOADED=1

WPVM_VERSION="0.1.0"
WPVM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DRY_RUN=0
VERBOSE=0
ASSUME_YES=0
ENV_FILE=""
COMMON_SHIFT=1
SCRIPT_NAME="$(basename "${0:-script}")"
SSH_OPTS=()
PASS_N=0
WARN_N=0
FAIL_N=0

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_OFF=$'\033[0m'
else
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_OFF=""
fi

# ---------------------------------------------------------------- logging

_log() {
  local level=$1 color=$2
  shift 2
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  printf '%s %s[%s]%s %s\n' "$ts" "$color" "$level" "$C_OFF" "$*" >&2
  if [ -n "${LOG_FILE:-}" ]; then
    printf '%s [%s] %s\n' "$ts" "$level" "$*" >>"$LOG_FILE"
  fi
}

log_info() { _log INFO "$C_BLUE" "$@"; }
log_ok() { _log OK "$C_GREEN" "$@"; }
log_warn() { _log WARN "$C_YELLOW" "$@"; }
log_error() { _log ERROR "$C_RED" "$@"; }
log_debug() {
  if [ "$VERBOSE" = 1 ]; then
    _log DEBUG "" "$@"
  fi
}
log_dry() { _log DRY-RUN "$C_YELLOW" "$@"; }

die() {
  log_error "$@"
  exit 1
}

# die_usage MESSAGE - prints message plus usage() (defined by the caller), exit 2.
die_usage() {
  log_error "$@"
  if declare -F usage >/dev/null 2>&1; then
    usage >&2
  fi
  exit 2
}

is_dry() { [ "$DRY_RUN" = 1 ]; }

# ------------------------------------------------------- check bookkeeping

pass() {
  PASS_N=$((PASS_N + 1))
  _log PASS "$C_GREEN" "$@"
}
warn() {
  WARN_N=$((WARN_N + 1))
  _log WARN "$C_YELLOW" "$@"
}
fail() {
  FAIL_N=$((FAIL_N + 1))
  _log FAIL "$C_RED" "$@"
}
skip() { _log SKIP "$C_YELLOW" "$@"; }

summary() {
  log_info "Summary: ${PASS_N} passed, ${WARN_N} warnings, ${FAIL_N} failed"
  [ "$FAIL_N" -eq 0 ]
}

# --------------------------------------------------------------- arguments

# common_flag ARGS... - handle flags every script understands.
# Returns 0 and sets COMMON_SHIFT (1 or 2) when $1 was recognised, else 1.
common_flag() {
  case "${1:-}" in
    -n | --dry-run)
      DRY_RUN=1
      COMMON_SHIFT=1
      ;;
    -v | --verbose)
      VERBOSE=1
      COMMON_SHIFT=1
      ;;
    -y | --yes)
      ASSUME_YES=1
      COMMON_SHIFT=1
      ;;
    --env)
      [ $# -ge 2 ] || die_usage "--env needs a file argument"
      ENV_FILE=$2
      # shellcheck disable=SC2034  # read by the sourcing script after parse_common_args
      COMMON_SHIFT=2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --version)
      echo "wp-vps-migration-toolkit $WPVM_VERSION"
      exit 0
      ;;
    *) return 1 ;;
  esac
  return 0
}

# ------------------------------------------------------------------ config

load_config() {
  local f="$ENV_FILE"
  if [ -z "$f" ]; then
    if [ -n "${MIGRATE_ENV:-}" ]; then
      f=$MIGRATE_ENV
    elif [ -f ./migrate.env ]; then
      f=./migrate.env
    elif [ -f "$WPVM_ROOT/migrate.env" ]; then
      f="$WPVM_ROOT/migrate.env"
    fi
  fi
  if [ -n "$f" ]; then
    [ -r "$f" ] || die "Config file not readable: $f"
    log_debug "Loading config $f"
    set -a
    # shellcheck source=/dev/null
    . "$f"
    set +a
  else
    log_warn "No migrate.env found (copy migrate.env.example); using environment only"
  fi
  : "${SRC_SSH_PORT:=22}"
  : "${SRC_SSH_STRICT:=accept-new}"
  : "${SSH_CONNECT_TIMEOUT:=10}"
  : "${WORK_DIR:=$WPVM_ROOT/work}"
  : "${WP_CLI:=wp}"
  : "${SRC_WP_CLI:=wp}"
  : "${WP_CLI_ARGS:=}"
  : "${SRC_WP_CLI_ARGS:=}"
  : "${PHP_BIN:=php}"
  : "${RSYNC_RETRIES:=5}"
  : "${RSYNC_RETRY_SLEEP:=5}"
  : "${RSYNC_EXTRA_EXCLUDES:=}"
  : "${MIN_TARGET_PHP:=7.4}"
  : "${VERIFY_INSECURE:=1}"
  : "${VERIFY_EXTRA_URLS:=}"
}

require_var() {
  local v
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then
      die "Required setting $v is empty. Set it in migrate.env."
    fi
  done
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
  done
}

# ---------------------------------------------------------------- execution

quote_cmd() {
  local out="" a
  for a in "$@"; do
    out="$out$(printf '%q ' "$a")"
  done
  printf '%s' "${out% }"
}

# run CMD ARGS... - execute, or just print under --dry-run.
run() {
  if is_dry; then
    log_dry "$(quote_cmd "$@")"
    return 0
  fi
  log_debug "exec: $(quote_cmd "$@")"
  "$@"
}

confirm() {
  local prompt=$1 reply
  if [ "$ASSUME_YES" = 1 ] || is_dry; then
    return 0
  fi
  if [ ! -t 0 ]; then
    die "$prompt - refusing to continue without a terminal; re-run with --yes"
  fi
  printf '%s [y/N] ' "$prompt" >&2
  read -r reply
  case "$reply" in
    y | Y | yes | YES) return 0 ;;
    *) die "Aborted by user" ;;
  esac
}

# ---------------------------------------------------------------------- ssh

build_ssh_opts() {
  SSH_OPTS=(-p "$SRC_SSH_PORT" -o BatchMode=yes
    -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT"
    -o "StrictHostKeyChecking=$SRC_SSH_STRICT"
    -o ServerAliveInterval=30)
  if [ -n "${SRC_SSH_KEY:-}" ]; then
    SSH_OPTS=("${SSH_OPTS[@]}" -i "$SRC_SSH_KEY")
  fi
}

# src_ssh REMOTE_COMMAND - run a command on the source host (read-only use).
src_ssh() {
    require_var SRC_SSH_HOST SRC_SSH_USER
  build_ssh_opts
  # shellcheck disable=SC2153  # SRC_SSH_HOST comes from the env file
  local target="$SRC_SSH_USER@$SRC_SSH_HOST"
  if is_dry; then
    log_dry "ssh ${SSH_OPTS[*]} $target $*"
    return 0
  fi
  log_debug "ssh $target $*"
  # shellcheck disable=SC2029  # the remote command is intentionally expanded locally
  ssh "${SSH_OPTS[@]}" "$target" "$@"
}

# quote_args ARGS... - shell-quote for embedding in a remote command string.
quote_args() {
  local out="" a
  for a in "$@"; do
    out="$out$(printf '%q ' "$a")"
  done
  printf '%s' "${out% }"
}

# src_wp WP_ARGS... - run WP-CLI against the source site.
src_wp() {
  src_ssh "$(quote_args "$SRC_WP_CLI") --path=$(printf '%q' "$SRC_WP_PATH") ${SRC_WP_CLI_ARGS} $(quote_args "$@")"
}

# dst_wp WP_ARGS... - run WP-CLI against the local (target) site.
dst_wp() {
  local extra=()
  if [ -n "$WP_CLI_ARGS" ]; then
    read -r -a extra <<<"$WP_CLI_ARGS"
  fi
  if is_dry; then
    log_dry "$(quote_cmd "$WP_CLI" "--path=$DST_WP_PATH" ${extra[@]+"${extra[@]}"} "$@")"
    return 0
  fi
  log_debug "wp --path=$DST_WP_PATH $*"
  "$WP_CLI" "--path=$DST_WP_PATH" ${extra[@]+"${extra[@]}"} "$@"
}

# ------------------------------------------------------------------ helpers

timestamp() { date '+%Y%m%d-%H%M%S'; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

url_scheme() { printf '%s' "${1%%://*}"; }
url_host() {
  local u=${1#*://}
  u=${u%%/*}
  printf '%s' "${u%%:*}"
}
url_strip_slash() { printf '%s' "${1%/}"; }

# ver_major_minor 8.1.2 -> 8001 (comparable integer)
ver_num() {
  local v=$1 major minor
  major=${v%%.*}
  minor=${v#*.}
  minor=${minor%%.*}
  printf '%d' $((10#${major:-0} * 1000 + 10#${minor:-0}))
}

init_logging() {
  if is_dry; then
    return 0
  fi
  mkdir -p "$WORK_DIR/logs"
  LOG_FILE="$WORK_DIR/logs/${SCRIPT_NAME%.sh}-$(timestamp).log"
  export LOG_FILE
}
