#!/usr/bin/env bash

test_preflight_dry_run_prints_remote_commands_and_runs_none() {
  run_script preflight.sh --dry-run
  assert_rc 0
  assert_contains "DRY-RUN"
  assert_contains "Dry run finished"
  assert_log_lacks "ssh -p"
}

test_preflight_passes_with_healthy_hosts() {
  run_script preflight.sh
  assert_rc 0
  assert_contains "SSH access to cpaneluser@old-host.example.com:2222"
  assert_contains "source PHP CLI: 7.4.33"
  assert_contains "database size: 85 MB"
  assert_contains "0 failed"
}

test_preflight_uses_port_and_batch_mode() {
  run_script preflight.sh
  assert_log_contains "-p 2222"
  assert_log_contains "BatchMode=yes"
}

test_preflight_flags_cache_backup_and_server_bound_plugins() {
  run_script preflight.sh
  assert_contains "cache plugin 'wp-rocket'"
  assert_contains "backup plugin 'updraftplus'"
  assert_contains "server-bound plugin 'wordfence'"
  assert_not_contains "plugin 'akismet'"
}

test_preflight_lists_cache_paths() {
  run_script preflight.sh
  assert_contains "wp-content/uploads/elementor/css present"
  assert_contains "wp-content/object-cache.php present"
}

test_preflight_fails_when_ssh_is_down() {
  SHIM_SSH_FAIL=1 run_script preflight.sh
  assert_rc 1
  assert_contains "cannot SSH"
}

test_preflight_fails_when_disk_too_small() {
  SHIM_FREE_MB=100 run_script preflight.sh
  assert_rc 1
  assert_contains "not enough free disk"
}

test_preflight_warns_on_php_downgrade() {
  SHIM_SRC_PHP=8.2.5 SHIM_DST_PHP=7.4.1 run_script preflight.sh
  assert_contains "older than source"
}

test_preflight_warns_on_php7_to_php8_jump() {
  SHIM_SRC_PHP=7.4.33 SHIM_DST_PHP=8.3.0 run_script preflight.sh
  assert_contains "PHP 7.x -> 8.x jump"
}

test_preflight_fails_when_target_php_below_minimum() {
  SHIM_DST_PHP=7.2.0 run_script preflight.sh
  assert_rc 1
  assert_contains "older than MIN_TARGET_PHP"
}

test_preflight_warns_when_source_has_no_wp_cli() {
  SHIM_NO_SRC_WP=1 run_script preflight.sh
  assert_contains "WP-CLI missing on source"
}
