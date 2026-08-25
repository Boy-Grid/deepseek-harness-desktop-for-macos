#!/bin/bash
# The contract between "no runtime here" and the offer to fetch one.
#
# The app used to decide this by searching the failure text for the words
# "runtime install". That made the offer depend on how each message happened to be
# phrased, and a missing stock dsh -- the case the managed runtime was built for --
# was phrased without them, so the offer never appeared. Worse, the check lived
# only on the launch path, so switching backends in Preferences reached a dead end.
#
# The signal is now an exit code, asserted here and used verbatim by the app.
set -u
TEST_NAME="t-14-missing-runtime"
cd "$(dirname "$0")" || exit 1
. lib/assert.sh

L="$(cd .. && pwd)/launcher"
REPO="$(cd .. && pwd)"
PORT="${D4M_TEST_PORT:-3187}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/d4m-t14.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# start_server checks the port before it resolves anything, so a service already
# there short-circuits every case below into "not mine" rather than the resolution
# failure under test. Say so instead of reporting five unrelated failures.
if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT" 2>/dev/null; then
    skip "全部用例（端口 ${PORT} 已被占用，设 D4M_TEST_PORT 换一个）"
    finish; exit $?
fi

# Resolution is stubbed rather than arranged: making "no node anywhere" true would
# mean controlling /opt/homebrew and /usr/local, which no test can rely on -- CI
# installs node on PATH. What is under test is the code a failed resolution
# produces, so failing the resolution outright is exactly the right lever.
start_with() { # stub definitions...
    (
        export DSH_LAUNCHER_LIB=1
        # shellcheck source=/dev/null
        . "$L" --port "$PORT" --state "$TMP/state" >/dev/null 2>&1
        eval "$1"
        start_server >/dev/null 2>&1
        echo $?
    )
}

EXPECTED=$(sed -n 's/^EXIT_NEEDS_RUNTIME=\([0-9]*\).*/\1/p' "$L")
assert_eq "4" "$EXPECTED" "launcher 定义的 EXIT_NEEDS_RUNTIME 是 4"

# --- node missing -----------------------------------------------------------
assert_eq "$EXPECTED" "$(start_with 'resolve_node() { return 1; }')" \
    "找不到 node 时以 EXIT_NEEDS_RUNTIME 退出"

# --- stock dsh missing: the case that used to get no offer ------------------
assert_eq "$EXPECTED" \
    "$(start_with 'resolve_node() { echo /usr/bin/true; }; resolve_dsh() { return 1; }')" \
    "找不到 stock dsh 时同样以 EXIT_NEEDS_RUNTIME 退出"
out=$(
    export DSH_LAUNCHER_LIB=1
    # shellcheck source=/dev/null
    . "$L" --port "$PORT" --state "$TMP/state" >/dev/null 2>&1
    resolve_node() { echo /usr/bin/true; }
    resolve_dsh() { return 1; }
    start_server 2>&1
)
assert_contains "$out" "runtime install" "缺 dsh 的提示里给出了 runtime install 这条出路"
assert_contains "$out" "npm install -g @deepseek-ai/dsh" "同时保留自行安装的办法"

# --- the message goes into a dialog verbatim, so it must read cleanly --------
# resolve_node writes its own "$PROG: ..." to stderr and start_server forwards it,
# which used to produce "DSH Desktop: DSH Desktop: ..." on screen.
node_msg=$(
    export DSH_LAUNCHER_LIB=1
    # shellcheck source=/dev/null
    . "$L" --port "$PORT" --state "$TMP/state" >/dev/null 2>&1
    # Stubbed, like every other case here. Without this the real resolvers succeed
    # on a developer machine and the case starts an actual server on the test port,
    # which then makes the assertions below pass or fail for the wrong reason.
    resolve_node() { echo "$PROG: 找不到 Node.js 运行时。" >&2; return 1; }
    start_server 2>&1
)
assert_not_contains "$node_msg" "DSH Desktop: DSH Desktop:" "程序名前缀不重复出现"
assert_contains "$node_msg" "找不到 Node.js" "仍然说明了缺什么"

# --- mfw missing must NOT claim a fetch would fix it ------------------------
# The managed runtime installs @deepseek-ai/dsh, not dsh-mfw. Offering to fetch
# would send the user through a 470 MB download that leaves them exactly as stuck.
code=$(start_with 'resolve_node() { echo /usr/bin/true; }; resolve_mfw() { return 1; }
                   BACKEND=mfw')
assert_ne "$EXPECTED" "$code" "找不到 dsh-mfw 时不报 EXIT_NEEDS_RUNTIME"
assert_eq "1" "$code" "而是普通失败（退出码 1）"

# --- an ordinary failure keeps 1 --------------------------------------------
assert_eq "1" "$(start_with 'resolve_node() { echo /usr/bin/true; }
                            resolve_dsh() { echo /nonexistent/entry.js; }
                            url_up() { return 1; }
                            pid_alive() { return 1; }')" \
    "子进程起不来是普通失败，不提示安装运行时"

# ===========================================================================
# the app must read the code, and both paths must use it
# ===========================================================================
agent=$(cat "$REPO/LauncherAgent.swift")
assert_contains "$agent" "exitNeedsRuntime: Int32 = 4" "应用侧的常量与 launcher 一致"
assert_contains "$agent" "code == Self.exitNeedsRuntime" "应用按退出码判断，而不是匹配文案"
assert_not_contains "$agent" "looksLikeMissingRuntime" "旧的文案匹配已经移除"
assert_not_contains "$agent" 'detail.contains("runtime install")' "不再按提示文字猜测"

# One presenter, reached from the launch path and from the restart path, so the
# two cannot drift apart again.
assert_contains "$agent" "private func presentStartFailure" "存在统一的失败呈现入口"
launch_path=$(printf '%s' "$agent" | grep -c 'presentStartFailure(' || true)
assert_eq "3" "$launch_path" "定义一次、被两条路径各调用一次"
restart_body=$(sed -n '/private func restartInstance/,/^    }$/p' "$REPO/LauncherAgent.swift")
assert_contains "$restart_body" "presentStartFailure" "切换后端失败时走统一入口"
assert_contains "$restart_body" "restartInstance()" "装完运行时后按切换语义重试（会重载标签）"

# --- what the offer says, and what it shows while working --------------------
# The dialog used to promise Node.js came from the official release, which stopped
# being true once mirrors were configurable; and a download failure is most often
# the network, which is the one problem the mirror setting solves.
#
# Asserted as two tokens rather than a sentence. An earlier version matched whole
# phrases and broke on a rewording that kept every fact intact -- the same coupling
# to prose that let the missing-runtime offer disappear in the first place. What
# has to hold is that the user is told the source is configurable and where.
offer_body=$(sed -n '/private func offerRuntimeInstall/,/^    }$/p' "$REPO/LauncherAgent.swift")
assert_contains "$offer_body" "偏好设置" "运行时提示指向偏好设置"
assert_contains "$offer_body" "下载源" "运行时提示说明下载源可自定义"
install_body=$(sed -n '/private func runRuntimeInstall/,/^    }$/p' "$REPO/LauncherAgent.swift")
assert_contains "$install_body" "偏好设置" "安装失败时指向偏好设置"
assert_contains "$install_body" "下载源" "安装失败时指名下载源"
# Progress is a panel, not an NSAlert: an alert outside a modal session draws a
# default button that does nothing. Both long-running jobs share the one panel.
assert_contains "$install_body" "Self.progressPanel" "安装进度用统一的进度面板"
assert_not_contains "$install_body" "accessoryView = spinner" "不再把 NSAlert 当进度框"
assert_not_contains "$agent" "panel.accessoryView" "全文件都没有残留的 NSAlert 进度框"

finish
