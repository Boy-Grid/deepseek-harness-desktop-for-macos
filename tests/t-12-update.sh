#!/bin/bash
# The update path: version comparison, release parsing, every refusal, and the
# detached swap.
#
# The one thing not asserted here is a successful signed install, because that
# needs two Developer ID certificates and a notarized image. What stands in for it
# is coverage of each individual gate, plus check_team_id -- the decision that
# actually separates "a release" from "this project's release" -- tested directly.
set -u
TEST_NAME="t-12-update"
cd "$(dirname "$0")" || exit 1
. lib/assert.sh

L="$(cd .. && pwd)/launcher"
REPO="$(cd .. && pwd)"
# Not named PORT: sourcing the launcher below defines a PORT of its own.
PORT_FOR_MIRROR="${D4M_TEST_UPDATE_PORT:-3183}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/d4m-t12.XXXXXX")
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$TMP"
    return 0
}
trap cleanup EXIT

# ===========================================================================
# pure helpers, via the library mode the script offers for exactly this
# ===========================================================================
# shellcheck source=/dev/null
DSH_LAUNCHER_LIB=1 . "$L"

assert_true "0.2.0 > 0.1.0" -- version_gt 0.2.0 0.1.0
assert_true "0.10.0 > 0.9.0（按版本比，不是按字符串）" -- version_gt 0.10.0 0.9.0
assert_true "1.0.0 > 0.99.99" -- version_gt 1.0.0 0.99.99
assert_true "0.1.1 > 0.1.0" -- version_gt 0.1.1 0.1.0
assert_false "相等不算更大" -- version_gt 0.1.0 0.1.0
assert_false "更小不算更大" -- version_gt 0.1.0 0.2.0
assert_false "0.9.0 不大于 0.10.0" -- version_gt 0.9.0 0.10.0

# --- the identity gate ------------------------------------------------------
# Only "both present and equal" may pass. In particular an ad-hoc current app has
# no identity to anchor to, and must not be treated as "anything goes".
assert_true "Team ID 相同则通过" -- check_team_id D2U29Q6P4C D2U29Q6P4C
assert_false "Team ID 不同则拒绝" -- check_team_id D2U29Q6P4C AAAAAAAAAA
assert_false "当前应用无 Team ID（ad-hoc）则拒绝" -- check_team_id "" D2U29Q6P4C
assert_false "下载的应用无 Team ID 则拒绝" -- check_team_id D2U29Q6P4C ""
assert_false "两边都没有也拒绝" -- check_team_id "" ""
assert_contains "$(check_team_id "" D2U29Q6P4C 2>&1)" "ad-hoc" "ad-hoc 的拒绝说明指向原因"
assert_contains "$(check_team_id D2U29Q6P4C AAAAAAAAAA 2>&1)" "签名者与当前应用不一致" \
    "不一致的拒绝说明点出是身份不符"

# --- bundle discovery -------------------------------------------------------
mkdir -p "$TMP/Probe.app/Contents"
cp "$REPO/Info.plist" "$TMP/Probe.app/Contents/Info.plist"
assert_eq "$TMP/Probe.app" "$(UPDATE_APP_OVERRIDE="$TMP/Probe.app" bundle_path)" \
    "--app 指定的 bundle 被采用"
assert_eq "0.1.0" "$(bundle_version "$TMP/Probe.app")" "从 Info.plist 读出版本"
assert_eq "" "$(bundle_version "$TMP/nope.app")" "不存在的 bundle 读不出版本"

# --- release JSON parsing ---------------------------------------------------
cat > "$TMP/rel.json" <<'JSON'
{"tag_name":"v9.9.9","assets":[
 {"name":"notes.txt","browser_download_url":"http://x/notes.txt"},
 {"name":"DSH-Desktop-9.9.9-universal.dmg","browser_download_url":"http://x/app.dmg"},
 {"name":"SHA256SUMS","browser_download_url":"http://x/SHA256SUMS"}]}
JSON
assert_eq "v9.9.9" "$(release_field "$TMP/rel.json" tag_name)" "读出 tag_name"
assert_eq "http://x/app.dmg" "$(release_asset_url "$TMP/rel.json" '*.dmg')" \
    "按 glob 找到 dmg，跳过前面的资产"
assert_eq "http://x/SHA256SUMS" "$(release_asset_url "$TMP/rel.json" 'SHA256SUMS')" \
    "按名字找到 SHA256SUMS"
assert_eq "" "$(release_asset_url "$TMP/rel.json" '*.pkg')" "找不到就返回空"

# Sourcing the launcher defines its own PORT, so the HTTP port is named after
# that point rather than before it.
HTTP_PORT="$PORT_FOR_MIRROR"

# ===========================================================================
# update check / install against a local stand-in for the GitHub API
# ===========================================================================
NODE=$(command -v node 2>/dev/null || true)
if [ -z "$NODE" ]; then
    skip "余下用例（本机 PATH 上没有 node，无法起本地 mirror）"
    finish; exit $?
fi

MIRROR="$TMP/mirror"
mkdir -p "$MIRROR/repos/fake/repo/releases" "$MIRROR/dl"

# A disk image with a bundle inside, built for real so the download, the checksum
# and the mount are the actual operations rather than stubs.
mkdir -p "$TMP/img/Fake.app/Contents/MacOS"
cp "$REPO/Info.plist" "$TMP/img/Fake.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 9.9.9" \
    "$TMP/img/Fake.app/Contents/Info.plist" >/dev/null
printf '#!/bin/bash\nexit 0\n' > "$TMP/img/Fake.app/Contents/MacOS/LauncherAgent"
chmod +x "$TMP/img/Fake.app/Contents/MacOS/LauncherAgent"
DMG_NAME="DSH-Desktop-9.9.9-universal.dmg"
if ! hdiutil create -quiet -volname "Fake 9.9.9" -srcfolder "$TMP/img" \
        -ov -format UDZO "$MIRROR/dl/$DMG_NAME" >/dev/null 2>&1; then
    skip "余下用例（hdiutil create 失败）"
    finish; exit $?
fi
GOOD_SHA=$(shasum -a 256 "$MIRROR/dl/$DMG_NAME" | awk '{print $1}')

# An image with no .app in it, for the "nothing to install" refusal.
mkdir -p "$TMP/empty-img"
printf 'nothing here\n' > "$TMP/empty-img/README.txt"
hdiutil create -quiet -volname "Empty" -srcfolder "$TMP/empty-img" \
    -ov -format UDZO "$MIRROR/dl/empty.dmg" >/dev/null 2>&1

write_release() { # tag, dmg asset name (empty to omit), include SHA256SUMS?
    local tag="$1" dmg="$2" sums="$3" body
    body="{\"tag_name\":\"$tag\",\"assets\":["
    [ -n "$dmg" ] && body="$body{\"name\":\"$dmg\",\"browser_download_url\":\"http://127.0.0.1:$HTTP_PORT/dl/$dmg\"}"
    if [ "$sums" = "yes" ]; then
        [ -n "$dmg" ] && body="$body,"
        body="$body{\"name\":\"SHA256SUMS\",\"browser_download_url\":\"http://127.0.0.1:$HTTP_PORT/dl/SHA256SUMS\"}"
    fi
    printf '%s]}\n' "$body" > "$MIRROR/repos/fake/repo/releases/latest"
}

write_sums() { # hash, name
    printf '%s  %s\n' "$1" "$2" > "$MIRROR/dl/SHA256SUMS"
}

"$NODE" -e '
const http = require("node:http"), fs = require("node:fs"), path = require("node:path");
const root = process.argv[1], port = Number(process.argv[2]);
http.createServer((req, res) => {
  const file = path.join(root, decodeURIComponent(req.url.split("?")[0]));
  fs.readFile(file, (err, data) => {
    if (err) { res.statusCode = 404; res.end("no"); return; }
    res.end(data);
  });
}).listen(port, "127.0.0.1");
' "$MIRROR" "$HTTP_PORT" &
SERVER_PID=$!
write_release v9.9.9 "$DMG_NAME" yes
waited=0
while [ "$waited" -lt 50 ]; do
    curl -sf -o /dev/null "http://127.0.0.1:$HTTP_PORT/repos/fake/repo/releases/latest" && break
    sleep 0.1; waited=$((waited + 1))
done
if [ "$waited" -ge 50 ]; then
    skip "余下用例（本地 mirror 未能在 ${HTTP_PORT} 上起来）"
    finish; exit $?
fi

# The bundle the commands are told to look at and would replace.
CUR="$TMP/Current.app"
mkdir -p "$CUR/Contents/MacOS"
cp "$REPO/Info.plist" "$CUR/Contents/Info.plist"

upd() { # subcommand, extra args...
    env DSH_LAUNCHER_UPDATE_API="http://127.0.0.1:$HTTP_PORT" \
        DSH_LAUNCHER_UPDATE_REPO="fake/repo" \
        "$L" --app "$CUR" update "$@" 2>&1
}

set_current_version() { # version
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $1" \
        "$CUR/Contents/Info.plist" >/dev/null
}

staged_dirs() { find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'dsh-update-staged.*' 2>/dev/null; }
assert_no_residue() { assert_eq "" "$(staged_dirs)" "$1"; }
assert_no_residue "起点：没有遗留的暂存目录"

# --- check ------------------------------------------------------------------
set_current_version 0.1.0
out=$(upd check)
assert_contains "$out" "status:  outdated" "落后时报 outdated"
assert_contains "$out" "latest:  9.9.9" "报出最新版本号"
assert_contains "$out" "current: 0.1.0" "报出当前版本号"
assert_contains "$out" "releases/tag/v9.9.9" "给出发布页地址"

set_current_version 9.9.9
assert_contains "$(upd check)" "status:  current" "同版本时报 current"
set_current_version 99.0.0
assert_contains "$(upd check)" "status:  ahead" "本地更新时报 ahead"

# A release without a tag cannot be compared, and must say so rather than
# treating the empty string as a version.
write_release "" "$DMG_NAME" yes
out=$(upd check)
assert_contains "$out" "没有 tag_name" "缺 tag_name 时明确报错"
assert_exit 1 "缺 tag_name 时退出码非 0" -- \
    env DSH_LAUNCHER_UPDATE_API="http://127.0.0.1:$HTTP_PORT" \
        DSH_LAUNCHER_UPDATE_REPO="fake/repo" "$L" --app "$CUR" update check

# An unreachable API is a failure, not "you are up to date".
out=$(env DSH_LAUNCHER_UPDATE_API="http://127.0.0.1:1" \
          DSH_LAUNCHER_UPDATE_REPO="fake/repo" "$L" --app "$CUR" update check 2>&1)
assert_contains "$out" "连不上" "网络不可达时说的是连不上"
assert_not_contains "$out" "status:" "网络失败时不输出任何 status"

# A missing repo and a spent API quota are different problems from a dead network,
# and from each other. GitHub allows 60 anonymous calls an hour per IP, so a shared
# address can be refused while the connection is perfectly fine -- reporting that
# as a network fault sends the user off to debug the wrong thing.
assert_contains "$(env DSH_LAUNCHER_UPDATE_API="http://127.0.0.1:$HTTP_PORT" \
        DSH_LAUNCHER_UPDATE_REPO="no/such" "$L" --app "$CUR" update check 2>&1)" \
    "HTTP 404" "找不到发布信息时报 404"

LIMIT_PORT=$((HTTP_PORT + 1))
"$NODE" -e '
const http = require("node:http");
http.createServer((_req, res) => {
  res.statusCode = 403;
  res.setHeader("x-ratelimit-limit", "60");
  res.setHeader("x-ratelimit-remaining", "0");
  res.setHeader("x-ratelimit-reset", "2000000000");
  res.end(JSON.stringify({ message: "API rate limit exceeded" }));
}).listen(Number(process.argv[1]), "127.0.0.1");
' "$LIMIT_PORT" &
LIMIT_PID=$!
waited=0
while [ "$waited" -lt 50 ]; do
    curl -s -o /dev/null "http://127.0.0.1:$LIMIT_PORT/" && break
    sleep 0.1; waited=$((waited + 1))
done
out=$(env DSH_LAUNCHER_UPDATE_API="http://127.0.0.1:$LIMIT_PORT" \
          DSH_LAUNCHER_UPDATE_REPO="fake/repo" "$L" --app "$CUR" update check 2>&1)
kill "$LIMIT_PID" 2>/dev/null
assert_contains "$out" "限额已用完" "限额耗尽时说的是限额，而不是网络"
assert_not_contains "$out" "检查网络" "限额耗尽时不误导去查网络"
assert_contains "$out" "releases" "限额耗尽时给出可以手动查看的地址"

# --- install: the refusals --------------------------------------------------
write_release v9.9.9 "$DMG_NAME" yes
set_current_version 9.9.9
out=$(upd install)
assert_contains "$out" "already at 9.9.9" "已是最新时什么都不做"
assert_no_residue "已是最新时不留暂存目录"

set_current_version 0.1.0
write_sums "0000000000000000000000000000000000000000000000000000000000000000" "$DMG_NAME"
out=$(upd install)
assert_contains "$out" "校验和不匹配" "校验和不符时拒绝"
assert_contains "$out" "已丢弃下载内容" "拒绝时说明已丢弃"
assert_no_residue "校验和不符后不留暂存目录"

write_sums "$GOOD_SHA" "some-other-file.dmg"
out=$(upd install)
assert_contains "$out" "SHA256SUMS 里没有" "SHA256SUMS 缺本文件记录时拒绝"
assert_no_residue "缺记录后不留暂存目录"

write_release v9.9.9 "$DMG_NAME" no
write_sums "$GOOD_SHA" "$DMG_NAME"
assert_contains "$(upd install)" "缺少 .dmg 或 SHA256SUMS" "发布缺 SHA256SUMS 时拒绝"
write_release v9.9.9 "" yes
assert_contains "$(upd install)" "缺少 .dmg 或 SHA256SUMS" "发布缺 dmg 时拒绝"

# An image that mounts but holds no bundle.
write_release v9.9.9 "empty.dmg" yes
write_sums "$(shasum -a 256 "$MIRROR/dl/empty.dmg" | awk '{print $1}')" "empty.dmg"
out=$(upd install)
assert_contains "$out" "checksum verified" "空映像仍先通过校验和（顺序正确）"
assert_contains "$out" "找不到 .app" "映像里没有 .app 时拒绝"
assert_no_residue "空映像后不留暂存目录"

# The signature gate, reached only after the checksum one. The bundle in the
# fixture image is unsigned, which is exactly what must not be installed.
write_release v9.9.9 "$DMG_NAME" yes
write_sums "$GOOD_SHA" "$DMG_NAME"
out=$(upd install)
assert_contains "$out" "checksum verified" "签名检查之前已完成校验和"
assert_contains "$out" "签名校验失败" "未签名的下载内容被拒绝"
assert_no_residue "签名拒绝后不留暂存目录"
assert_eq "0.1.0" "$(plutil -extract CFBundleShortVersionString raw -o - \
    -- "$CUR/Contents/Info.plist")" "所有拒绝路径都没有动过目标 bundle"

# ===========================================================================
# the detached swap
# ===========================================================================
# Named .app so /usr/bin/open refuses it outright instead of revealing a folder
# in Finder; the script treats a failed reopen as non-fatal either way.
swap_case() { # case dir
    local d="$TMP/$1"
    rm -rf "$d"
    mkdir -p "$d/staged/New.app" "$d/Target.app"
    printf 'new\n' > "$d/staged/New.app/marker"
    printf 'old\n' > "$d/Target.app/marker"
    write_swap_script "$d/swap.sh" "$d/staged/New.app" "$d/Target.app" 0
}

# Replaces only after the pid it was given has exited.
swap_case waits
sleep 30 & hold=$!
"$TMP/waits/swap.sh" "$TMP/waits/staged/New.app" "$TMP/waits/Target.app" "$hold" 20 &
sleep 1
assert_eq "old" "$(cat "$TMP/waits/Target.app/marker")" "目标进程还活着时不替换"
kill "$hold" 2>/dev/null
waited=0
while [ "$waited" -lt 50 ] && [ -f "$TMP/waits/swap.sh" ]; do sleep 0.2; waited=$((waited+1)); done
assert_eq "new" "$(cat "$TMP/waits/Target.app/marker" 2>/dev/null)" "进程退出后完成替换"
assert_false "替换后 swap 脚本自删" -- test -f "$TMP/waits/swap.sh"
assert_false "替换后暂存目录清理" -- test -d "$TMP/waits/staged"

# Gives up rather than replacing under a process that never exits.
swap_case stubborn
sleep 30 & hold=$!
"$TMP/stubborn/swap.sh" "$TMP/stubborn/staged/New.app" "$TMP/stubborn/Target.app" "$hold" 3
rc=$?
kill "$hold" 2>/dev/null
assert_ne "0" "$rc" "等待超时后以非 0 退出"
assert_eq "old" "$(cat "$TMP/stubborn/Target.app/marker")" "等待超时后目标保持原样"
assert_false "等待超时后 swap 脚本自删" -- test -f "$TMP/stubborn/swap.sh"

# A copy that cannot be made must leave the installed bundle alone.
swap_case badsource
rm -rf "$TMP/badsource/staged/New.app"
"$TMP/badsource/swap.sh" "$TMP/badsource/staged/New.app" "$TMP/badsource/Target.app" 0 5
rc=$?
assert_ne "0" "$rc" "复制失败时以非 0 退出"
assert_eq "old" "$(cat "$TMP/badsource/Target.app/marker")" "复制失败时目标保持原样"
assert_false "复制失败后不留 .update-new 中间产物" -- test -e "$TMP/badsource/Target.app.update-new"

finish
