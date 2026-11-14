#!/usr/bin/env bash
# Tests for compare.sh. Source answers come from the ssh shim (SHIM_SRC_*),
# target answers from the wp shim (SHIM_DST_*); defaults match on both ends.

# make_uploads N - N regular files in the target uploads plus pruned debris.
make_uploads() {
  local i up="$T/site/wp-content/uploads"
  mkdir -p "$up/2026/01" "$up/elementor/css" "$up/cache"
  i=0
  while [ "$i" -lt "$1" ]; do
    i=$((i + 1))
    : >"$up/2026/01/img-$i.jpg"
  done
  : >"$up/elementor/css/post-1.css"
  : >"$up/cache/page.html"
  : >"$up/error_log"
}

test_compare_dry_run_runs_nothing() {
  run_script compare.sh --dry-run
  assert_rc 0
  assert_contains "DRY-RUN"
  assert_contains "core version"
  assert_contains "GROUP\\ BY\\ post_type"
  assert_contains "Dry run finished"
  assert_log_lacks "ssh "
  assert_log_lacks "wp "
  assert_no_file "$T/work/reports"
}

test_compare_passes_when_sites_match() {
  make_uploads 3
  run_script compare.sh
  assert_rc 0
  assert_contains "WordPress core: '6.6.2' on both"
  assert_contains "active theme: 'astra' on both"
  assert_contains "active plugins match (5)"
  assert_contains "table prefix: 'wp_' on both"
  assert_contains "posts post: 40 on both"
  assert_contains "terms post_tag: 9 on both"
  assert_contains "comments: 12 on both"
  assert_contains "users: 2 on both"
  assert_contains "upload files: 3 on both"
  assert_contains "0 failed"
}

test_compare_uses_source_prefix_in_queries() {
  make_uploads 3
  SHIM_SRC_PREFIX=wpx_ SHIM_DST_PREFIX=wpx_ run_script compare.sh
  assert_rc 0
  assert_log_contains "FROM\\ wpx_posts"
  assert_log_contains "FROM wpx_users"
}

test_compare_fails_on_missing_posts() {
  make_uploads 3
  SHIM_DST_POSTS="attachment:3 page:5 post:31" run_script compare.sh
  assert_rc 1
  assert_contains "posts post: target is missing 9 (40 -> 31)"
}

test_compare_fails_on_post_type_absent_on_target() {
  make_uploads 3
  SHIM_SRC_POSTS="page:5 post:40 product:7" SHIM_DST_POSTS="page:5 post:40" run_script compare.sh
  assert_rc 1
  assert_contains "posts product: target is missing 7 (7 -> 0)"
}

test_compare_tolerance_turns_small_gaps_into_warnings() {
  make_uploads 3
  SHIM_SRC_COMMENTS=100 SHIM_DST_COMMENTS=96 run_script compare.sh --tolerance 5
  assert_rc 0
  assert_contains "comments: target has 4 fewer (100 -> 96), within 5% tolerance"
  SHIM_SRC_COMMENTS=100 SHIM_DST_COMMENTS=94 run_script compare.sh --tolerance 5
  assert_rc 1
  assert_contains "comments: target is missing 6"
}

test_compare_tolerance_from_env() {
  make_uploads 3
  echo 'COMPARE_TOLERANCE=10' >>"$T/migrate.env"
  SHIM_SRC_USERS=20 SHIM_DST_USERS=19 run_script compare.sh
  assert_rc 0
  assert_contains "within 10% tolerance"
}

test_compare_more_on_target_is_a_warning() {
  make_uploads 3
  SHIM_DST_USERS=3 run_script compare.sh
  assert_rc 0
  assert_contains "users: target has more (2 -> 3)"
}

test_compare_plugin_missing_on_target_fails() {
  make_uploads 3
  SHIM_DST_PLUGINS="elementor akismet wordfence wp-rocket jetpack" run_script compare.sh
  assert_rc 1
  assert_contains "active on source but not on target: updraftplus"
  assert_contains "active on target only: jetpack"
}

test_compare_theme_and_permalink_mismatch_fail() {
  make_uploads 3
  SHIM_DST_THEME=twentytwentyfour SHIM_DST_PERMALINK="" run_script compare.sh
  assert_rc 1
  assert_contains "active theme differs: source 'astra', target 'twentytwentyfour'"
  assert_contains "permalink structure differs: source '/%postname%/', target ''"
}

test_compare_core_version_mismatch_only_warns() {
  make_uploads 3
  SHIM_DST_CORE=6.7.1 run_script compare.sh
  assert_rc 0
  assert_contains "WordPress core differs: source '6.6.2', target '6.7.1'"
}

test_compare_prefix_mismatch_fails_with_hint() {
  make_uploads 3
  SHIM_DST_PREFIX=wpnew_ run_script compare.sh
  assert_rc 1
  assert_contains "table prefix differs: source 'wp_', target 'wpnew_'"
  assert_contains "table_prefix = 'wp_'"
}

test_compare_rejects_unsafe_prefix() {
  make_uploads 3
  SHIM_SRC_PREFIX='wp_;DROP' SHIM_DST_PREFIX='wp_;DROP' run_script compare.sh
  assert_rc 1
  assert_contains "unusable table prefix"
  assert_log_lacks "DROPposts"
}

test_compare_unreachable_target_wp_fails_and_skips_db() {
  make_uploads 3
  SHIM_DST_CORE="" run_script compare.sh
  assert_rc 1
  assert_contains "WP-CLI could not read the target site"
  assert_log_lacks "theme list"
  assert_contains "upload files: 3 on both"
}

test_compare_uploads_missing_files_fails_and_prunes_excludes() {
  make_uploads 2
  run_script compare.sh --skip-wp
  assert_rc 1
  assert_contains "upload files: target is missing 1 (3 -> 2)"
  assert_contains "WP-CLI comparisons (--skip-wp)"
  assert_log_contains "-path /home/cpaneluser/public_html/wp-content/uploads/elementor/css"
}

test_compare_extra_excludes_are_pruned_on_both_ends() {
  make_uploads 3
  mkdir -p "$T/site/wp-content/uploads/large-videos"
  : >"$T/site/wp-content/uploads/large-videos/a.mp4"
  echo 'RSYNC_EXTRA_EXCLUDES="/wp-content/uploads/large-videos/ wp-content/plugins/x"' >>"$T/migrate.env"
  run_script compare.sh --skip-wp
  assert_rc 0
  assert_contains "upload files: 3 on both"
  assert_log_contains "uploads/large-videos"
  assert_log_lacks "plugins/x"
}

test_compare_no_uploads_anywhere_is_skipped() {
  SHIM_SRC_UPLOADS=none run_script compare.sh --skip-wp
  assert_rc 0
  assert_contains "no wp-content/uploads on either site"
}

test_compare_writes_tsv_report() {
  make_uploads 3
  SHIM_DST_COMMENTS=10 run_script compare.sh --report "$T/report.tsv"
  assert_rc 1
  assert_file "$T/report.tsv"
  assert_eq "$(head -n 1 "$T/report.tsv")" "$(printf 'check\tsource\ttarget\tresult')"
  grep -q "$(printf '^comments\t12\t10\tFAIL$')" "$T/report.tsv" || fail_test "report lacks comments row"
  grep -q "$(printf '^posts post\t40\t40\tPASS$')" "$T/report.tsv" || fail_test "report lacks posts row"
}

test_compare_default_report_goes_to_work_dir() {
  make_uploads 3
  run_script compare.sh
  assert_rc 0
  assert_contains "Report written to $T/work/reports/compare-"
  ls "$T"/work/reports/compare-*.tsv >/dev/null 2>&1 || fail_test "no report in work/reports"
}

test_compare_validates_options() {
  run_script compare.sh --tolerance abc
  assert_rc 2
  assert_contains "whole percentage"
  run_script compare.sh --tolerance 150
  assert_rc 2
  assert_contains "between 0 and 100"
  run_script compare.sh --skip-wp --skip-files
  assert_rc 2
  assert_contains "nothing to compare"
  run_script compare.sh --report
  assert_rc 2
}

test_compare_ssh_down_fails() {
  SHIM_SSH_FAIL=1 run_script compare.sh --skip-files
  assert_rc 1
  assert_contains "WP-CLI could not read the source site"
}
