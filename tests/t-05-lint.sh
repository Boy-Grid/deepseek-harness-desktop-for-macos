#!/bin/bash
# Static checks over the shell sources and the bundle manifest.
set -u
TEST_NAME="t-05-lint"
cd "$(dirname "$0")" || exit 1
. lib/assert.sh

REPO="$(cd .. && pwd)"
SHELL_FILES="$REPO/launcher $REPO/build.sh $REPO/tests/run.sh $REPO/tests/lib/assert.sh"
for t in "$REPO"/tests/t-*.sh; do SHELL_FILES="$SHELL_FILES $t"; done

# --- parseable ---------------------------------------------------------------
for f in $SHELL_FILES; do
    assert_true "bash -n $(basename "$f")" -- bash -n "$f"
done

# --- unbraced variable followed by a multibyte character --------------------
# In a UTF-8 locale bash folds the following byte into the variable name, so an
# unbraced "$var" written directly against a Chinese character looks up a name
# that does not exist and set -u aborts the script.  This bit three times while
# writing the Chinese diagnostics, so it is a check rather than a habit.
#
# The offending shape is never written literally below -- it is assembled at run
# time -- so that this file can be scanned along with the others.
PATTERN=$(printf '\\$[A-Za-z_][A-Za-z0-9_]*[\200-\377]')
for f in $SHELL_FILES; do
    hits=$(LC_ALL=C grep -cE "$PATTERN" "$f" 2>/dev/null || true)
    assert_eq "0" "${hits:-0}" "$(basename "$f")：中文旁的变量引用都加了花括号"
done

# Reverse verification: the pattern must actually catch the mistake.
probe=$(mktemp "${TMPDIR:-/tmp}/d4m-lint.XXXXXX")
printf 'echo "%sfoo，bar"\n' '$' > "$probe"
probe_hits=$(LC_ALL=C grep -cE "$PATTERN" "$probe" 2>/dev/null || true)
rm -f "$probe"
assert_eq "1" "${probe_hits:-0}" "反向验证：该规则确实能命中未加花括号的写法"

# --- set -u must stay on: it is what turns the above into a hard failure ----
assert_true "launcher 保持 set -u" -- grep -q '^set -u' "$REPO/launcher"
assert_true "build.sh 保持 set -eu" -- grep -qE '^set -[a-z]*e[a-z]*u|^set -[a-z]*u[a-z]*e' "$REPO/build.sh"

# --- shellcheck --------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
    # -x follows sourced files, so helpers defined in lib/assert.sh and in the
    # launcher itself are not reported as unused where they are consumed.
    for f in $SHELL_FILES; do
        out=$(cd "$(dirname "$f")" && shellcheck -x -S warning -f gcc "$(basename "$f")" 2>&1) || true
        assert_eq "" "$out" "shellcheck $(basename "$f")"
    done
else
    skip "shellcheck（未安装，CI 上会跑）"
fi

# --- bundle manifest ---------------------------------------------------------
assert_true "Info.plist 是合法 plist" -- plutil -lint "$REPO/Info.plist"

# The identity decisions from M0, asserted so a later edit cannot quietly undo
# them: the bundle id is what a released DMG is stuck with, and the copyright
# line carries the trademark disclaimer.
plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$REPO/Info.plist" 2>/dev/null; }
assert_eq "io.github.boy-grid.dsh-desktop" "$(plist_get CFBundleIdentifier)" "bundle ID 未被改动"
assert_eq "DSH Desktop" "$(plist_get CFBundleName)" "CFBundleName 不含上游产品名"
# The floor is 14.0 because the per-tab persistent data stores need it, and the
# code already calls NSApplication.activate() (also 14+).
assert_eq "14.0" "$(plist_get LSMinimumSystemVersion)" "最低系统版本仍是 14.0"
# Without an explicit -target, swiftc stamps the host's OS version into the
# binary and the plist's promise becomes a lie. build.sh derives the target from
# the plist and verifies the result; both halves have to stay.
assert_true "build.sh 显式指定 -target" -- grep -q 'target "\$TARGET"' "$REPO/build.sh"
assert_true "build.sh 校验 minos 与 plist 一致" -- grep -q "deployment target drift" "$REPO/build.sh"
assert_contains "$(plist_get NSHumanReadableCopyright)" "not affiliated" "版权字段带免责声明"
assert_contains "$(plist_get NSHumanReadableCopyright)" "Boy-Grid" "版权字段带署名"

# --- the app must not name itself after the upstream product ---------------
assert_not_contains "$(grep -o 'w.title = .*' "$REPO/LauncherAgent.swift" || true)" "DeepSeek Harness" \
    "窗口标题不使用上游产品名"

finish
