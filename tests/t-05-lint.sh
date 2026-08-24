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
assert_true "build.sh 按 plist 推导 -target" -- grep -q 'apple-macos\${MIN_OS}' "$REPO/build.sh"
assert_true "build.sh 校验 minos 与 plist 一致" -- grep -q "deployment target drift" "$REPO/build.sh"

# --- release signing requirements ------------------------------------------
# Notarization rejects a submission without the hardened runtime or a secure
# timestamp, and a release that is only ad-hoc signed would look official while
# still being refused by Gatekeeper. These are the flags that make the
# difference, asserted here because CI has no certificate to sign with.
build=$(cat "$REPO/build.sh")
assert_contains "$build" "--options runtime" "release 签名带 hardened runtime"
assert_contains "$build" "--timestamp" "release 签名带安全时间戳"
assert_contains "$build" "Developer ID Certification Authority" "release 校验 Developer ID 证书链"
assert_contains "$build" "lipo -create" "release 产出通用二进制"

dmg=$(cat "$REPO/scripts/make-dmg.sh")
assert_contains "$dmg" "CFBundleName" "打包时按产品名放置 bundle（而非源路径名）"
assert_contains "$dmg" "stapler staple" "公证后装订票据"
assert_contains "$dmg" "notarytool info" "轮询公证状态而不是无限 --wait"
assert_not_contains "$dmg" "submit \"\$DMG\" --keychain-profile \"\$NOTARY_PROFILE\" --wait" \
    "不使用会挂死的 submit --wait"

# `grep -q` in a pipeline under `set -o pipefail` reports failure for a search
# that succeeded: grep exits at the first match and the writer takes SIGPIPE.
# Both release scripts set pipefail, so neither may pipe into `grep -q`.
# The same applies to `| head -n`, which closes the pipe just as early.
# Comments are stripped first: these files explain the trap in prose, and an
# explanation must not trip the check that enforces it.
for f in "$REPO/build.sh" "$REPO/scripts/make-dmg.sh"; do
    body=$(sed 's/#.*$//' "$f")
    assert_contains "$(cat "$f")" "pipefail" "$(basename "$f") 开启 pipefail"
    assert_not_contains "$body" "| grep -q" \
        "$(basename "$f") 不在 pipefail 下管道接 grep -q"
    assert_not_contains "$body" "| head -" \
        "$(basename "$f") 不在 pipefail 下管道接 head"
done
assert_contains "$(plist_get NSHumanReadableCopyright)" "not affiliated" "版权字段带免责声明"
assert_contains "$(plist_get NSHumanReadableCopyright)" "Boy-Grid" "版权字段带署名"

# --- the app must not name itself after the upstream product ---------------
assert_not_contains "$(grep -o 'w.title = .*' "$REPO/LauncherAgent.swift" || true)" "DeepSeek Harness" \
    "窗口标题不使用上游产品名"

finish
