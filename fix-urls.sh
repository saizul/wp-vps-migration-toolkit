#!/usr/bin/env bash
# fix-urls.sh - rewrite site URLs after the import (WP-CLI search-replace).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

OLD_URL=""
NEW_URL=""
VARIANTS=1
FLUSH=1

usage() {
  cat <<USAGE
Usage: fix-urls.sh [options]

Runs wp search-replace as a dry run first, shows what would change, asks for
confirmation, then applies it. Also rewrites JSON-escaped URLs (Elementor,
block data), http:// and protocol-relative variants, then flushes the Elementor
CSS cache, transients, object cache and rewrite rules.

Options:
  --old URL          URL to replace (default: SRC_URL)
  --new URL          Replacement (default: DST_URL)
  --no-variants      Only replace the exact --old string
  --skip-flush       Do not flush caches afterwards
  -n, --dry-run      Print commands only (nothing is executed at all)
  -y, --yes          Apply without the confirmation prompt
  --env FILE         Config file (default: ./migrate.env)
  -v, --verbose      Debug output
  -h, --help         Show this help
USAGE
}

while [ $# -gt 0 ]; do
  case $1 in
    --old)
      [ $# -ge 2 ] || die_usage "--old needs a URL"
      OLD_URL=$2
      shift
      ;;
    --new)
      [ $# -ge 2 ] || die_usage "--new needs a URL"
      NEW_URL=$2
      shift
      ;;
    --no-variants) VARIANTS=0 ;;
    --skip-flush) FLUSH=0 ;;
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
OLD_URL=$(url_strip_slash "${OLD_URL:-${SRC_URL:-}}")
NEW_URL=$(url_strip_slash "${NEW_URL:-${DST_URL:-}}")
[ -n "$OLD_URL" ] || die_usage "No old URL: pass --old or set SRC_URL"
[ -n "$NEW_URL" ] || die_usage "No new URL: pass --new or set DST_URL"
require_var DST_WP_PATH
case "$OLD_URL$NEW_URL" in
  *://*://*) ;;
  *) die_usage "URLs must include a scheme, e.g. https://example.com" ;;
esac
if [ "$OLD_URL" = "$NEW_URL" ]; then
  log_ok "Old and new URL are identical; nothing to rewrite"
  exit 0
fi
init_logging

escape_slashes() { printf '%s' "${1//\//\\/}"; }

# PAIRS holds "old|new" lines, most specific first.
PAIRS=()
add_pair() {
  local o=$1 n=$2 p
  for p in ${PAIRS[@]+"${PAIRS[@]}"}; do
    [ "$p" = "$o|$n" ] && return 0
  done
  PAIRS=(${PAIRS[@]+"${PAIRS[@]}"} "$o|$n")
}

old_host=$(url_host "$OLD_URL")
new_host=$(url_host "$NEW_URL")
add_pair "$OLD_URL" "$NEW_URL"
add_pair "$(escape_slashes "$OLD_URL")" "$(escape_slashes "$NEW_URL")"
if [ "$VARIANTS" = 1 ]; then
  if [ "$(url_scheme "$OLD_URL")" = "https" ]; then
    add_pair "http://${OLD_URL#*://}" "$NEW_URL"
    add_pair "$(escape_slashes "http://${OLD_URL#*://}")" "$(escape_slashes "$NEW_URL")"
  fi
  if [ "$old_host" != "$new_host" ]; then
    add_pair "//${OLD_URL#*://}" "//${NEW_URL#*://}"
    add_pair "$(escape_slashes "//${OLD_URL#*://}")" "$(escape_slashes "//${NEW_URL#*://}")"
  fi
fi

case "$NEW_URL" in
  "$OLD_URL"*) log_warn "New URL starts with old URL; re-running this script would double-apply the path" ;;
esac

SR_COMMON=(--all-tables-with-prefix --skip-columns=guid --report-changed-only)

log_info "Rewriting $OLD_URL -> $NEW_URL (${#PAIRS[@]} patterns)"
for pair in "${PAIRS[@]}"; do
  log_info "dry-run pattern: ${pair%%|*} -> ${pair#*|}"
  dst_wp search-replace "${pair%%|*}" "${pair#*|}" "${SR_COMMON[@]}" --dry-run
done

if is_dry; then
  log_info "Script dry-run: not applying. Planned apply and flush commands follow."
fi
confirm "Apply these replacements to the database at $DST_WP_PATH?"
for pair in "${PAIRS[@]}"; do
  dst_wp search-replace "${pair%%|*}" "${pair#*|}" "${SR_COMMON[@]}"
done

for opt in home siteurl; do
  if is_dry; then
    dst_wp option get "$opt"
    continue
  fi
  cur=$(dst_wp option get "$opt" 2>/dev/null || true)
  if [ "$cur" = "$NEW_URL" ]; then
    log_ok "$opt = $cur"
  else
    log_warn "$opt is '$cur', expected '$NEW_URL'; fix with: wp option update $opt $NEW_URL"
  fi
done

if [ "$FLUSH" = 1 ]; then
  if is_dry; then
    dst_wp plugin is-active elementor
    dst_wp elementor flush-css
  elif dst_wp plugin is-active elementor >/dev/null 2>&1; then
    dst_wp elementor flush-css || log_warn "elementor flush-css failed; regenerate under Elementor > Tools"
  else
    log_info "Elementor not active: skipping CSS flush"
  fi
  dst_wp transient delete --all || log_warn "transient delete failed"
  dst_wp cache flush || log_warn "cache flush failed"
  dst_wp rewrite flush || log_warn "rewrite flush failed"
fi
log_ok "URL rewrite finished. Next: ./verify.sh"
