#!/bin/bash
# The app-side half of the network settings: the loopback classifier that decides
# whether the user is warned, and the two parsers that decide what gets stored.
#
# These run against the shipping Preferences.swift through a probe binary, so a
# logic change cannot pass by keeping the right words in the source -- which is
# all tests/t-05-lint.sh is able to check.
set -u
TEST_NAME="t-11-exposure"
cd "$(dirname "$0")" || exit 1
. lib/assert.sh

REPO="$(cd .. && pwd)"

if ! command -v swiftc >/dev/null 2>&1; then
    skip "全部用例（本机没有 swiftc）"
    finish; exit $?
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/d4m-t11.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PROBE="$TMP/exposure-probe"
build_log="$TMP/build.log"
if ! swiftc -O -o "$PROBE" \
        "$REPO/Preferences.swift" "$REPO/TabStore.swift" \
        "$(pwd)/fixtures/exposure-probe.swift" >"$build_log" 2>&1; then
    _fail "探针编译失败" "$(sed -n '1,12p' "$build_log")"
    finish; exit $?
fi
_pass "探针编译通过（Preferences.swift 可独立编译）"

ask() { "$PROBE" "$@" 2>/dev/null; }

# ===========================================================================
# loopback classification -- the security-relevant half
# ===========================================================================
for host in 127.0.0.1 127.0.0.53 localhost LocalHost ::1 "[::1]" " 127.0.0.1 "; do
    assert_eq "yes" "$(ask loopback "$host")" "「${host}」判定为仅本机"
done

# Everything else has to read as exposed. 0.0.0.0 is the case the feature exists
# for; the rest are shapes that must not be mistaken for loopback because they
# merely start with or contain the digits.
for host in 0.0.0.0 :: 192.168.1.50 10.0.0.9 1270.0.0.1 12.7.0.1 example.com \
            "" "127" "0127.0.0.1"; do
    assert_eq "no" "$(ask loopback "$host")" "「${host}」判定为对外可达"
done

# ===========================================================================
# authority list parsing
# ===========================================================================
assert_eq "dsh.local|box:3080" "$(ask authorities "dsh.local, box:3080")" "逗号分隔"
assert_eq "dsh.local|box:3080" "$(ask authorities "dsh.local box:3080")" "空格分隔"
assert_eq "dsh.local|box:3080" "$(ask authorities $'dsh.local\nbox:3080')" "换行分隔"
assert_eq "a|b|c" "$(ask authorities " a ,, b   c , ")" "忽略空项与多余分隔符"
assert_eq "<empty>" "$(ask authorities "")" "空输入得到空列表"
assert_eq "<empty>" "$(ask authorities "   ,  ")" "只有分隔符也得到空列表"

# ===========================================================================
# port normalisation -- refuse rather than store something that fails at bind
# ===========================================================================
assert_eq "3080" "$(ask port "3080")" "常规端口"
assert_eq "8080" "$(ask port " 8080 ")" "去掉两端空白"
assert_eq "1" "$(ask port "1")" "下界 1"
assert_eq "65535" "$(ask port "65535")" "上界 65535"
for bad in 0 65536 -1 "" abc "80 80" "3080a" "3.14"; do
    assert_eq "<invalid>" "$(ask port "$bad")" "「${bad}」被拒绝"
done

finish
