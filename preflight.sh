#!/usr/bin/env bash
# preflight.sh - read-only readiness checks before migrating a WordPress site.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

CACHE_PLUGINS="wp-rocket w3-total-cache wp-super-cache litespeed-cache wp-fastest-cache autoptimize cache-enabler sg-cachepress breeze hummingbird-performance comet-cache hyper-cache nitropack flying-press"
BACKUP_PLUGINS="updraftplus duplicator all-in-one-wp-migration backwpup backupbuddy wpvivid-backuprestore backupwordpress"
SERVER_BOUND_PLUGINS="wordfence sg-security ithemes-security-pro really-simple-ssl"

usage() {
  cat <<USAGE
Usage: preflight.sh [options]

Checks SSH access to the source, PHP versions, free disk, database size,
WP-CLI on both ends, and lists caches/plugins to purge or reconfigure.
Run it on the target VPS. Nothing is modified.

Options:
  -n, --dry-run      Print the remote commands without running them
  --env FILE         Config file (default: ./migrate.env)
  -v, --verbose      Debug output
  -h, --help         Show this help
  --version          Show version
USAGE
}

while [ $# -gt 0 ]; do
  case $1 in
    *)
      if common_flag "$@"; then
        shift $((COMMON_SHIFT - 1))
      else
        die_usage "Unknown option: $1"
      fi
      ;;
  esac
  shift
done

load_config
require_var SRC_SSH_HOST SRC_SSH_USER SRC_WP_PATH DST_WP_PATH
SRC_P=$(printf '%q' "$SRC_WP_PATH")

# probe CMD... - run a read-only probe; hide stderr noise except for dry-run output.
probe() {
  if is_dry; then
    "$@"
  else
    "$@" 2>/dev/null
  fi
}

SRC_PHP=""
SRC_MB=0
DB_MB=0
HAVE_SRC_WP=0

check_local_tools() {
  local t
  for t in ssh rsync gzip curl; do
    if command -v "$t" >/dev/null 2>&1; then
      pass "local tool present: $t"
    else
      fail "local tool missing: $t"
    fi
  done
  if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
    pass "local tool present: sha256sum/shasum"
  else
    fail "local tool missing: sha256sum or shasum"
  fi
}

check_ssh() {
  local out
  out=$(probe src_ssh "echo wpvm-ok") || out=""
  if is_dry; then
    skip "SSH access (dry-run)"
    return 0
  fi
  if [ "$out" = "wpvm-ok" ]; then
    pass "SSH access to $SRC_SSH_USER@$SRC_SSH_HOST:$SRC_SSH_PORT"
    return 0
  fi
  fail "cannot SSH to $SRC_SSH_USER@$SRC_SSH_HOST:$SRC_SSH_PORT (key authentication only; check SRC_SSH_KEY)"
  return 1
}

check_php() {
  local dst
  SRC_PHP=$(probe src_ssh "php -r 'echo PHP_VERSION;'") || SRC_PHP=""
  dst=$("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null) || dst=""
  if is_dry; then
    skip "PHP versions (dry-run)"
    return 0
  fi
  if [ -z "$SRC_PHP" ]; then
    warn "could not read source PHP CLI version (cPanel may need a full path to ea-php)"
  else
    pass "source PHP CLI: $SRC_PHP (the site may run a different MultiPHP version; check cPanel)"
  fi
  if [ -z "$dst" ]; then
    fail "target PHP CLI not found (PHP_BIN=$PHP_BIN)"
    return 0
  fi
  pass "target PHP: $dst"
  if [ "$(ver_num "$dst")" -lt "$(ver_num "$MIN_TARGET_PHP")" ]; then
    fail "target PHP $dst is older than MIN_TARGET_PHP=$MIN_TARGET_PHP"
  fi
  if [ -n "$SRC_PHP" ]; then
    if [ "$(ver_num "$dst")" -lt "$(ver_num "$SRC_PHP")" ]; then
      warn "target PHP ($dst) is older than source ($SRC_PHP); downgrades often break plugins"
    elif [ "$(ver_num "$dst")" -ge 8000 ] && [ "$(ver_num "$SRC_PHP")" -lt 8000 ]; then
      warn "PHP 7.x -> 8.x jump: test plugins/themes on staging before cutover"
    fi
  fi
}

check_remote_tools() {
  local t out
  for t in rsync mysqldump gzip; do
    out=$(probe src_ssh "command -v $t") || out=""
    if is_dry; then
      skip "source tool $t (dry-run)"
      continue
    fi
    if [ -n "$out" ]; then
      pass "source tool present: $t"
    else
      fail "source tool missing: $t"
    fi
  done
}

check_wpcli() {
  local out
  out=$(probe src_ssh "command -v $(printf '%q' "$SRC_WP_CLI")") || out=""
  if is_dry; then
    skip "WP-CLI on source (dry-run)"
  elif [ -n "$out" ]; then
    HAVE_SRC_WP=1
    pass "WP-CLI on source: $out"
  else
    warn "WP-CLI missing on source: DB size and plugin list fall back to filesystem checks"
  fi
  if command -v "$WP_CLI" >/dev/null 2>&1; then
    pass "WP-CLI on target: $(command -v "$WP_CLI")"
  elif is_dry; then
    skip "WP-CLI on target (dry-run)"
  else
    fail "WP-CLI missing on target (install: https://wp-cli.org/#installing); fix-urls.sh needs it"
  fi
}

check_disk() {
  local dir free need
  SRC_MB=$(probe src_ssh "du -sm $SRC_P | cut -f1") || SRC_MB=0
  if is_dry; then
    skip "disk space (dry-run)"
    return 0
  fi
  SRC_MB=${SRC_MB//[!0-9]/}
  : "${SRC_MB:=0}"
  dir=$DST_WP_PATH
  while [ ! -d "$dir" ] && [ "$dir" != "/" ]; do dir=$(dirname "$dir"); done
  free=$(df -Pm "$dir" | awk 'NR==2 {print $4}')
  free=${free//[!0-9]/}
  : "${free:=0}"
  # files + (dump + import + safety backup) headroom
  need=$((SRC_MB + DB_MB * 3 + 200))
  log_info "source size ${SRC_MB} MB, DB ${DB_MB} MB, target free ${free} MB, estimated need ${need} MB"
  if [ "$free" -lt "$need" ]; then
    fail "not enough free disk on target ($free MB < $need MB)"
  else
    pass "enough free disk on target ($free MB >= $need MB)"
  fi
  if [ -w "$dir" ]; then
    pass "target path writable: $dir"
  else
    warn "target path not writable by $(id -un): $dir"
  fi
}

check_db_size() {
  local out
  out=$(probe src_wp db query "SELECT ROUND(SUM(data_length+index_length)/1024/1024) FROM information_schema.tables WHERE table_schema=DATABASE()" --skip-column-names) || out=""
  if is_dry; then
    skip "database size (dry-run)"
    return 0
  fi
  out=${out//[!0-9]/}
  if [ -n "$out" ]; then
    DB_MB=$out
    pass "database size: ${DB_MB} MB"
  else
    warn "could not determine database size (needs WP-CLI on source)"
  fi
}

word_in_list() {
  local w=$1 list=$2 item
  for item in $list; do
    if [ "$item" = "$w" ]; then
      return 0
    fi
  done
  return 1
}

check_plugins() {
  local plugins p found=0
  if [ "$HAVE_SRC_WP" = 1 ] || is_dry; then
    plugins=$(probe src_wp plugin list --status=active --field=name) || plugins=""
  else
    plugins=$(probe src_ssh "ls -1 $SRC_P/wp-content/plugins") || plugins=""
  fi
  if is_dry; then
    skip "plugin inspection (dry-run)"
    return 0
  fi
  if [ -z "$plugins" ]; then
    warn "no plugin list obtained"
    return 0
  fi
  pass "found $(printf '%s\n' "$plugins" | wc -l | tr -d ' ') plugin(s)"
  for p in $plugins; do
    if word_in_list "$p" "$CACHE_PLUGINS"; then
      warn "cache plugin '$p': purge its cache and re-save settings on the new server"
      found=1
    elif word_in_list "$p" "$BACKUP_PLUGINS"; then
      warn "backup plugin '$p': archives are excluded from rsync; delete stale backups on source"
      found=1
    elif word_in_list "$p" "$SERVER_BOUND_PLUGINS"; then
      warn "server-bound plugin '$p': may write .htaccess/.user.ini rules that need Nginx/PHP-FPM equivalents"
      found=1
    fi
  done
  [ "$found" = 1 ] || pass "no known cache/backup/server-bound plugins active"
}

check_cache_paths() {
  local out line
  out=$(probe src_ssh "cd $SRC_P/wp-content && ls -d cache advanced-cache.php object-cache.php litespeed w3tc-config uploads/elementor/css updraft ai1wm-backups backwpup* 2>/dev/null; true") || out=""
  if is_dry; then
    skip "cache/backup path scan (dry-run)"
    return 0
  fi
  if [ -z "$out" ]; then
    pass "no cache or backup directories found in wp-content"
    return 0
  fi
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      warn "wp-content/$line present: excluded from transfer, regenerated on target"
    fi
  done <<<"$out"
}

main() {
  log_info "Preflight for $SRC_SSH_USER@$SRC_SSH_HOST:$SRC_WP_PATH -> $DST_WP_PATH"
  check_local_tools
  if check_ssh; then
    check_php
    check_remote_tools
    check_wpcli
    check_db_size
    check_disk
    check_plugins
    check_cache_paths
  fi
  if is_dry; then
    log_info "Dry run finished; no commands were executed"
    return 0
  fi
  summary
}

main
