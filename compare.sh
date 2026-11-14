#!/usr/bin/env bash
# compare.sh - read-only content parity check between the source and target site.
# Compares what WordPress holds on both ends (core, theme, plugins, table prefix,
# permalinks, posts per type, terms per taxonomy, comments, users) and the number
# of files in wp-content/uploads, so a truncated import or a partial rsync is
# caught before DNS cutover.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

TOLERANCE=""
CHECK_WP=1
CHECK_FILES=1
REPORT=""
# Upload subdirectories that pull-files.sh excludes (config/rsync-excludes.txt);
# they are pruned on both ends so the counts stay comparable.
UPLOAD_PRUNE="cache elementor/css wc-logs backupbuddy_backups backwpup-* wpforms/cache"

usage() {
  cat <<USAGE
Usage: compare.sh [options]

Compares the source and target site after pull-files.sh / pull-db.sh and
before DNS cutover. Read-only on both ends. Fails when the target is missing
content: fewer posts of a type, terms, comments, users or upload files than the
source, a plugin active only on the source, another active theme, a different
table prefix or permalink structure. More content on the target is a warning.

Options:
  --tolerance PCT    Accept up to PCT percent fewer items on the target per
                     count (default: COMPARE_TOLERANCE or 0); useful while the
                     old site is still live and taking comments or orders
  --skip-wp          Skip the WP-CLI (database) comparisons
  --skip-files       Skip the uploads file count
  --report FILE      Write the TSV report here (default:
                     WORK_DIR/reports/compare-TIMESTAMP.tsv)
  -n, --dry-run      Print the commands without running them
  --env FILE         Config file (default: ./migrate.env)
  -v, --verbose      Debug output
  -h, --help         Show this help
USAGE
}

while [ $# -gt 0 ]; do
  case $1 in
    --tolerance)
      [ $# -ge 2 ] || die_usage "--tolerance needs a percentage"
      TOLERANCE=$2
      shift
      ;;
    --skip-wp) CHECK_WP=0 ;;
    --skip-files) CHECK_FILES=0 ;;
    --report)
      [ $# -ge 2 ] || die_usage "--report needs a file"
      REPORT=$2
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
: "${COMPARE_TOLERANCE:=0}"
TOLERANCE=${TOLERANCE:-$COMPARE_TOLERANCE}
case "$TOLERANCE" in
  '' | *[!0-9]*) die_usage "Tolerance must be a whole percentage (0-100), got: $TOLERANCE" ;;
esac
TOLERANCE=$((10#$TOLERANCE))
[ "$TOLERANCE" -le 100 ] || die_usage "Tolerance must be between 0 and 100, got: $TOLERANCE"
if [ "$CHECK_WP" = 0 ] && [ "$CHECK_FILES" = 0 ]; then
  die_usage "--skip-wp and --skip-files together leave nothing to compare"
fi
require_var SRC_SSH_HOST SRC_SSH_USER SRC_WP_PATH DST_WP_PATH
init_logging

TMP=$(mktemp -d "${TMPDIR:-/tmp}/wpvm-compare.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
REPORT_ROWS="$TMP/report.tsv"
printf 'check\tsource\ttarget\tresult\n' >"$REPORT_ROWS"

# probe CMD... - run a read-only probe; hide stderr noise except for dry-run output.
probe() {
  if is_dry; then
    "$@"
  else
    "$@" 2>/dev/null
  fi
}

# record CHECK SOURCE TARGET RESULT - one row of the TSV report.
record() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" | tr -d '\r' >>"$REPORT_ROWS"
}

# one_line TEXT - first line, trimmed, carriage returns removed.
one_line() {
  printf '%s\n' "$1" | head -n 1 | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# words TEXT - sorted unique whitespace-separated words, one per line.
words() {
  printf '%s\n' "$1" | tr -d '\r' | awk '{ for (i = 1; i <= NF; i++) print $i }' | LC_ALL=C sort -u
}

# compare_count LABEL SRC DST - numeric comparison with tolerance.
compare_count() {
  local label=$1 s=$2 d=$3 diff allowed
  case "$s" in '' | *[!0-9]*) s='' ;; esac
  case "$d" in '' | *[!0-9]*) d='' ;; esac
  if [ -z "$s" ] || [ -z "$d" ]; then
    warn "$label: could not read both counts (source '${s:-?}', target '${d:-?}')"
    record "$label" "$s" "$d" WARN
    return 0
  fi
  s=$((10#$s))
  d=$((10#$d))
  if [ "$s" -eq "$d" ]; then
    pass "$label: $s on both"
    record "$label" "$s" "$d" PASS
  elif [ "$d" -gt "$s" ]; then
    warn "$label: target has more ($s -> $d); content created on the target after the import?"
    record "$label" "$s" "$d" WARN
  else
    diff=$((s - d))
    allowed=$((s * TOLERANCE / 100))
    if [ "$diff" -le "$allowed" ]; then
      warn "$label: target has $diff fewer ($s -> $d), within ${TOLERANCE}% tolerance"
      record "$label" "$s" "$d" WARN
    else
      fail "$label: target is missing $diff ($s -> $d)"
      record "$label" "$s" "$d" FAIL
    fi
  fi
}

# compare_keyed LABEL SRC_ROWS DST_ROWS - rows of "key count"; compares every key
# seen on either side (a key missing on one side counts as 0).
compare_keyed() {
  local label=$1 key s d
  printf '%s\n' "$2" | tr -d '\r' | awk 'NF >= 2 {print $1, $2}' >"$TMP/keyed.src"
  printf '%s\n' "$3" | tr -d '\r' | awk 'NF >= 2 {print $1, $2}' >"$TMP/keyed.dst"
  if [ ! -s "$TMP/keyed.src" ] && [ ! -s "$TMP/keyed.dst" ]; then
    warn "$label: no rows returned by either site"
    record "$label" "" "" WARN
    return 0
  fi
  awk 'FILENAME == ARGV[1] { s[$1] = $2; k[$1] = 1; next }
       { d[$1] = $2; k[$1] = 1 }
       END { for (x in k) print x, ((x in s) ? s[x] : 0), ((x in d) ? d[x] : 0) }' \
    "$TMP/keyed.src" "$TMP/keyed.dst" | LC_ALL=C sort >"$TMP/keyed.joined"
  while read -r key s d; do
    compare_count "$label $key" "$s" "$d"
  done <"$TMP/keyed.joined"
}

# compare_value LABEL SRC DST SEVERITY(fail|warn) - single string comparison.
compare_value() {
  local label=$1 s d severity=$4
  s=$(one_line "$2")
  d=$(one_line "$3")
  if [ -z "$s" ] && [ -z "$d" ]; then
    warn "$label: not readable on either site"
    record "$label" "" "" WARN
  elif [ "$s" = "$d" ]; then
    pass "$label: '$s' on both"
    record "$label" "$s" "$d" PASS
  elif [ "$severity" = fail ]; then
    fail "$label differs: source '$s', target '$d'"
    record "$label" "$s" "$d" FAIL
  else
    warn "$label differs: source '$s', target '$d'"
    record "$label" "$s" "$d" WARN
  fi
}

check_plugins() {
  local s d missing extra
  s=$(probe src_wp plugin list --status=active --field=name) || s=""
  d=$(probe dst_wp plugin list --status=active --field=name) || d=""
  is_dry && return 0
  words "$s" >"$TMP/plugins.src"
  words "$d" >"$TMP/plugins.dst"
  missing=$(LC_ALL=C comm -23 "$TMP/plugins.src" "$TMP/plugins.dst" | tr '\n' ' ')
  extra=$(LC_ALL=C comm -13 "$TMP/plugins.src" "$TMP/plugins.dst" | tr '\n' ' ')
  missing=${missing% }
  extra=${extra% }
  if [ -n "$missing" ]; then
    fail "active on source but not on target: $missing"
    record "active plugins missing" "$missing" "" FAIL
  fi
  if [ -n "$extra" ]; then
    warn "active on target only: $extra"
    record "active plugins extra" "" "$extra" WARN
  fi
  if [ -z "$missing" ] && [ -z "$extra" ]; then
    pass "active plugins match ($(wc -l <"$TMP/plugins.src" | tr -d ' '))"
    record "active plugins" "$(wc -l <"$TMP/plugins.src" | tr -d ' ')" "$(wc -l <"$TMP/plugins.dst" | tr -d ' ')" PASS
  fi
}

# valid_prefix PREFIX - table prefixes are interpolated into SQL; allow only [A-Za-z0-9_].
valid_prefix() {
  case "$1" in
    '' | *[!A-Za-z0-9_]*) return 1 ;;
  esac
  return 0
}

# db_rows SIDE SQL - run a query on src or dst WP-CLI, tab-separated, no header.
db_rows() {
  local side=$1 sql=$2
  if [ "$side" = src ]; then
    probe src_wp db query "$sql" --skip-column-names
  else
    probe dst_wp db query "$sql" --skip-column-names
  fi
}

check_database() {
  local sp dp s d
  sp=$(probe src_wp db prefix) || sp=""
  dp=$(probe dst_wp db prefix) || dp=""
  sp=$(one_line "$sp")
  dp=$(one_line "$dp")
  if is_dry; then
    sp=wp_
    dp=wp_
  else
    compare_value "table prefix" "$sp" "$dp" fail
    if [ "$sp" != "$dp" ]; then
      log_warn "the dump keeps the source prefix; set \$table_prefix = '$sp' in the target wp-config.php"
    fi
    if ! valid_prefix "$sp" || ! valid_prefix "$dp"; then
      fail "unusable table prefix (source '$sp', target '$dp'); skipping database counts"
      return 0
    fi
  fi

  s=$(db_rows src "SELECT post_type, COUNT(*) FROM ${sp}posts GROUP BY post_type") || s=""
  d=$(db_rows dst "SELECT post_type, COUNT(*) FROM ${dp}posts GROUP BY post_type") || d=""
  is_dry || compare_keyed "posts" "$s" "$d"

  s=$(db_rows src "SELECT taxonomy, COUNT(*) FROM ${sp}term_taxonomy GROUP BY taxonomy") || s=""
  d=$(db_rows dst "SELECT taxonomy, COUNT(*) FROM ${dp}term_taxonomy GROUP BY taxonomy") || d=""
  is_dry || compare_keyed "terms" "$s" "$d"

  s=$(db_rows src "SELECT COUNT(*) FROM ${sp}comments") || s=""
  d=$(db_rows dst "SELECT COUNT(*) FROM ${dp}comments") || d=""
  is_dry || compare_count "comments" "$(one_line "$s")" "$(one_line "$d")"

  s=$(db_rows src "SELECT COUNT(*) FROM ${sp}users") || s=""
  d=$(db_rows dst "SELECT COUNT(*) FROM ${dp}users") || d=""
  is_dry || compare_count "users" "$(one_line "$s")" "$(one_line "$d")"
}

check_wp() {
  local s d
  s=$(probe src_wp core version) || s=""
  d=$(probe dst_wp core version) || d=""
  if ! is_dry; then
    s=$(one_line "$s")
    d=$(one_line "$d")
    if [ -z "$s" ] || [ -z "$d" ]; then
      [ -n "$s" ] || fail "WP-CLI could not read the source site (SRC_WP_CLI, SRC_WP_PATH)"
      [ -n "$d" ] || fail "WP-CLI could not read the target site (WP_CLI, DST_WP_PATH, wp-config.php)"
      record "WordPress reachable" "${s:-no}" "${d:-no}" FAIL
      return 0
    fi
    compare_value "WordPress core" "$s" "$d" warn
  fi

  s=$(probe src_wp theme list --status=active --field=name) || s=""
  d=$(probe dst_wp theme list --status=active --field=name) || d=""
  is_dry || compare_value "active theme" "$s" "$d" fail

  check_plugins

  s=$(probe src_wp option get permalink_structure) || s=""
  d=$(probe dst_wp option get permalink_structure) || d=""
  is_dry || compare_value "permalink structure" "$s" "$d" fail

  check_database
}

# upload_find_args DIR - find(1) arguments counting files in DIR the way
# pull-files.sh transfers them (excluded caches and debris pruned).
upload_find_args() {
  local dir=$1 sub pat prune=""
  # Disable globbing: the lists hold patterns such as backwpup-*.
  set -f
  for sub in $UPLOAD_PRUNE; do
    prune="$prune $sub"
  done
  for sub in $RSYNC_EXTRA_EXCLUDES; do
    sub=${sub#/}
    case "$sub" in
      wp-content/uploads/?*) prune="$prune ${sub#wp-content/uploads/}" ;;
    esac
  done
  FIND_ARGS=("$dir" "(")
  for sub in $prune; do
    sub=${sub%/}
    if [ "${#FIND_ARGS[@]}" -gt 2 ]; then
      FIND_ARGS=("${FIND_ARGS[@]}" -o)
    fi
    FIND_ARGS=("${FIND_ARGS[@]}" -path "$dir/$sub")
  done
  set +f
  FIND_ARGS=("${FIND_ARGS[@]}" ")" -prune -o -type f)
  for pat in error_log debug.log .DS_Store '*.sql' '*.sql.gz' '*.zip.bak'; do
    FIND_ARGS=("${FIND_ARGS[@]}" ! -name "$pat")
  done
  FIND_ARGS=("${FIND_ARGS[@]}" -print)
}

check_uploads() {
  local src_dir dst_dir s d
  src_dir="${SRC_WP_PATH%/}/wp-content/uploads"
  dst_dir="${DST_WP_PATH%/}/wp-content/uploads"
  upload_find_args "$src_dir"
  s=$(probe src_ssh "if [ -d $(printf '%q' "$src_dir") ]; then find $(quote_args "${FIND_ARGS[@]}") 2>/dev/null | wc -l; else echo none; fi") || s=""
  upload_find_args "$dst_dir"
  if is_dry; then
    log_dry "find $(quote_cmd "${FIND_ARGS[@]}") | wc -l"
    return 0
  fi
  if [ -d "$dst_dir" ]; then
    d=$(find "${FIND_ARGS[@]}" 2>/dev/null | wc -l | tr -d ' ')
  else
    d=none
  fi
  s=$(one_line "$s")
  if [ "$s" = none ] && [ "$d" = none ]; then
    skip "uploads: no wp-content/uploads on either site"
    record "upload files" none none SKIP
    return 0
  fi
  [ "$s" = none ] && s=0
  [ "$d" = none ] && d=0
  compare_count "upload files" "$s" "$d"
}

write_report() {
  local dest=$REPORT
  if [ -z "$dest" ]; then
    mkdir -p "$WORK_DIR/reports"
    dest="$WORK_DIR/reports/compare-$(timestamp).tsv"
  fi
  if cp "$REPORT_ROWS" "$dest" 2>/dev/null; then
    log_info "Report written to $dest"
  else
    log_warn "could not write report to $dest"
  fi
}

main() {
  log_info "Comparing $SRC_SSH_USER@$SRC_SSH_HOST:$SRC_WP_PATH with $DST_WP_PATH (tolerance ${TOLERANCE}%)"
  if [ "$CHECK_WP" = 1 ]; then
    check_wp
  else
    skip "WP-CLI comparisons (--skip-wp)"
  fi
  if [ "$CHECK_FILES" = 1 ]; then
    check_uploads
  else
    skip "uploads file count (--skip-files)"
  fi
  if is_dry; then
    log_info "Dry run finished; no commands were executed"
    return 0
  fi
  write_report
  summary
}

main
