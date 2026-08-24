#!/bin/bash
# The bind host and Host-header fence knobs.
#
# What matters here is not just that the flags arrive, but the two properties the
# feature rests on:
#
#   * loopback stays the default, and leaving it is announced, because the
#     DeepSeek Harness UI carries no authentication -- reachable means operable;
#   * readiness is probed over loopback regardless of what was bound, since
#     0.0.0.0 names an interface to listen on, not an address to connect to.
set -u
TEST_NAME="t-10-bind"
cd "$(dirname "$0")" || exit 1
. lib/assert.sh

L="$(cd .. && pwd)/launcher"
FAKE_DSH="$(pwd)/fixtures/fake-dsh.mjs"
PORT="${D4M_TEST_PORT:-3181}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/d4m-t10.XXXXXX")
cleanup() {
    "$L" stop --port "$PORT" --state "$TMP/any" >/dev/null 2>&1
    "$L" stop --port "$PORT" --state "$TMP/trust" >/dev/null 2>&1
    rm -rf "$TMP"
    return 0
}
trap cleanup EXIT

# ===========================================================================
# classification and defaults -- pure string work, nothing is bound
# ===========================================================================
st=$("$L" status --port "$PORT" --state "$TMP/s1")
assert_contains "$st" "bind:    127.0.0.1" "默认绑定 127.0.0.1"
assert_not_contains "$st" "no authentication" "默认绑定不该出现暴露提示"
assert_contains "$st" "url:     http://127.0.0.1:$PORT" "默认探测地址是 loopback"

for h in localhost ::1 127.0.0.5; do
    st=$("$L" status --port "$PORT" --state "$TMP/s1" --host "$h")
    assert_not_contains "$st" "no authentication" "$h 判定为 loopback，不提示暴露"
done

for h in 0.0.0.0 192.168.1.50 ::; do
    st=$("$L" status --port "$PORT" --state "$TMP/s1" --host "$h")
    assert_contains "$st" "no authentication" "$h 判定为对外可达，明确提示无认证"
    # The probe address is independent of the bind address, always.
    assert_contains "$st" "url:     http://127.0.0.1:$PORT" "绑定 $h 时探测仍走 loopback"
done

# Both spellings of every knob, including the environment form the app uses.
assert_contains "$("$L" status --port "$PORT" --state "$TMP/s1" --host=0.0.0.0)" \
    "bind:    0.0.0.0" "--host=<v> 等价于 --host <v>"
assert_contains "$(DSH_LAUNCHER_HOST=0.0.0.0 "$L" status --port "$PORT" --state "$TMP/s1")" \
    "bind:    0.0.0.0" "DSH_LAUNCHER_HOST 生效"

# ===========================================================================
# the fence list accumulates instead of overwriting
# ===========================================================================
st=$("$L" status --port "$PORT" --state "$TMP/s1" \
        --trusted-host dsh.local --trusted-host=box:3080 --trusted-host 10.0.0.9)
assert_contains "$st" "trusted: dsh.local box:3080 10.0.0.9" "--trusted-host 可重复，按序累积"
assert_not_contains "$("$L" status --port "$PORT" --state "$TMP/s1")" "trusted:" \
    "没传时不显示 trusted 行"
assert_contains "$(DSH_LAUNCHER_TRUSTED_HOSTS=$'a.local\nb.local' "$L" status \
        --port "$PORT" --state "$TMP/s1")" "trusted: a.local b.local" \
    "DSH_LAUNCHER_TRUSTED_HOSTS 按换行分隔"

# ===========================================================================
# what actually reaches the child
# ===========================================================================
NODE=$(command -v node 2>/dev/null || true)
serving() { curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT" 2>/dev/null; }
if [ -z "$NODE" ]; then
    skip "启动类用例（本机 PATH 上没有 node）"
elif serving; then
    skip "启动类用例（端口 $PORT 已被占用，设 D4M_TEST_PORT 换一个）"
else
    # A run that never leaves loopback: the fence authorities still have to be
    # forwarded one flag per authority, which is how --trusted-host is declared.
    out=$("$L" start --port "$PORT" --state "$TMP/trust" --dsh "$FAKE_DSH" \
            --dsh-home "$TMP/home" --trusted-host dsh.local --trusted-host box:3080 2>&1)
    assert_contains "$out" "web UI is up" "loopback + trusted-host：启动成功"
    assert_not_contains "$out" "no authentication" "仅本机绑定时不发暴露警告"
    body=$(cat "$TMP/trust/logs/web.log" 2>/dev/null || true)
    assert_contains "$body" "--host 127.0.0.1" "子进程收到显式 --host 127.0.0.1"
    assert_contains "$body" "--trusted-host dsh.local --trusted-host box:3080" \
        "两个 authority 各自成一个 --trusted-host，而非并入一个"
    "$L" stop --port "$PORT" --state "$TMP/trust" >/dev/null 2>&1

    # Binding every interface is the case the feature exists for, and the one
    # where the loopback probe carries its weight: the child listens on 0.0.0.0
    # while readiness is checked against 127.0.0.1.  The stand-in serves a fixed
    # string for the second or two this takes.
    out=$("$L" start --port "$PORT" --state "$TMP/any" --dsh "$FAKE_DSH" \
            --dsh-home "$TMP/home" --host 0.0.0.0 2>&1)
    assert_contains "$out" "web UI is up" "绑定 0.0.0.0 时就绪探测仍能成功"
    assert_contains "$out" "没有任何认证" "对外绑定时把后果讲清楚，而不是只说注意安全"
    body=$(cat "$TMP/any/logs/web.log" 2>/dev/null || true)
    assert_contains "$body" "--host 0.0.0.0" "子进程收到 --host 0.0.0.0"
    assert_contains "$body" "listening on 0.0.0.0:$PORT" "子进程确实在所有接口上监听"
    assert_contains "$body" "launcher: 警告" "警告同时落进日志，便于事后追溯"
    assert_true "对外绑定时 loopback 依然可达" -- serving
    "$L" stop --port "$PORT" --state "$TMP/any" >/dev/null 2>&1
    assert_false "停止后端口已释放" -- serving
fi

finish
