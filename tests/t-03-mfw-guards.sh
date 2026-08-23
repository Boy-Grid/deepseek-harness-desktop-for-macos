#!/bin/bash
# The guards in front of the mfw backend: baseline-vs-installed version skew,
# the Node floor, and a reachable package manager.
#
# Fully hermetic -- a fake node, a fake dsh and a fake dsh-mfw are built in a
# temp dir, so this runs identically on a machine with neither installed.
set -u
TEST_NAME="t-03-mfw-guards"
cd "$(dirname "$0")" || exit 1
. lib/assert.sh

L="$(cd .. && pwd)/launcher"
# A port of its own. Without one these cases run against 3080, where a real
# instance may well be listening -- and the "port is busy with somebody else's
# server" check fires before the guards under test ever run.
PORT="${D4M_TEST_PORT:-3181}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/d4m-t03.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT" 2>/dev/null; then
    skip "全部用例（端口 ${PORT} 已被占用，设 D4M_TEST_PORT 换一个）"
    finish; exit $?
fi

# --- fixtures ---------------------------------------------------------------
# A node stand-in: answers --version, and exits 42 for anything else.  Reaching
# that 42 is how a test proves it got all the way past the guards to provision.
make_node() { # dir version
    mkdir -p "$1"
    cat > "$1/node" <<EOF
#!/bin/sh
case "\$1" in
  --version) echo "$2" ;;
  *) exit 42 ;;
esac
EOF
    chmod +x "$1/node"
}

# A package manager stand-in, so pnpm_locate has something to find.
make_pnpm() { mkdir -p "$1"; printf '#!/bin/sh\nexit 0\n' > "$1/pnpm"; chmod +x "$1/pnpm"; }

make_dsh() { # root version
    mkdir -p "$1/node_modules/@deepseek-ai/dsh/lib" "$1/node_modules/.bin"
    printf '{\n  "name": "@deepseek-ai/dsh",\n  "version": "%s"\n}\n' "$2" \
        > "$1/node_modules/@deepseek-ai/dsh/package.json"
    printf '#!/bin/sh\nexit 0\n' > "$1/node_modules/@deepseek-ai/dsh/lib/bin.js"
    chmod +x "$1/node_modules/@deepseek-ai/dsh/lib/bin.js"
    ln -sf "../@deepseek-ai/dsh/lib/bin.js" "$1/node_modules/.bin/dsh"
}

make_mfw() { # root baseline
    mkdir -p "$1/lib"
    printf '{\n  "name": "@boy_grid/dsh-mfw",\n  "version": "0.1.0",\n  "dshMfw": { "baseVersion": "%s", "profile": "mfw" }\n}\n' \
        "$2" > "$1/package.json"
    printf '#!/bin/sh\nexit 0\n' > "$1/lib/bin.js"
}

make_node "$TMP/bin22" "v22.22.3"
make_pnpm "$TMP/bin22"
make_node "$TMP/bin18" "v18.20.1"
make_pnpm "$TMP/bin18"
make_dsh "$TMP/dsh-0111" "0.1.1-rc.2"
make_dsh "$TMP/dsh-none" "0.0.0"; rm -f "$TMP/dsh-none/node_modules/@deepseek-ai/dsh/package.json"
make_mfw "$TMP/mfw-match" "0.1.1-rc.2"
make_mfw "$TMP/mfw-skew"  "9.9.9"

DSH_OK="$TMP/dsh-0111/node_modules/.bin/dsh"
DSH_NOPKG="$TMP/dsh-none/node_modules/.bin/dsh"

# Every invocation gets a fresh state dir so nothing is cached between cases.
attempt() { # mfw-root [extra launcher args...]
    local mfw="$1"; shift
    rm -rf "$TMP/state"
    "$L" start --backend mfw --port "$PORT" \
        --state "$TMP/state" \
        --node "$TMP/bin22/node" \
        --mfw "$mfw/lib/bin.js" \
        "$@" 2>&1
}

SKEW_MSG="两者已错开"
PAST_GUARDS="退出码 42"   # the fake node's exit code, reached only at provision

# --- A: shared home + drifted versions -> refuse ----------------------------
out=$(attempt "$TMP/mfw-skew" --dsh "$DSH_OK")
assert_contains "$out" "$SKEW_MSG" "版本错开 + 共享 home → 拒绝启动"
assert_contains "$out" "9.9.9" "拒绝信息里点明 mfw 的基线"
assert_contains "$out" "0.1.1-rc.2" "拒绝信息里点明已安装的 dsh 版本"
assert_contains "$out" "--dsh-home" "拒绝信息给出独立 home 的出路"
assert_not_contains "$out" "$PAST_GUARDS" "被拒时不会继续去 provision"

# --- B: drifted, but an isolated home -> allowed ----------------------------
out=$(attempt "$TMP/mfw-skew" --dsh "$DSH_OK" --dsh-home "$TMP/isolated-home")
assert_not_contains "$out" "$SKEW_MSG" "独立 home 时不拦"
assert_contains "$out" "$PAST_GUARDS" "反向验证：确实走到了 provision"

# --- C: drifted, escape hatch -> allowed ------------------------------------
out=$(attempt "$TMP/mfw-skew" --dsh "$DSH_OK" --allow-version-skew)
assert_not_contains "$out" "$SKEW_MSG" "--allow-version-skew 跳过检查"
assert_contains "$out" "$PAST_GUARDS" "反向验证：确实走到了 provision"

# --- D: versions match -> allowed (the non-regression that matters) ---------
out=$(attempt "$TMP/mfw-match" --dsh "$DSH_OK")
assert_not_contains "$out" "$SKEW_MSG" "版本一致时不得误拦"
assert_contains "$out" "$PAST_GUARDS" "版本一致时正常进入 provision"

# --- E: nothing to compare -> allowed, no invented mismatch -----------------
out=$(attempt "$TMP/mfw-skew" --dsh "$DSH_NOPKG")
assert_not_contains "$out" "$SKEW_MSG" "读不到已安装版本时不臆造错开"
assert_contains "$out" "$PAST_GUARDS" "缺信息时放行"

# --- F: Node floor ----------------------------------------------------------
rm -rf "$TMP/state"
out=$("$L" start --backend mfw --port "$PORT" --state "$TMP/state" \
        --node "$TMP/bin18/node" --mfw "$TMP/mfw-match/lib/bin.js" --dsh "$DSH_OK" 2>&1)
assert_contains "$out" "Node.js >= 22" "Node 低于 22 时拒绝 mfw"
assert_contains "$out" "v18" "报错点明当前版本"
assert_not_contains "$out" "$PAST_GUARDS" "Node 太旧时不会继续"

# stock backend has no declared floor upstream, so it must not inherit this gate
rm -rf "$TMP/state"
out=$("$L" start --port "$PORT" --state "$TMP/state" --node "$TMP/bin18/node" --dsh "$DSH_OK" 2>&1)
assert_not_contains "$out" "Node.js >= 22" "stock 后端不施加 Node 22 门槛"

# --- G: no package manager reachable ---------------------------------------
# Only meaningful when the environment really has none; a dev machine usually
# has pnpm or corepack somewhere on the fallback PATH.
NOPM_HOME="$TMP/nopm-home"; mkdir -p "$NOPM_HOME"
make_node "$TMP/bin-nopm" "v22.22.3"      # deliberately without a pnpm beside it
probe=$(env -i HOME="$NOPM_HOME" PATH="$TMP/bin-nopm:/opt/homebrew/bin:/usr/local/bin:$NOPM_HOME/.local/bin:/usr/bin:/bin" \
    sh -c 'command -v pnpm || command -v corepack' 2>/dev/null)
if [ -n "$probe" ]; then
    skip "无包管理器用例（本机在回退 PATH 上找得到 ${probe}）"
else
    rm -rf "$TMP/state"
    out=$(env -i HOME="$NOPM_HOME" PATH="/usr/bin:/bin" "$L" start --backend mfw --port "$PORT" \
            --state "$TMP/state" --node "$TMP/bin-nopm/node" \
            --mfw "$TMP/mfw-match/lib/bin.js" --dsh "$DSH_OK" 2>&1)
    assert_contains "$out" "pnpm" "找不到包管理器时明确报出来"
    assert_not_contains "$out" "$PAST_GUARDS" "找不到包管理器时不会继续"
fi

# --- mfw mode must not pass --profile (dsh-mfw supplies its own) -----------
rm -rf "$TMP/state"
out=$(attempt "$TMP/mfw-match" --dsh "$DSH_OK")
assert_not_contains "$out" "--profile" "mfw 模式的启动命令里不含 --profile"
out=$("$L" start --port "$PORT" --state "$TMP/state2" --node "$TMP/bin22/node" --dsh "$DSH_OK" 2>&1)
rm -rf "$TMP/state2"
assert_contains "$out" "--profile web" "stock 模式仍传 --profile web"

finish
