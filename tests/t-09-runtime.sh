#!/bin/bash
# The managed runtime: fetch Node and install dsh into the app's own directory.
#
# Nothing here downloads 48 MB from nodejs.org. A tiny tarball shaped like a Node
# distribution is served from localhost, and the expected checksum is overridden
# to match it -- so the code path under test is the real one, including the part
# that must refuse to unpack a tarball whose checksum does not match.
set -u
TEST_NAME="t-09-runtime"
cd "$(dirname "$0")" || exit 1
. lib/assert.sh

L="$(cd .. && pwd)/launcher"
PORT="${D4M_TEST_PORT:-3182}"

NODE=$(command -v node 2>/dev/null || true)
if [ -z "$NODE" ]; then
    skip "全部用例（本机 PATH 上没有 node，无法起本地 mirror）"
    finish; exit $?
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/d4m-t09.XXXXXX")
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$TMP"
    return 0
}
trap cleanup EXIT

# --- pinned constants must stay well-formed --------------------------------
# Updating Node means updating the version and both checksums together; a stale
# or truncated hash would only surface as a failed download much later.
body=$(cat "$L")
version=$(printf '%s' "$body" | sed -n 's/^MANAGED_NODE_VERSION="\(.*\)"$/\1/p')
sha_arm=$(printf '%s' "$body" | sed -n 's/^MANAGED_NODE_SHA256_ARM64="\(.*\)"$/\1/p')
sha_x64=$(printf '%s' "$body" | sed -n 's/^MANAGED_NODE_SHA256_X64="\(.*\)"$/\1/p')
version_shape=0
case "$version" in v2[0-9].*) version_shape=1 ;; esac
assert_eq "1" "$version_shape" "pinned Node 版本形如 vNN.x（读到 ${version}）"
assert_eq "64" "${#sha_arm}" "arm64 校验和是 64 位十六进制"
assert_eq "64" "${#sha_x64}" "x64 校验和是 64 位十六进制"
assert_ne "$sha_arm" "$sha_x64" "两个架构的校验和不同"

# --- build a stand-in Node distribution ------------------------------------
# Layout mirrors the real tarball: node-<version>-darwin-<arch>/bin/node plus the
# npm CLI where the launcher expects to find it.
arch_dir=$(uname -m); [ "$arch_dir" = "x86_64" ] && arch_dir="x64"
dist_name="node-${version}-darwin-${arch_dir}"
mkdir -p "$TMP/build/$dist_name/bin" "$TMP/build/$dist_name/lib/node_modules/npm/bin"
# Reports the pinned version, and hands everything else to the real node -- the
# subject under test is the launcher's install logic, not node itself.
cat > "$TMP/build/$dist_name/bin/node" <<EOF
#!/bin/sh
case "\$1" in
  --version) echo "$version" ;;
  *) exec "$NODE" "\$@" ;;
esac
EOF
chmod +x "$TMP/build/$dist_name/bin/node"
# A stand-in npm.
#
# It reproduces the layout a *real* `npm install --prefix <dir> <pkg>` produces:
# <dir>/node_modules/<pkg> with the bin link in <dir>/node_modules/.bin. An
# earlier version of this fixture invented the global-install layout instead
# (<dir>/lib/node_modules + <dir>/bin), which made this file pass while a real
# install failed -- a stand-in is only worth anything if it is wrong in no way
# that matters.
cat > "$TMP/build/$dist_name/lib/node_modules/npm/bin/npm-cli.js" <<'EOF'
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const prefixAt = args.indexOf('--prefix');
if (prefixAt < 0) process.exit(1);
const prefix = args[prefixAt + 1];
const pkgDir = path.join(prefix, 'node_modules', '@deepseek-ai', 'dsh');
const binDir = path.join(prefix, 'node_modules', '.bin');
fs.mkdirSync(path.join(pkgDir, 'lib'), { recursive: true });
fs.mkdirSync(binDir, { recursive: true });
fs.writeFileSync(path.join(pkgDir, 'package.json'),
  JSON.stringify({ name: '@deepseek-ai/dsh', version: '9.9.9-test' }, null, 2));
fs.writeFileSync(path.join(pkgDir, 'lib', 'bin.js'), '// stand-in dsh\n');
const link = path.join(binDir, 'dsh');
fs.rmSync(link, { force: true });
fs.symlinkSync('../@deepseek-ai/dsh/lib/bin.js', link);
EOF

mkdir -p "$TMP/mirror/$version"
tar -czf "$TMP/mirror/$version/${dist_name}.tar.gz" -C "$TMP/build" "$dist_name"
good_sha=$(shasum -a 256 "$TMP/mirror/$version/${dist_name}.tar.gz" | awk '{print $1}')

# --- serve it -------------------------------------------------------------
"$NODE" -e '
const http = require("node:http"), fs = require("node:fs"), path = require("node:path");
const root = process.argv[1], port = Number(process.argv[2]);
http.createServer((req, res) => {
  const file = path.join(root, decodeURIComponent(req.url));
  fs.readFile(file, (err, data) => {
    if (err) { res.statusCode = 404; res.end("no"); return; }
    res.end(data);
  });
}).listen(port, "127.0.0.1");
' "$TMP/mirror" "$PORT" &
SERVER_PID=$!
waited=0
while [ "$waited" -lt 50 ]; do
    curl -sf -o /dev/null "http://127.0.0.1:$PORT/$version/${dist_name}.tar.gz" && break
    sleep 0.1; waited=$((waited + 1))
done
if [ "$waited" -ge 50 ]; then
    skip "余下用例（本地 mirror 未能在 ${PORT} 上起来）"
    finish; exit $?
fi

runtime() { # extra env..., then launcher args
    env DSH_LAUNCHER_NODE_DIST="http://127.0.0.1:$PORT" \
        DSH_LAUNCHER_NODE_SHA256="$1" \
        "$L" runtime "$2" --state "$TMP/state" 2>&1
}

# --- checksum mismatch must refuse, and leave nothing behind ---------------
# The most important assertion in this file: a tarball that fails verification
# must not be unpacked, because unpacking it is executing whatever it contains.
out=$(runtime "0000000000000000000000000000000000000000000000000000000000000000" install)
assert_contains "$out" "校验和不匹配" "校验和不匹配时拒绝"
assert_contains "$out" "未解压" "拒绝时明确说明未解压"
assert_false "拒绝后没有留下 node 目录" -- test -e "$TMP/state/runtime/node"
assert_false "拒绝后没有写 manifest" -- test -e "$TMP/state/runtime/manifest.json"

# --- the happy path -------------------------------------------------------
out=$(runtime "$good_sha" install)
assert_contains "$out" "checksum verified" "校验通过时继续"
assert_true "node 已就位" -- test -x "$TMP/state/runtime/node/bin/node"
assert_true "dsh 入口已就位" -- test -e "$TMP/state/runtime/npm/node_modules/.bin/dsh"
assert_true "manifest 已写入" -- test -f "$TMP/state/runtime/manifest.json"
assert_contains "$(cat "$TMP/state/runtime/manifest.json")" "$version" "manifest 记下 node 版本"

# The runtime directory holds executables fetched from the network; nothing else
# on the machine should be able to add to it.
perms=$(stat -f "%Lp" "$TMP/state/runtime")
assert_eq "700" "$perms" "runtime 目录权限为 700"

# --- status reflects reality ----------------------------------------------
out=$(env "$L" runtime status --state "$TMP/state" 2>&1)
assert_contains "$out" "(managed)" "status 报告托管运行时"
assert_contains "$out" "9.9.9-test" "status 读出托管 dsh 的版本"

# --- a second install is a no-op for node ---------------------------------
out=$(runtime "$good_sha" install)
assert_contains "$out" "already installed" "已装同版本时不重复下载"

# --- resolution prefers the user's own tools ------------------------------
# The managed copy is a fallback. A dsh the user installed is the one they
# maintain, so it has to win.
out=$(env DSH_LAUNCHER_STATE="$TMP/state" "$L" runtime status 2>&1)
assert_contains "$out" "resolved dsh" "status 报告实际会用哪个 dsh"
assert_contains "$out" "(managed)" "无系统 dsh 时解析到托管副本"

# --- uninstall removes the runtime and nothing else -----------------------
out=$(env "$L" runtime uninstall --state "$TMP/state" 2>&1)
assert_contains "$out" "removed" "uninstall 报告已删除"
assert_false "runtime 目录已删除" -- test -e "$TMP/state/runtime"
assert_true "状态目录本身仍在" -- test -d "$TMP/state"
assert_contains "$out" "not touched" "uninstall 说明未触碰 DSH 数据"

finish
