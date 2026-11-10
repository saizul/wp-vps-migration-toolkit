#!/usr/bin/env bash

test_pull_db_dry_run_creates_nothing() {
  run_script pull-db.sh --dry-run --export-only
  assert_rc 0
  assert_contains "mysqldump --single-transaction"
  assert_no_file "$T/work/db"
  assert_log_lacks "ssh "
}

test_pull_db_export_creates_verified_dump_and_checksum() {
  run_script pull-db.sh --export-only
  assert_rc 0
  assert_contains "Dump saved"
  local dump
  dump=$(ls "$T"/work/db/*.sql.gz)
  assert_file "$dump"
  assert_file "$dump.sha256"
  gzip -t "$dump"
  assert_no_file "$dump.part"
  grep -q "$(basename "$dump")" "$dump.sha256"
}

test_pull_db_export_rejects_truncated_dump() {
  SHIM_DUMP_BAD=1 run_script pull-db.sh --export-only
  assert_rc 1
  assert_contains "truncated"
  [ -z "$(ls "$T"/work/db 2>/dev/null)" ] || fail_test "partial dump left behind"
}

test_pull_db_export_fails_when_ssh_fails() {
  SHIM_SSH_FAIL=1 run_script pull-db.sh --export-only
  assert_rc 1
  assert_contains "Remote dump failed"
}

test_pull_db_remote_command_uses_wp_config_not_cli_passwords() {
  run_script pull-db.sh --export-only
  assert_log_contains "--single-transaction"
  assert_log_contains "MYSQL_PWD"
  assert_log_lacks "-p'"
}

test_pull_db_import_requires_confirmation_without_tty() {
  run_script pull-db.sh --export-only
  run_script pull-db.sh --import-only </dev/null
  assert_rc 1
  assert_contains "--yes"
  assert_log_lacks "db import"
}

test_pull_db_full_cycle_backs_up_then_imports() {
  touch "$T/site/wp-config.php"
  run_script pull-db.sh --yes
  assert_rc 0
  assert_log_contains "db export $T/work/db/pre-import-"
  assert_log_contains "db import -"
  assert_contains "Import complete"
}

test_pull_db_import_detects_checksum_mismatch() {
  touch "$T/site/wp-config.php"
  run_script pull-db.sh --export-only
  local dump
  dump=$(ls "$T"/work/db/*.sql.gz)
  echo "deadbeef  x" >"$dump.sha256"
  run_script pull-db.sh --import-only --yes
  assert_rc 1
  assert_contains "Checksum mismatch"
}

test_pull_db_import_rejects_corrupt_gzip() {
  touch "$T/site/wp-config.php"
  mkdir -p "$T/work/db"
  echo "not gzip" >"$T/work/db/bad.sql.gz"
  run_script pull-db.sh --import-only --yes
  assert_rc 1
  assert_contains "Corrupt gzip"
}

test_pull_db_import_without_wp_config_fails() {
  mkdir -p "$T/work/db"
  printf -- '-- x\n-- Dump completed\n' | gzip -c >"$T/work/db/a.sql.gz"
  run_script pull-db.sh --import-only --yes
  assert_rc 1
  assert_contains "No wp-config.php"
}

test_pull_db_import_only_dry_run_prints_import() {
  run_script pull-db.sh --import-only --dry-run
  assert_rc 0
  assert_contains "db import -"
  assert_log_lacks "db import"
}

test_pull_db_import_only_missing_dump_fails() {
  run_script pull-db.sh --import-only --yes
  assert_rc 1
  assert_contains "No dump found"
}

test_pull_db_mutually_exclusive_modes() {
  run_script pull-db.sh --export-only --import-only
  assert_rc 2
  assert_contains "mutually exclusive"
}

test_pull_db_explicit_file_is_used() {
  touch "$T/site/wp-config.php"
  printf -- '-- x\n-- Dump completed\n' | gzip -c >"$T/custom.sql.gz"
  run_script pull-db.sh --import-only --yes --file "$T/custom.sql.gz"
  assert_rc 0
  assert_contains "custom.sql.gz"
}
