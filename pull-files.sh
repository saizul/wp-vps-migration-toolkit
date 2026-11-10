#!/usr/bin/env bash
# pull-files.sh - rsync WordPress files from the source host (resumable).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

DELETE=0
WITH_WP_CONFIG=0
WITH_HTACCESS=0
FIX_PERMS=0
ONLY_PATH=""
BWLIMIT=""

usage() {
  cat <<USAGE
Usage: pull-files.sh [options]

Pulls SRC_WP_PATH from the source over SSH into DST_WP_PATH with rsync.
Caches, backups, logs and cPanel debris are excluded (config/rsync-excludes.txt).
Interrupted transfers resume (--partial) and transient failures are retried.
Safe to run repeatedly: run it early, then again just before cutover.

Options:
  --delete           Delete files on the target that no longer exist on the source
  --with-wp-config   Also copy wp-config.php (default: excluded)
  --with-htaccess    Also copy .htaccess (default: excluded, useless on Nginx)
  --only PATH        Sync one sub-path only, e.g. wp-content/uploads
  --bwlimit KBPS     Limit bandwidth (rsync --bwlimit)
  --fix-perms        chmod dirs 755 / files 644 after transfer
  -n, --dry-run      Print the rsync command without running it
  -y, --yes          Do not prompt (needed with --delete in non-interactive use)
  --env FILE         Config file (default: ./migrate.env)
  -v, --verbose      Debug output
  -h, --help         Show this help
USAGE
}

while [ $# -gt 0 ]; do
  case $1 in
    --delete) DELETE=1 ;;
    --with-wp-config) WITH_WP_CONFIG=1 ;;
    --with-htaccess) WITH_HTACCESS=1 ;;
    --fix-perms) FIX_PERMS=1 ;;
    --only)
      [ $# -ge 2 ] || die_usage "--only needs a path"
      ONLY_PATH=${2#/}
      shift
      ;;
    --bwlimit)
      [ $# -ge 2 ] || die_usage "--bwlimit needs a number"
      BWLIMIT=$2
      shift
      ;;
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
require_cmd rsync
case "$ONLY_PATH" in
  *..*) die_usage "--only must not contain '..'" ;;
esac
init_logging

build_ssh_opts
SSH_CMD="ssh ${SSH_OPTS[*]}"

src="$SRC_SSH_USER@$SRC_SSH_HOST:${SRC_WP_PATH%/}/"
dst="${DST_WP_PATH%/}/"
if [ -n "$ONLY_PATH" ]; then
  src="${src}${ONLY_PATH%/}/"
  dst="${dst}${ONLY_PATH%/}/"
fi

args=(-az --partial --partial-dir=.rsync-partial --human-readable --stats
  --timeout=120 -e "$SSH_CMD"
  "--exclude-from=$HERE/config/rsync-excludes.txt")
[ "$WITH_WP_CONFIG" = 1 ] || args=("${args[@]}" --exclude=/wp-config.php)
[ "$WITH_HTACCESS" = 1 ] || args=("${args[@]}" --exclude=/.htaccess)
if [ -t 1 ]; then
  args=("${args[@]}" --info=progress2)
fi
if [ -n "$BWLIMIT" ]; then
  args=("${args[@]}" "--bwlimit=$BWLIMIT")
fi
if [ -n "$RSYNC_EXTRA_EXCLUDES" ]; then
  for pat in $RSYNC_EXTRA_EXCLUDES; do
    args=("${args[@]}" "--exclude=$pat")
  done
fi
if [ "$DELETE" = 1 ]; then
  confirm "--delete will remove files under $dst that are absent on the source. Continue?"
  args=("${args[@]}" --delete-after)
fi

log_info "Source: $src"
log_info "Target: $dst"
run mkdir -p "$dst"

attempt=1
while :; do
  log_info "rsync attempt $attempt/$RSYNC_RETRIES"
  rc=0
  if is_dry; then
    run rsync "${args[@]}" "$src" "$dst"
  else
    rsync "${args[@]}" "$src" "$dst" || rc=$?
  fi
  case $rc in
    0) break ;;
    24)
      log_warn "some source files vanished during transfer (rsync 24); treating as success"
      break
      ;;
    23) die "rsync 23: some files could not be transferred (permissions?). Not retrying." ;;
    10 | 12 | 30 | 35 | 255)
      if [ "$attempt" -ge "$RSYNC_RETRIES" ]; then
        die "rsync failed with code $rc after $attempt attempts"
      fi
      log_warn "rsync code $rc (network/timeout); resuming in $((RSYNC_RETRY_SLEEP * attempt))s"
      sleep $((RSYNC_RETRY_SLEEP * attempt))
      attempt=$((attempt + 1))
      ;;
    *) die "rsync failed with code $rc" ;;
  esac
done

if [ -n "${DST_OWNER:-}" ]; then
  run chown -R "$DST_OWNER" "$dst"
else
  log_info "DST_OWNER not set: remember to chown the files to the site user"
fi
if [ "$FIX_PERMS" = 1 ]; then
  run find "$dst" -type d -exec chmod 755 {} +
  run find "$dst" -type f -exec chmod 644 {} +
fi
if [ ! -f "${DST_WP_PATH%/}/wp-config.php" ] && [ "$WITH_WP_CONFIG" = 0 ] && ! is_dry; then
  log_warn "No wp-config.php on target. Create one: wp config create --dbname=... --dbuser=... --prompt=dbpass"
fi
log_ok "File sync complete"
