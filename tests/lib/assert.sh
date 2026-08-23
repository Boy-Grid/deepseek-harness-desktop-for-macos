#!/bin/bash
# =============================================================================
# Minimal assertion helpers.
#
# No test framework on purpose: the app itself has zero runtime dependencies and
# CI should not need to install one to check it.  Each tests/t-*.sh sources this
# file, asserts, and ends with `finish`.
# =============================================================================

set -u

TEST_NAME="${TEST_NAME:-$(basename "${0%.sh}")}"
ASSERT_COUNT=0
ASSERT_FAILED=0
ASSERT_SKIPPED=0

if [ -t 1 ]; then
    _C_PASS=$'\033[32m'; _C_FAIL=$'\033[31m'; _C_SKIP=$'\033[33m'; _C_OFF=$'\033[0m'
else
    _C_PASS=""; _C_FAIL=""; _C_SKIP=""; _C_OFF=""
fi

_pass() {
    ASSERT_COUNT=$((ASSERT_COUNT + 1))
    printf '  %sPASS%s %s\n' "$_C_PASS" "$_C_OFF" "$1"
}

_fail() {
    ASSERT_COUNT=$((ASSERT_COUNT + 1))
    ASSERT_FAILED=$((ASSERT_FAILED + 1))
    printf '  %sFAIL%s %s\n' "$_C_FAIL" "$_C_OFF" "$1"
    [ $# -gt 1 ] && printf '       %s\n' "$2"
    return 0
}

# Announce a test that cannot run here (a missing dsh install, say) instead of
# quietly passing.  A skip is visible in the output but does not fail the run.
skip() {
    ASSERT_SKIPPED=$((ASSERT_SKIPPED + 1))
    printf '  %sSKIP%s %s\n' "$_C_SKIP" "$_C_OFF" "$1"
}

assert_eq() { # expected actual label
    if [ "$1" = "$2" ]; then _pass "$3"; else _fail "$3" "expected [$1], got [$2]"; fi
}

assert_ne() { # unexpected actual label
    if [ "$1" != "$2" ]; then _pass "$3"; else _fail "$3" "did not expect [$1]"; fi
}

assert_contains() { # haystack needle label
    case "$1" in
        *"$2"*) _pass "$3" ;;
        *) _fail "$3" "missing [$2] in: $(printf '%s' "$1" | head -3 | tr '\n' '|')" ;;
    esac
}

assert_not_contains() { # haystack needle label
    case "$1" in
        *"$2"*) _fail "$3" "unexpectedly found [$2]" ;;
        *) _pass "$3" ;;
    esac
}

assert_true() { # label -- command...
    local label="$1"; shift; [ "$1" = "--" ] && shift
    if "$@" >/dev/null 2>&1; then _pass "$label"; else _fail "$label" "command failed: $*"; fi
}

assert_false() { # label -- command...
    local label="$1"; shift; [ "$1" = "--" ] && shift
    if "$@" >/dev/null 2>&1; then _fail "$label" "command unexpectedly succeeded: $*"; else _pass "$label"; fi
}

assert_exit() { # expected-code label -- command...
    local want="$1" label="$2"; shift 2; [ "$1" = "--" ] && shift
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    assert_eq "$want" "$got" "$label"
}

finish() {
    local total="$ASSERT_COUNT"
    if [ "$ASSERT_FAILED" -eq 0 ]; then
        printf '%s: %d assertions, 0 failed' "$TEST_NAME" "$total"
    else
        printf '%s: %d assertions, %s%d failed%s' "$TEST_NAME" "$total" "$_C_FAIL" "$ASSERT_FAILED" "$_C_OFF"
    fi
    [ "$ASSERT_SKIPPED" -gt 0 ] && printf ', %d skipped' "$ASSERT_SKIPPED"
    printf '\n'
    [ "$ASSERT_FAILED" -eq 0 ]
}
