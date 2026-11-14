#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are read by functions in lib/common.sh under test
# Tests for lib/common.sh helpers and shared CLI behaviour.

test_help_flag_exits_zero_for_every_script() {
  local s
  for s in preflight.sh pull-files.sh pull-db.sh fix-urls.sh compare.sh verify.sh; do
    run_raw "$s" --help
    assert_rc 0
    assert_contains "Usage:"
    assert_contains "--dry-run"
  done
}

test_unknown_option_is_a_usage_error() {
  local s
  for s in preflight.sh pull-files.sh pull-db.sh fix-urls.sh compare.sh verify.sh; do
    run_script "$s" --bogus
    assert_rc 2
    assert_contains "Unknown option: --bogus"
  done
}

test_version_flag() {
  run_raw preflight.sh --version
  assert_rc 0
  assert_contains "wp-vps-migration-toolkit 0."
}

test_missing_config_file_fails() {
  run_raw preflight.sh --env "$T/nope.env"
  assert_rc 1
  assert_contains "Config file not readable"
}

test_env_option_requires_argument() {
  run_raw preflight.sh --env
  assert_rc 2
  assert_contains "--env needs a file"
}

test_missing_required_setting_is_reported() {
  : >"$T/empty.env"
  run_raw pull-files.sh --env "$T/empty.env" --dry-run
  assert_rc 1
  assert_contains "Required setting SRC_SSH_HOST is empty"
}

test_ver_num_orders_versions() {
  # shellcheck source=/dev/null
  . "$ROOT/lib/common.sh"
  [ "$(ver_num 8.1.2)" -gt "$(ver_num 7.4.33)" ]
  [ "$(ver_num 8.10.0)" -gt "$(ver_num 8.2.0)" ]
  assert_eq "$(ver_num 7.4)" "7004"
}

test_url_helpers() {
  # shellcheck source=/dev/null
  . "$ROOT/lib/common.sh"
  assert_eq "$(url_host https://www.example.com:8443/blog)" "www.example.com"
  assert_eq "$(url_scheme http://example.com)" "http"
  assert_eq "$(url_strip_slash https://example.com/)" "https://example.com"
}

test_quote_cmd_escapes_spaces() {
  # shellcheck source=/dev/null
  . "$ROOT/lib/common.sh"
  assert_eq "$(quote_cmd echo 'a b')" 'echo a\ b'
}

test_run_honours_dry_run() {
  # shellcheck source=/dev/null
  . "$ROOT/lib/common.sh"
  DRY_RUN=1
  run touch "$T/should-not-exist" 2>/dev/null
  assert_no_file "$T/should-not-exist"
  DRY_RUN=0
  run touch "$T/exists"
  assert_file "$T/exists"
}

test_sha256_of_matches_known_value() {
  # shellcheck source=/dev/null
  . "$ROOT/lib/common.sh"
  printf 'abc' >"$T/f"
  assert_eq "$(sha256_of "$T/f")" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
}

test_confirm_refuses_without_tty_or_yes() {
  # shellcheck source=/dev/null
  . "$ROOT/lib/common.sh"
  if (confirm "ok?" </dev/null) 2>/dev/null; then
    fail_test "confirm should fail without a tty"
  fi
  ASSUME_YES=1
  confirm "ok?"
}

test_env_file_values_and_defaults_load() {
  # shellcheck source=/dev/null
  . "$ROOT/lib/common.sh"
  ENV_FILE="$T/migrate.env"
  load_config 2>/dev/null
  assert_eq "$SRC_SSH_HOST" "old-host.example.com"
  assert_eq "$RSYNC_RETRIES" "5"
  assert_eq "$SRC_SSH_STRICT" "accept-new"
}
