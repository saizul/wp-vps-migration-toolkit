#!/usr/bin/env bash
# Minimal test helpers (bats-free). Source from test files.
# shellcheck shell=bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIMS="$ROOT/tests/shims"

# setup_env: fresh sandbox with PATH shims and a config file.
setup_env() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/wpvm-test.XXXXXX")
  export SHIM_LOG="$T/shim.log"
  export SHIM_STATE="$T"
  : >"$SHIM_LOG"
  mkdir -p "$T/site/wp-content"
  cat >"$T/migrate.env" <<ENV
SRC_SSH_HOST=old-host.example.com
SRC_SSH_USER=cpaneluser
SRC_SSH_PORT=2222
SRC_WP_PATH=/home/cpaneluser/public_html
SRC_URL=https://www.example.com
DST_WP_PATH=$T/site
DST_URL=https://www.example.com
DST_IP=203.0.113.10
WORK_DIR=$T/work
RSYNC_RETRY_SLEEP=0
ENV
  export PATH="$SHIMS:$PATH"
  cd "$T"
}

teardown_env() {
  cd /
  rm -rf "$T"
}

# run_script NAME ARGS... : capture stdout+stderr in $OUT and status in $RC.
run_script() {
  local name=$1
  shift
  set +e
  OUT=$(NO_COLOR=1 bash "$ROOT/$name" --env "$T/migrate.env" "$@" 2>&1)
  RC=$?
  set -e
}

# run_raw NAME ARGS... : no implicit --env.
run_raw() {
  local name=$1
  shift
  set +e
  OUT=$(NO_COLOR=1 bash "$ROOT/$name" "$@" 2>&1)
  RC=$?
  set -e
}

fail_test() {
  printf '    assertion failed: %s\n' "$*" >&2
  printf '    --- output ---\n%s\n    --------------\n' "${OUT:-}" >&2
  return 1
}

assert_rc() {
  [ "$RC" -eq "$1" ] || fail_test "expected exit $1, got $RC"
}

assert_contains() {
  case "$OUT" in
    *"$1"*) ;;
    *) fail_test "output does not contain: $1" ;;
  esac
}

assert_not_contains() {
  case "$OUT" in
    *"$1"*) fail_test "output unexpectedly contains: $1" ;;
  esac
}

assert_log_contains() {
  grep -q -F -- "$1" "$SHIM_LOG" || fail_test "shim log lacks: $1"
}

assert_log_lacks() {
  if grep -q -F -- "$1" "$SHIM_LOG"; then
    fail_test "shim log unexpectedly has: $1"
  fi
}

assert_file() { [ -f "$1" ] || fail_test "missing file: $1"; }
assert_no_file() { [ ! -e "$1" ] || fail_test "unexpected file: $1"; }
assert_eq() { [ "$1" = "$2" ] || fail_test "expected '$2', got '$1'"; }
