#!/bin/bash
# Switching backends on the same port.
#
# The failure this pins down: an instance started under one backend can only be
# stopped under that same backend (its pid file lives in that backend's state
# dir). If `start` treats "something already answers on the port" as success
# regardless of who owns it, a switch silently does nothing -- the old instance
# survives, the new backend never boots, and every caller believes it worked.
set -u
TEST_NAME="t-07-backend-switch"
cd "$(dirname "$0")" || exit 1
. lib/assert.sh

L="$(cd .. && pwd)/launcher"
FAKE_DSH="$(pwd)/fixtures/fake-dsh.mjs"
FAKE_MFW="$(pwd)/fixtures/fake-mfw.mjs"
PORT="${D4M_TEST_PORT:-3180}"

NODE=$(command -v node 2>/dev/null || true)
if [ -z "$NODE" ]; then
    skip "全部用例（本机 PATH 上没有 node）"
    finish; exit $?
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/d4m-t07.XXXXXX")
cleanup() {
    "$L" stop --backend stock --port "$PORT" --state "$TMP/stock" >/dev/null 2>&1
    "$L" stop --backend mfw --port "$PORT" --state "$TMP/mfw" >/dev/null 2>&1
    rm -rf "$TMP"
    return 0
}
trap cleanup EXIT

serving() { curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT" 2>/dev/null; }
if serving; then
    skip "全部用例（端口 ${PORT} 已被占用，设 D4M_TEST_PORT 换一个）"
    finish; exit $?
fi

stock() { "$L" "$1" --backend stock --port "$PORT" --state "$TMP/stock" --dsh "$FAKE_DSH" 2>&1; }
mfw() {
    "$L" "$1" --backend mfw --port "$PORT" --state "$TMP/mfw" \
        --mfw "$FAKE_MFW" --dsh "$FAKE_DSH" 2>&1
}

pm=$(command -v pnpm 2>/dev/null || command -v corepack 2>/dev/null || true)
major=$("$NODE" --version 2>/dev/null | sed 's/^v//; s/\..*//')
mfw_runnable=1
if [ "${major:-0}" -lt 22 ] || [ -z "$pm" ]; then
    mfw_runnable=0
fi

# --- start under stock ------------------------------------------------------
out=$(stock start)
assert_contains "$out" "web UI is up" "stock 后端启动成功"
assert_true "端口在提供服务" -- serving

# --- the mfw backend must refuse to adopt it -------------------------------
# This is the core assertion: before the fix, `start` printed "already
# responding — nothing to start" and returned 0 here, which is what made the
# GUI's backend switch look successful while changing nothing.
out=$(mfw start)
assert_contains "$out" "不是本后端" "mfw 的 start 认出端口上的服务不是自己的"
assert_exit 1 "mfw 的 start 因此失败而不是假装成功" -- \
    "$L" start --backend mfw --port "$PORT" --state "$TMP/mfw" --mfw "$FAKE_MFW" --dsh "$FAKE_DSH"
assert_true "拒绝之后 stock 实例仍在运行" -- serving

# --- stopping under the wrong backend must be refused ----------------------
out=$(mfw stop)
assert_contains "$out" "did not start it" "用 mfw 去 stop 一个 stock 实例被拒绝"
assert_true "被拒后 stock 实例仍在运行" -- serving

# --- ownership is reported per backend -------------------------------------
assert_contains "$(stock status)" "this launcher" "stock 认得这是自己的实例"
assert_contains "$(mfw status)" "another process" "mfw 判定这不是自己的实例"

# --- the correct order does work -------------------------------------------
out=$(stock stop)
assert_contains "$out" "web UI stopped" "用 stock 停掉 stock 实例"
assert_false "端口已释放" -- serving

if [ "$mfw_runnable" -eq 0 ]; then
    skip "以 mfw 重启（本机缺 node>=22 或 pnpm/corepack）"
else
    out=$(mfw start)
    assert_contains "$out" "web UI is up" "端口空出来后 mfw 启动成功"
    assert_contains "$(mfw status)" "this launcher" "现在归属判定为 mfw"
    assert_contains "$(stock status)" "another process" "stock 不再认领它"
    out=$(mfw stop)
    assert_contains "$out" "web UI stopped" "用 mfw 停掉 mfw 实例"
    assert_false "端口已释放" -- serving
fi

finish
