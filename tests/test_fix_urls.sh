#!/usr/bin/env bash

test_fix_urls_dry_run_prints_plan_and_runs_no_wp() {
  run_script fix-urls.sh --dry-run --old https://old.example.com --new https://new.example.com
  assert_rc 0
  assert_contains "search-replace"
  assert_contains "--dry-run"
  assert_log_lacks "search-replace"
}

test_fix_urls_includes_json_escaped_variant_for_elementor() {
  run_script fix-urls.sh --dry-run --old https://old.example.com --new https://new.example.com
  assert_contains 'https:\\/\\/old.example.com'
}

test_fix_urls_adds_http_and_protocol_relative_variants() {
  run_script fix-urls.sh --dry-run --old https://old.example.com --new https://new.example.com
  assert_contains "http://old.example.com"
  assert_contains "//old.example.com //new.example.com"
}

test_fix_urls_no_variants_flag() {
  run_script fix-urls.sh --dry-run --no-variants --old https://old.example.com --new https://new.example.com
  assert_contains "(2 patterns)"
}

test_fix_urls_defaults_come_from_env() {
  echo "DST_URL=https://new.example.com" >>"$T/migrate.env"
  run_script fix-urls.sh --dry-run
  assert_contains "https://www.example.com -> https://new.example.com"
}

test_fix_urls_dry_run_pass_precedes_apply() {
  SHIM_ELEMENTOR=1 run_script fix-urls.sh --yes --old https://old.example.com --new https://new.example.com
  assert_rc 0
  local first
  first=$(grep -n 'search-replace' "$SHIM_LOG" | head -n 1)
  case "$first" in
    *"--dry-run"*) ;;
    *) fail_test "first search-replace was not a dry run: $first" ;;
  esac
  grep 'search-replace' "$SHIM_LOG" | grep -v -q -- '--dry-run' || fail_test "no applying search-replace"
}

test_fix_urls_skips_guid_and_uses_all_tables_with_prefix() {
  run_script fix-urls.sh --yes --old https://old.example.com --new https://new.example.com
  assert_log_contains "--skip-columns=guid"
  assert_log_contains "--all-tables-with-prefix"
}

test_fix_urls_requires_confirmation_without_tty() {
  run_script fix-urls.sh --old https://old.example.com --new https://new.example.com </dev/null
  assert_rc 1
  assert_contains "--yes"
  local applied
  applied=$(grep 'search-replace' "$SHIM_LOG" | grep -vc -- '--dry-run' || true)
  assert_eq "$applied" "0"
}

test_fix_urls_flushes_elementor_when_active() {
  SHIM_ELEMENTOR=1 run_script fix-urls.sh --yes --old https://old.example.com --new https://new.example.com
  assert_log_contains "elementor flush-css"
  assert_log_contains "cache flush"
  assert_log_contains "transient delete --all"
  assert_log_contains "rewrite flush"
}

test_fix_urls_skips_elementor_flush_when_inactive() {
  run_script fix-urls.sh --yes --old https://old.example.com --new https://new.example.com
  assert_log_lacks "elementor flush-css"
  assert_log_contains "cache flush"
}

test_fix_urls_skip_flush_flag() {
  run_script fix-urls.sh --yes --skip-flush --old https://old.example.com --new https://new.example.com
  assert_log_lacks "cache flush"
}

test_fix_urls_rejects_missing_scheme() {
  run_script fix-urls.sh --old old.example.com --new new.example.com
  assert_rc 2
  assert_contains "must include a scheme"
}

test_fix_urls_rejects_identical_urls() {
  run_script fix-urls.sh --old https://a.example.com --new https://a.example.com/
  assert_rc 0
  assert_contains "identical"
  assert_log_lacks "search-replace"
}

test_fix_urls_warns_when_home_option_mismatch() {
  SHIM_HOME=https://wrong.example.com run_script fix-urls.sh --yes --old https://old.example.com --new https://new.example.com
  assert_contains "home is 'https://wrong.example.com'"
}

test_fix_urls_option_requires_value() {
  run_script fix-urls.sh --old
  assert_rc 2
}
