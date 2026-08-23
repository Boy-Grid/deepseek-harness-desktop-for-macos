#!/bin/bash
# The promise this app is asked to be trusted on: it only ever stops a server it
# started itself, and a port held by anything else is left alone.
#
# A tiny HTTP server stands in for "somebody else's dsh".  Needs node; skipped
# without one.
set -u
TEST_NAME="t-04-safety"
cd "$(dirname "$0")" || exit 1
. lib/assert.sh

L="$(cd .. && pwd)/launcher"
FIXTURE="$(pwd)/fixtures/tiny-http.mjs"
PORT="${D4M_TEST_PORT:-3178}"

NODE=$(command -v node 2>/dev/null || true)
if [ -z "$NODE" ]; then
    skip "全部用例（本机 PATH 上没有 node，无法起替身服务）"
    finish
    exit $?
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/d4m-t04.XXXXXX")
INTRUDER=""
DECOY=""
cleanup() {
    [ -n "$INTRUDER" ] && kill -9 "$INTRUDER" 2>/dev/null
    [ -n "$DECOY" ] && kill -9 "$DECOY" 2>/dev/null
    rm -rf "$TMP"
    return 0
}
trap cleanup EXIT

launcher() { "$L" "$@" --port "$PORT" --state "$TMP/state" 2>&1; }
serving() { curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT" 2>/dev/null; }

# Refuse to run against a port that is already busy for unrelated reasons.
if serving; then
    skip "全部用例（端口 ${PORT} 已被占用，设 D4M_TEST_PORT 换一个）"
    finish
    exit $?
fi

start_intruder() {
    "$NODE" "$FIXTURE" "$PORT" >/dev/null 2>&1 &
    INTRUDER=$!
    local waited=0
    while [ "$waited" -lt 50 ]; do
        serving && return 0
        sleep 0.1; waited=$((waited + 1))
    done
    return 1
}

mkdir -p "$TMP/state/logs"
if ! start_intruder; then
    skip "全部用例（替身服务未能在 ${PORT} 上起来）"
    finish
    exit $?
fi

# --- A: a foreign server and no pid file of ours -----------------------------
assert_contains "$(launcher status)" "another process" "无 pid 记录时 status 判定为他人的服务"
assert_exit 1 "无 pid 记录时 stop 拒绝动手" -- "$L" stop --port "$PORT" --state "$TMP/state"
assert_contains "$(launcher stop)" "did not start it" "拒绝时说明原因"
assert_true "替身服务未被误杀" -- kill -0 "$INTRUDER"
assert_true "替身服务仍在提供服务" -- serving

# --- B: a stale pid file whose pid is dead ----------------------------------
# A pid that has certainly exited.
sleep 0.01 & dead=$!; wait "$dead" 2>/dev/null
echo "$dead" > "$TMP/state/web.pid"
assert_contains "$(launcher status)" "another process" "死 pid 记录时 status 仍判定为他人的"
assert_exit 1 "死 pid 记录时 stop 拒绝" -- "$L" stop --port "$PORT" --state "$TMP/state"
assert_true "替身服务未被误杀（死 pid 情形）" -- kill -0 "$INTRUDER"

# --- C: a live pid that is not the listener (pid reuse / port takeover) -----
# This is the hole the ownership check closes: before it, stop trusted the pid
# file and signalled a process that had nothing to do with the port.
sleep 120 >/dev/null 2>&1 &
DECOY=$!
echo "$DECOY" > "$TMP/state/web.pid"
out=$(launcher stop)
assert_contains "$out" "not in its process tree" "活 pid 但不是监听者 → 拒绝并说明"
assert_true "无关进程未被误杀" -- kill -0 "$DECOY"
assert_true "替身服务未被误杀（pid 复用情形）" -- kill -0 "$INTRUDER"
assert_true "替身服务仍在提供服务" -- serving
kill -9 "$DECOY" 2>/dev/null; DECOY=""

# --- D: the listener really is the recorded process -> stop works -----------
echo "$INTRUDER" > "$TMP/state/web.pid"
assert_contains "$(launcher status)" "this launcher" "记录的 pid 就是监听者 → 判定为自己的"
out=$(launcher stop)
assert_contains "$out" "web UI stopped" "确属自己时 stop 正常执行"
# stop must not return until the tree is actually gone -- no sleep here on purpose
assert_false "stop 返回时进程已退出（不留孤儿）" -- kill -0 "$INTRUDER"
assert_false "端口已释放" -- serving
assert_false "pid 文件已清理" -- test -f "$TMP/state/web.pid"
INTRUDER=""

# --- E: nothing serving at all ---------------------------------------------
assert_contains "$(launcher stop)" "nothing is serving" "端口空闲时 stop 是无操作"
assert_exit 0 "端口空闲时 stop 返回成功" -- "$L" stop --port "$PORT" --state "$TMP/state"

finish
