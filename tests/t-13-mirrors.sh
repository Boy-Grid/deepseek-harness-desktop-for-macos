#!/bin/bash
# The npm / Node.js mirror selection.
#
# The load-bearing assertion is the last group: choosing a Node mirror must not
# move the checksum. The expected SHA-256 is pinned in the launcher, so a mirror is
# a convenience rather than a trust decision -- but only for as long as nothing
# lets the mirror supply the hash as well.
set -u
TEST_NAME="t-13-mirrors"
cd "$(dirname "$0")" || exit 1
. lib/assert.sh

L="$(cd .. && pwd)/launcher"
REPO="$(cd .. && pwd)"
MIRROR_PORT="${D4M_TEST_MIRROR_PORT:-3185}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/d4m-t13.XXXXXX")
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$TMP"
    return 0
}
trap cleanup EXIT

rt() { "$L" --state "$TMP/state" "$@" runtime status 2>&1; }

# ===========================================================================
# defaults: inherit npm's own configuration, and only Node gets a fixed default
# ===========================================================================
# Passing a registry by default would override the ~/.npmrc that carries a user's
# proxy and credentials -- exactly the setup the people who need mirrors have.
out=$(rt)
assert_contains "$out" "跟随 ~/.npmrc" "默认不指定 registry，沿用用户自己的配置"
assert_contains "$out" "node dist     https://nodejs.org/dist" "Node 默认走官方"
assert_not_contains "$out" "mirror  " "未选镜像时不显示 mirror 行"

# ===========================================================================
# presets
# ===========================================================================
assert_contains "$(rt --mirror npmmirror)" "npm registry  https://registry.npmmirror.com" \
    "npmmirror 预设给出 registry"
assert_contains "$(rt --mirror npmmirror)" "node dist     https://npmmirror.com/mirrors/node" \
    "npmmirror 预设给出 Node 源"
assert_contains "$(rt --mirror tencent)" "mirrors.cloud.tencent.com/npm" "腾讯云预设"
assert_contains "$(rt --mirror huawei)" "repo.huaweicloud.com" "华为云预设"
assert_contains "$(rt --mirror npmjs)" "https://registry.npmjs.org" \
    "npmjs 预设显式指向官方（用于覆盖坏掉的 ~/.npmrc）"
assert_contains "$(rt --mirror=npmmirror)" "registry.npmmirror.com" "--mirror=<v> 等价写法"
assert_contains "$(DSH_LAUNCHER_MIRROR=npmmirror "$L" --state "$TMP/state" runtime status 2>&1)" \
    "registry.npmmirror.com" "DSH_LAUNCHER_MIRROR 生效"

# `mirrors` has to list every preset, or the built-in set is undiscoverable.
listing=$("$L" mirrors 2>&1)
for name in npmjs npmmirror tencent huawei; do
    assert_contains "$listing" "$name" "mirrors 列出 $name"
done
assert_contains "$listing" "固定写在本脚本里" "mirrors 说明校验和是固定的"
assert_contains "$listing" "信任选择" "mirrors 说明换 registry 是信任选择"

# ===========================================================================
# precedence and validation
# ===========================================================================
# A preset fills only the half that was not given, so one override is possible.
out=$(rt --mirror tencent --registry https://registry.npmjs.org)
assert_contains "$out" "npm registry  https://registry.npmjs.org" "--registry 覆盖预设的 registry"
assert_contains "$out" "nodejs-release" "被覆盖的那一半之外，预设仍然生效"
out=$(rt --mirror tencent --node-mirror https://example.com/node)
assert_contains "$out" "node dist     https://example.com/node" "--node-mirror 覆盖预设的 Node 源"
assert_contains "$out" "mirrors.cloud.tencent.com/npm" "registry 仍来自预设"

assert_exit 2 "未知镜像名以 2 退出" -- "$L" --state "$TMP/state" --mirror nosuch runtime status
assert_contains "$(rt --mirror nosuch)" "expected one of: npmjs npmmirror tencent huawei" \
    "未知镜像名列出可选值"

# A typo that is not an absolute URL must be refused here rather than surfacing
# later as an unreadable npm error.
for bad in registry.npmmirror.com "file:///etc" "https://" "ftp://a.b"; do
    assert_exit 2 "「${bad}」作为 registry 被拒" -- \
        "$L" --state "$TMP/state" --registry "$bad" runtime status
    assert_exit 2 "「${bad}」作为 Node 源被拒" -- \
        "$L" --state "$TMP/state" --node-mirror "$bad" runtime status
done
# An internal registry over plain http is a real setup, so it has to be accepted.
# `runtime status` reports "nothing installed" with a non-zero exit of its own, so
# what is checked is that it is not 2 -- the code the argument check uses.
good_rc=0
"$L" --state "$TMP/state" --registry http://npm.internal.example/ runtime status \
    >/dev/null 2>&1 || good_rc=$?
assert_ne "2" "$good_rc" "内网 http registry 未被参数校验拒绝"
assert_contains "$(rt --registry http://npm.internal.example/)" "http://npm.internal.example/" \
    "内网 http registry 被采用"

# ===========================================================================
# the two mirror tables have to agree
# ===========================================================================
# The launcher needs the table without the app, and the app needs it without
# spawning the launcher for every menu redraw. Drift would show a user one mirror
# in the popup and fetch from another.
if ! command -v swiftc >/dev/null 2>&1; then
    skip "两张表的一致性（本机没有 swiftc）"
else
    PROBE="$TMP/probe"
    if swiftc -O -o "$PROBE" "$REPO/Preferences.swift" "$REPO/TabStore.swift" \
            "$(pwd)/fixtures/exposure-probe.swift" >"$TMP/build.log" 2>&1; then
        for name in npmjs npmmirror tencent huawei; do
            assert_eq "$("$L" --state "$TMP/state" --mirror "$name" runtime status 2>&1 \
                    | sed -n 's/^npm registry  //p')" \
                "$("$PROBE" mirror-registry "$name")" \
                "$name 的 registry 在 launcher 与应用中一致"
            assert_eq "$("$L" --state "$TMP/state" --mirror "$name" runtime status 2>&1 \
                    | sed -n 's/^node dist     //p')" \
                "$("$PROBE" mirror-node "$name")" \
                "$name 的 Node 源在 launcher 与应用中一致"
        done
        # Inherit and custom deliberately carry no URLs, and pass no --mirror.
        assert_eq "<none>" "$("$PROBE" mirror-registry "")" "inherit 不带 registry"
        assert_eq "<none>" "$("$PROBE" mirror-preset "")" "inherit 不传 --mirror"
        assert_eq "<none>" "$("$PROBE" mirror-preset custom)" "custom 不传 --mirror"
        assert_eq "npmmirror" "$("$PROBE" mirror-preset npmmirror)" "预设按名字传 --mirror"
        assert_eq "(inherit)|npmjs|npmmirror|tencent|huawei|custom" "$("$PROBE" mirror-names)" \
            "应用侧的选项集合与预期一致"
        # URL validation must agree too, or the app would accept what the launcher
        # then refuses at startup.
        for good in https://registry.npmmirror.com http://a.b/c; do
            assert_eq "yes" "$("$PROBE" mirror-url "$good")" "应用接受 $good"
        done
        for bad in registry.npmmirror.com "file:///etc" "https://" "https://host."; do
            assert_eq "no" "$("$PROBE" mirror-url "$bad")" "应用拒绝 $bad"
        done
    else
        skip "两张表的一致性（探针编译失败）"
    fi
fi

# ===========================================================================
# a mirror must not be able to supply its own checksum
# ===========================================================================
NODE=$(command -v node 2>/dev/null || true)
if [ -z "$NODE" ]; then
    skip "校验和用例（本机 PATH 上没有 node）"
    finish; exit $?
fi

# A stand-in "mirror" serving a tarball that is not the pinned Node build.
version=$(sed -n 's/^MANAGED_NODE_VERSION="\(.*\)"/\1/p' "$L")
arch=$(uname -m); [ "$arch" = "x86_64" ] && arch=x64
dist_name="node-${version}-darwin-${arch}"
mkdir -p "$TMP/build/$dist_name/bin" "$TMP/mirror/mirrors/node/$version"
printf '#!/bin/bash\necho v0.0.0\n' > "$TMP/build/$dist_name/bin/node"
chmod +x "$TMP/build/$dist_name/bin/node"
tar -czf "$TMP/mirror/mirrors/node/$version/${dist_name}.tar.gz" -C "$TMP/build" "$dist_name"
impostor_sha=$(shasum -a 256 "$TMP/mirror/mirrors/node/$version/${dist_name}.tar.gz" | awk '{print $1}')

"$NODE" -e '
const http = require("node:http"), fs = require("node:fs"), path = require("node:path");
const root = process.argv[1];
http.createServer((req, res) => {
  fs.readFile(path.join(root, decodeURIComponent(req.url)), (err, data) => {
    if (err) { res.statusCode = 404; res.end("no"); return; }
    res.end(data);
  });
}).listen(Number(process.argv[2]), "127.0.0.1");
' "$TMP/mirror" "$MIRROR_PORT" &
SERVER_PID=$!
waited=0
while [ "$waited" -lt 50 ]; do
    curl -sf -o /dev/null \
        "http://127.0.0.1:$MIRROR_PORT/mirrors/node/$version/${dist_name}.tar.gz" && break
    sleep 0.1; waited=$((waited + 1))
done
if [ "$waited" -ge 50 ]; then
    skip "校验和用例（本地 mirror 未能在 ${MIRROR_PORT} 上起来）"
    finish; exit $?
fi

out=$("$L" --state "$TMP/rt" --node-mirror "http://127.0.0.1:$MIRROR_PORT/mirrors/node" \
        runtime install 2>&1)
assert_contains "$out" "校验和不匹配" "镜像给出别的内容时拒绝"
assert_contains "$out" "未解压" "拒绝时未解压"
assert_contains "$out" "$impostor_sha" "报出实际收到的校验和"
assert_false "被拒的镜像内容没有留下 node" -- test -x "$TMP/rt/runtime/node/bin/node"

# The same refusal via a preset-shaped invocation, so the flag and the preset path
# share the check rather than only one of them having it.
out=$("$L" --state "$TMP/rt2" --mirror npmmirror \
        --node-mirror "http://127.0.0.1:$MIRROR_PORT/mirrors/node" runtime install 2>&1)
assert_contains "$out" "校验和不匹配" "预设与显式 Node 源混用时同样校验"
assert_false "混用时也没有留下 node" -- test -x "$TMP/rt2/runtime/node/bin/node"

# ===========================================================================
# what npm is actually told
# ===========================================================================
# A stand-in node and npm-cli.js that echo their argv, so the flag can be observed
# rather than inferred from the source. install_managed_dsh fails afterwards (there
# is no real dsh to find) and that is fine -- the argv is what is under test.
npm_argv() { # extra launcher args...
    local state="$TMP/argv-$1"
    rm -rf "$state"
    mkdir -p "$state/runtime/node/bin" "$state/runtime/node/lib/node_modules/npm/bin"
    printf '#!/bin/bash\necho "NODE-ARGV: $*"\n' > "$state/runtime/node/bin/node"
    chmod +x "$state/runtime/node/bin/node"
    : > "$state/runtime/node/lib/node_modules/npm/bin/npm-cli.js"
    shift
    (
        export DSH_LAUNCHER_LIB=1
        # shellcheck source=/dev/null
        . "$L" --state "$state" "$@"
        install_managed_dsh 2>&1
    )
}

out=$(npm_argv plain --mirror npmmirror)
assert_contains "$out" "--registry https://registry.npmmirror.com" \
    "选了镜像时 npm 收到 --registry"
assert_contains "$out" "--prefix" "npm 仍被限制在应用自己的目录里"
assert_contains "$out" "npm registry: https://registry.npmmirror.com" "日志记下所用 registry"

# And with nothing chosen, no --registry at all: npm has to be left to read the
# user's ~/.npmrc, which is where their proxy and credentials live.
out=$(npm_argv inherit)
assert_not_contains "$out" "--registry" "未选镜像时不给 npm 传 --registry"
assert_contains "$out" "NODE-ARGV" "反向验证：确实执行到了 npm 调用"

out=$(npm_argv custom --registry http://npm.internal.example/)
assert_contains "$out" "--registry http://npm.internal.example/" "自定义 registry 传到 npm"

finish
