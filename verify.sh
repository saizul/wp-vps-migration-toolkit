#!/usr/bin/env bash
# verify.sh - smoke-test the new server BEFORE changing DNS.
# Uses curl --resolve so the real hostname is served by the new IP.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

TARGET_URL=""
TARGET_IP=""
OLD_HOST=""
EXTRA=""
DEFAULT_CHECKS="/=200 /wp-login.php=200 /wp-admin/=302 /wp-admin/admin-ajax.php=200,400 /robots.txt=200 /wp-sitemap.xml=200,301 /wp-json/=200 /feed/=200"

usage() {
  cat <<USAGE
Usage: verify.sh [options]

Requests key URLs on the new server (by IP, with the real Host header and SNI)
and checks status codes, mixed content, leftover old-domain links, the
wp-login.php form and WP-Cron. Exits 1 if any check fails.

Options:
  --url URL          Site URL to test (default: DST_URL)
  --ip IP            New server IP (default: DST_IP)
  --old-host HOST    Old hostname to search for in HTML (default: host of SRC_URL)
  --check PATH=CODES Extra check, repeatable, e.g. --check /about/=200
  --secure           Validate TLS certificates (default accepts any until the
                     certificate is issued; see VERIFY_INSECURE)
  -n, --dry-run      Print the curl commands without running them
  --env FILE         Config file (default: ./migrate.env)
  -v, --verbose      Debug output
  -h, --help         Show this help
USAGE
}

while [ $# -gt 0 ]; do
  case $1 in
    --url)
      [ $# -ge 2 ] || die_usage "--url needs a value"
      TARGET_URL=$2
      shift
      ;;
    --ip)
      [ $# -ge 2 ] || die_usage "--ip needs a value"
      TARGET_IP=$2
      shift
      ;;
    --old-host)
      [ $# -ge 2 ] || die_usage "--old-host needs a value"
      OLD_HOST=$2
      shift
      ;;
    --check)
      [ $# -ge 2 ] || die_usage "--check needs PATH=CODES"
      case $2 in
        /*=*) EXTRA="$EXTRA $2" ;;
        *) die_usage "--check expects PATH=CODES, e.g. /about/=200" ;;
      esac
      shift
      ;;
    --secure) VERIFY_INSECURE_FLAG=0 ;;
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
if [ -n "${VERIFY_INSECURE_FLAG:-}" ]; then
  VERIFY_INSECURE=$VERIFY_INSECURE_FLAG
fi
TARGET_URL=$(url_strip_slash "${TARGET_URL:-${DST_URL:-}}")
TARGET_IP=${TARGET_IP:-${DST_IP:-}}
[ -n "$TARGET_URL" ] || die_usage "No URL: pass --url or set DST_URL"
[ -n "$TARGET_IP" ] || die_usage "No IP: pass --ip or set DST_IP"
case "$TARGET_IP" in
  *[!0-9a-fA-F:.]*) die_usage "Invalid IP address: $TARGET_IP" ;;
esac
case "$TARGET_URL" in
  http://* | https://*) ;;
  *) die_usage "URL must start with http:// or https://" ;;
esac
require_cmd curl

HOST=$(url_host "$TARGET_URL")
SCHEME=$(url_scheme "$TARGET_URL")
if [ -z "$OLD_HOST" ] && [ -n "${SRC_URL:-}" ]; then
  OLD_HOST=$(url_host "$SRC_URL")
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/wpvm-verify.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

CURL_BASE=(-sS --max-time 30 --resolve "$HOST:443:$TARGET_IP" --resolve "$HOST:80:$TARGET_IP"
  -A "wp-vps-migration-toolkit/$WPVM_VERSION")
if [ "$VERIFY_INSECURE" = 1 ]; then
  CURL_BASE=("${CURL_BASE[@]}" -k)
fi

# fetch PATH -> sets CODE, writes $TMP/body and $TMP/headers
fetch() {
  local path=$1
  : >"$TMP/body"
  : >"$TMP/headers"
  if is_dry; then
    log_dry "curl ${CURL_BASE[*]} -o body -D headers -w '%{http_code}' $TARGET_URL$path"
    CODE="000"
    return 0
  fi
  CODE=$(curl "${CURL_BASE[@]}" -o "$TMP/body" -D "$TMP/headers" -w '%{http_code}' "$TARGET_URL$path" 2>"$TMP/err") || CODE="000"
}

code_ok() {
  local code=$1 allowed=$2 c
  for c in ${allowed//,/ }; do
    if [ "$c" = "$code" ]; then
      return 0
    fi
  done
  return 1
}

check_status() {
  local spec=$1 path codes
  path=${spec%%=*}
  codes=${spec#*=}
  fetch "$path"
  if is_dry; then
    skip "$path (dry-run)"
    return 0
  fi
  if code_ok "$CODE" "$codes"; then
    pass "$path -> $CODE"
  elif [ "$CODE" = "000" ]; then
    fail "$path -> connection error: $(head -n 1 "$TMP/err" 2>/dev/null)"
  else
    fail "$path -> $CODE (expected $codes) $(grep -i '^location:' "$TMP/headers" | head -n 1 | tr -d '\r')"
  fi
}

check_home_html() {
  local hits
  fetch "/"
  if is_dry; then
    skip "mixed content / old-domain scan (dry-run)"
    return 0
  fi
  if [ "$CODE" != "200" ]; then
    warn "home page returned $CODE; skipping HTML scans"
    return 0
  fi
  if [ "$SCHEME" = "https" ]; then
    hits=$(grep -Eoi "(<(link|script|img|iframe|source|video|audio)[^>]+(src|href)=[\"']http://[^\"']+|srcset=[\"']http://[^\"']+|url\(['\"]?http://[^)'\"]+)" "$TMP/body" | head -n 10 || true)
    if [ -n "$hits" ]; then
      fail "mixed content (http:// resources on https page):"
      printf '%s\n' "$hits" | sed 's/^/        /' >&2
    else
      pass "no mixed content on /"
    fi
  else
    skip "mixed content check (site URL is http)"
  fi
  if [ -n "$OLD_HOST" ] && [ "$OLD_HOST" != "$HOST" ]; then
    hits=$(grep -c -F "$OLD_HOST" "$TMP/body" || true)
    if [ "${hits:-0}" -gt 0 ]; then
      fail "old host '$OLD_HOST' still referenced on / ($hits line(s)); run fix-urls.sh and flush caches"
    else
      pass "no references to old host $OLD_HOST on /"
    fi
  fi
}

check_login() {
  fetch "/wp-login.php"
  if is_dry; then
    skip "wp-login.php form (dry-run)"
    return 0
  fi
  if [ "$CODE" = "200" ] && grep -q -E 'name=["'"'"']log["'"'"']|id=["'"'"']user_login["'"'"']' "$TMP/body"; then
    pass "wp-login.php serves the login form"
  else
    fail "wp-login.php did not return a login form (HTTP $CODE)"
  fi
  fetch "/wp-admin/"
  if [ "$CODE" = "302" ] && grep -qi '^location:.*wp-login.php' "$TMP/headers"; then
    pass "wp-admin redirects to wp-login.php"
  elif [ "$CODE" = "200" ]; then
    warn "wp-admin returned 200 (already authenticated session or custom login URL?)"
  else
    fail "wp-admin returned $CODE instead of redirecting to the login page"
  fi
}

check_cron() {
  fetch "/wp-cron.php?doing_wp_cron=$(date +%s)"
  if is_dry; then
    skip "WP-Cron (dry-run)"
    dst_wp cron event list --format=count
    dst_wp config get DISABLE_WP_CRON
    return 0
  fi
  if [ "$CODE" = "200" ]; then
    pass "wp-cron.php reachable (200)"
  else
    fail "wp-cron.php returned $CODE (blocked by Nginx rules or basic auth?)"
  fi
  if [ -n "${DST_WP_PATH:-}" ] && command -v "$WP_CLI" >/dev/null 2>&1; then
    local n disabled
    n=$(dst_wp cron event list --format=count 2>/dev/null || true)
    disabled=$(dst_wp config get DISABLE_WP_CRON 2>/dev/null || true)
    if [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null; then
      pass "$n cron event(s) scheduled"
    else
      warn "no cron events listed (new site or WP-CLI could not connect)"
    fi
    case "$disabled" in
      1 | true)
        if crontab -l 2>/dev/null | grep -Eq 'wp-cron|wp cron'; then
          pass "DISABLE_WP_CRON set and a system cron job exists"
        else
          warn "DISABLE_WP_CRON is set but no system cron job calls wp-cron; scheduled posts will not run"
        fi
        ;;
    esac
  fi
}

main() {
  local spec
  log_info "Verifying $TARGET_URL on $TARGET_IP (host header $HOST)"
  if [ "$VERIFY_INSECURE" = 1 ]; then
    log_info "TLS verification disabled (use --secure once a certificate is installed)"
  fi
  for spec in $DEFAULT_CHECKS $VERIFY_EXTRA_URLS $EXTRA; do
    check_status "$spec"
  done
  check_home_html
  check_login
  check_cron
  if is_dry; then
    log_info "Dry run finished; no requests were sent"
    return 0
  fi
  summary
}

main
