#!/bin/bash
# Run every tests/t-*.sh in its own process and summarise.
#
#   tests/run.sh              run all
#   tests/run.sh t-03         run the files whose name contains "t-03"
#
# Skips are counted and repeated at the end: a case that could not run here (no
# pnpm on the machine, a busy port) must not read as a pass.
set -u

cd "$(dirname "$0")" || exit 1
filter="${1:-}"

out_dir=$(mktemp -d "${TMPDIR:-/tmp}/d4m-run.XXXXXX")
trap 'rm -rf "$out_dir"' EXIT

total=0
failed=0
failed_names=""

for t in t-*.sh; do
    [ -f "$t" ] || continue
    if [ -n "$filter" ]; then
        case "$t" in *"$filter"*) ;; *) continue ;; esac
    fi
    total=$((total + 1))
    printf '\n=== %s ===\n' "$t"
    # The status of a pipeline is tee's, which is always 0 -- read the test's own
    # from PIPESTATUS instead of guessing from its output.
    bash "$t" 2>&1 | tee "$out_dir/$t.log"
    rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        failed=$((failed + 1))
        if grep -q 'assertions' "$out_dir/$t.log"; then
            failed_names="$failed_names $t"
        else
            # No summary line: the file died before reaching finish.
            failed_names="$failed_names $t(aborted:$rc)"
        fi
    fi
done

skips=$(grep -h 'SKIP' "$out_dir"/*.log 2>/dev/null | sed 's/^ *//' || true)
skip_count=$(printf '%s' "$skips" | grep -c 'SKIP' || true)

printf '\n-----------------------------------------\n'
if [ "$total" -eq 0 ]; then
    printf 'no test files matched %s\n' "${filter:-*}"
    exit 1
fi
if [ "${skip_count:-0}" -gt 0 ]; then
    printf '%s\n' "$skips"
    printf '\n'
fi
if [ "$failed" -eq 0 ]; then
    printf '%d test files, all passed' "$total"
else
    printf '%d test files, %d failed:%s' "$total" "$failed" "$failed_names"
fi
[ "${skip_count:-0}" -gt 0 ] && printf ' (%d skipped)' "$skip_count"
printf '\n'
[ "$failed" -eq 0 ]
