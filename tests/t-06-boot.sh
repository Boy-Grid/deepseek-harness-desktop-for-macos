#!/bin/bash
# The boot path end to end -- argument construction, PATH and DSH_HOME handed to
# the child, pid recording, readiness polling, ownership and stop -- against a
# stand-in dsh instead of a real one, so it runs anywhere node does.
set -u
TEST_NAME="t-06-boot"
cd "$(dirname "$0")" || exit 1
. lib/assert.sh

L="$(cd .. && pwd)/launcher"
FAKE_DSH="$(pwd)/fixtures/fake-dsh.mjs"
FAKE_MFW="$(pwd)/fixtures/fake-mfw.mjs"
PORT="${D4M_TEST_PORT:-3179}"

NODE=$(command -v node 2>/dev/null || true)
if [ -z "$NODE" ]; then
    skip "全部用例（本机 PATH 上没有 node）"
    finish; exit $?
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/d4m-t06.XXXXXX")
cleanup() {
    "$L" stop --port "$PORT" --state "$TMP/stock" >/dev/null 2>&1
    "$L" stop --port "$PORT" --state "$TMP/mfw" --backend mfw >/dev/null 2>&1
    rm -rf "$TMP"
    return 0
}
trap cleanup EXIT

serving() { curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT" 2>/dev/null; }
if serving; then
    skip "全部用例（端口 ${PORT} 已被占用，设 D4M_TEST_PORT 换一个）"
    finish; exit $?
fi

# The launcher runs the entry with the node it resolved, so the stand-in has to
# be reachable as a plain script argument -- exactly how the real dsh entry is.
HOME_DIR="$TMP/dsh-home"

# ===========================================================================
# stock backend
# ===========================================================================
out=$("$L" start --port "$PORT" --state "$TMP/stock" --dsh "$FAKE_DSH" \
        --dsh-home "$HOME_DIR" 2>&1)
LOG="$TMP/stock/logs/web.log"
assert_contains "$out" "web UI is up" "stock：启动成功"
assert_true "stock：端口在提供服务" -- serving
assert_true "stock：pid 文件已写入" -- test -s "$TMP/stock/web.pid"

log_body=$(cat "$LOG" 2>/dev/null || true)
assert_contains "$log_body" "--profile web" "stock：传了 --profile web"
assert_contains "$log_body" "--no-open" "stock：传了 --no-open（否则会另开系统浏览器）"
assert_contains "$log_body" "DSH_HOME=$HOME_DIR" "stock：DSH_HOME 显式传给子进程"
assert_contains "$log_body" "listening on 127.0.0.1:$PORT" "stock：子进程确实在监听指定端口"

assert_contains "$("$L" status --port "$PORT" --state "$TMP/stock")" "this launcher" \
    "stock：归属判定为自己"

out=$("$L" stop --port "$PORT" --state "$TMP/stock" 2>&1)
assert_contains "$out" "web UI stopped" "stock：停止成功"
assert_false "stock：端口已释放" -- serving
assert_false "stock：pid 文件已清理" -- test -f "$TMP/stock/web.pid"

# ===========================================================================
# mfw backend
# ===========================================================================
major=$("$NODE" --version 2>/dev/null | sed 's/^v//; s/\..*//')
pm=$(command -v pnpm 2>/dev/null || command -v corepack 2>/dev/null || true)
if [ "${major:-0}" -lt 22 ]; then
    skip "mfw 用例（本机 node 是 v${major}，低于 mfw 要求的 22）"
elif [ -z "$pm" ]; then
    skip "mfw 用例（本机找不到 pnpm/corepack，mfw 后端会被前置检查拦下）"
else
    out=$("$L" start --backend mfw --port "$PORT" --state "$TMP/mfw" \
            --mfw "$FAKE_MFW" --dsh "$FAKE_DSH" --dsh-home "$HOME_DIR" 2>&1)
    LOG="$TMP/mfw/logs/web.log"
    assert_contains "$out" "web UI is up" "mfw：启动成功"
    assert_contains "$out" "package manager for mfw" "mfw：日志记下解析到的包管理器"
    assert_contains "$out" "preparing the mfw runtime" "mfw：先跑 provision 再 boot"

    log_body=$(cat "$LOG" 2>/dev/null || true)
    assert_contains "$log_body" "ready to boot" "mfw：provision 的输出进了日志"
    assert_contains "$log_body" "argv web --host" "mfw：把 web 作为首个参数透传"
    assert_contains "$log_body" "--no-open" "mfw：同样传了 --no-open"
    # dsh-mfw supplies --profile mfw itself; a second one would collide.
    assert_not_contains "$log_body" "--profile" "mfw：启动参数里不含 --profile"

    # The recorded pid is dsh-mfw itself here, with the server one level below --
    # the case the single-chain ownership walk used to get wrong.
    pid=$(cat "$TMP/mfw/web.pid")
    assert_contains "$("$L" status --backend mfw --port "$PORT" --state "$TMP/mfw")" "this launcher" \
        "mfw：归属判定为自己（监听者是记录 pid 的后代）"

    out=$("$L" stop --backend mfw --port "$PORT" --state "$TMP/mfw" 2>&1)
    assert_contains "$out" "web UI stopped" "mfw：停止成功"
    assert_false "mfw：整棵进程树都退了（无孤儿）" -- kill -0 "$pid"
    assert_false "mfw：端口已释放" -- serving
fi

# ===========================================================================
# a child that dies immediately must be reported at once, not after the
# readiness timeout
# ===========================================================================
started=$(date +%s)
out=$("$L" start --port "$PORT" --state "$TMP/fail" \
        --dsh "$(pwd)/fixtures/fake-dsh-crash.mjs" --dsh-home "$HOME_DIR" 2>&1 || true)
elapsed=$(( $(date +%s) - started ))
assert_contains "$out" "exited early" "子进程立刻退出时如实报出"
assert_contains "$out" "exiting 3 on purpose" "报错带上日志尾部，指向真实原因"
assert_true "报错发生在就绪超时之前（用了 ${elapsed}s，远小于 60s）" -- test "$elapsed" -lt 15
assert_false "失败后不留 pid 记录的服务" -- serving

finish
