#!/usr/bin/env bash
# Test runner: executes every test_* function in tests/test_*.sh, each in a
# subshell with a fresh sandbox. Usage: tests/run.sh [file-pattern]
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pattern="${1:-}"
total=0
failed=0

for file in "$DIR"/test_*.sh; do
  case "$file" in
    *"$pattern"*) ;;
    *) continue ;;
  esac
  names=$(bash -c ". '$file'; declare -F" | awk '{print $3}' | grep '^test_' || true)
  printf '%s\n' "$(basename "$file")"
  for name in $names; do
    total=$((total + 1))
    # Not inside `if (...)`: errexit is ignored in that context.
    (
      set -e
      # shellcheck source=/dev/null
      . "$DIR/helpers.sh"
      # shellcheck source=/dev/null
      . "$file"
      setup_env
      trap teardown_env EXIT
      "$name"
    )
    rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '  ok   %s\n' "$name"
    else
      printf '  FAIL %s\n' "$name"
      failed=$((failed + 1))
    fi
  done
done

printf '\n%d tests, %d failed\n' "$total" "$failed"
[ "$failed" -eq 0 ]
