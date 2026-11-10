#!/usr/bin/env bash

test_pull_files_dry_run_does_not_call_rsync() {
  run_script pull-files.sh --dry-run
  assert_rc 0
  assert_contains "DRY-RUN"
  assert_contains "rsync"
  assert_log_lacks "rsync "
}

test_pull_files_builds_expected_rsync_command() {
  run_script pull-files.sh
  assert_rc 0
  assert_log_contains "--partial"
  assert_log_contains "--partial-dir=.rsync-partial"
  assert_log_contains "--exclude=/wp-config.php"
  assert_log_contains "--exclude=/.htaccess"
  assert_log_contains "--exclude-from=$ROOT/config/rsync-excludes.txt"
  assert_log_contains "cpaneluser@old-host.example.com:/home/cpaneluser/public_html/ $T/site/"
  assert_log_contains "-p 2222"
}

test_pull_files_with_wp_config_drops_exclusion() {
  run_script pull-files.sh --with-wp-config --with-htaccess
  assert_rc 0
  assert_log_lacks "--exclude=/wp-config.php"
  assert_log_lacks "--exclude=/.htaccess"
}

test_pull_files_delete_requires_yes_without_tty() {
  run_script pull-files.sh --delete </dev/null
  assert_rc 1
  assert_contains "--yes"
  assert_log_lacks "rsync "
}

test_pull_files_delete_with_yes_uses_delete_after() {
  run_script pull-files.sh --delete --yes
  assert_rc 0
  assert_log_contains "--delete-after"
}

test_pull_files_only_limits_subpath() {
  mkdir -p "$T/site/wp-content/uploads"
  run_script pull-files.sh --only wp-content/uploads
  assert_rc 0
  assert_log_contains "public_html/wp-content/uploads/ $T/site/wp-content/uploads/"
}

test_pull_files_rejects_path_traversal() {
  run_script pull-files.sh --only ../etc
  assert_rc 2
  assert_contains "must not contain"
}

test_pull_files_retries_transient_failures_then_succeeds() {
  SHIM_RSYNC_RCS="30 255 0" run_script pull-files.sh
  assert_rc 0
  assert_contains "rsync attempt 3/5"
  assert_contains "File sync complete"
}

test_pull_files_gives_up_after_max_retries() {
  SHIM_RSYNC_RCS="30 30 30" RSYNC_RETRIES=3 run_script pull-files.sh
  assert_rc 1
  assert_contains "after 3 attempts"
}

test_pull_files_does_not_retry_permission_errors() {
  SHIM_RSYNC_RCS="23 0" run_script pull-files.sh
  assert_rc 1
  assert_not_contains "attempt 2"
}

test_pull_files_treats_vanished_files_as_success() {
  SHIM_RSYNC_RCS="24" run_script pull-files.sh
  assert_rc 0
  assert_contains "vanished"
}

test_pull_files_extra_excludes_and_bwlimit() {
  RSYNC_EXTRA_EXCLUDES="big-videos tmp-export" run_script pull-files.sh --bwlimit 5000
  assert_rc 0
  assert_log_contains "--exclude=big-videos"
  assert_log_contains "--exclude=tmp-export"
  assert_log_contains "--bwlimit=5000"
}

test_pull_files_chowns_when_owner_configured() {
  echo "DST_OWNER=nobody:nobody" >>"$T/migrate.env"
  run_script pull-files.sh --dry-run
  assert_contains "chown -R nobody:nobody"
}

test_excludes_file_covers_caches_and_backups() {
  local f="$ROOT/config/rsync-excludes.txt"
  grep -q 'wp-content/cache/' "$f"
  grep -q 'updraft' "$f"
  grep -q 'ai1wm-backups' "$f"
  grep -q 'error_log' "$f"
}
