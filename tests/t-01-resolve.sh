#!/bin/bash
# Unit tests for the launcher's path and process helpers, exercised directly
# through DSH_LAUNCHER_LIB=1 rather than through a full start/stop.
set -u
TEST_NAME="t-01-resolve"
cd "$(dirname "$0")" || exit 1
. lib/assert.sh

REPO="$(cd .. && pwd)"
set --                       # the launcher parses "$@" when sourced
# shellcheck source=../launcher
DSH_LAUNCHER_LIB=1 . "$REPO/launcher"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/d4m-t01.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# --- realpath_of: walk a chain of symlinks, absolute and relative -----------
mkdir -p "$TMP/realbin" "$TMP/symbin"
printf '#!/bin/sh\necho v22.22.3\n' > "$TMP/realbin/node"
chmod +x "$TMP/realbin/node"
ln -s "../realbin/node" "$TMP/symbin/node"          # relative target
ln -s "$TMP/symbin/node" "$TMP/abs-node"            # absolute target, 2 hops

REAL_DIR=$(cd "$TMP/realbin" && pwd -P)
assert_eq "$REAL_DIR/node" "$(realpath_of "$TMP/symbin/node")" "realpath_of 解析相对 symlink"
assert_eq "$REAL_DIR/node" "$(realpath_of "$TMP/abs-node")"    "realpath_of 解析两跳 symlink"
assert_eq "$REAL_DIR/node" "$(realpath_of "$TMP/realbin/node")" "realpath_of 对普通文件返回自身"

# realpath_of walks with cd; a caller must not have its own directory moved.
here=$(pwd -P)
_=$(realpath_of "$TMP/abs-node")
assert_eq "$here" "$(pwd -P)" "realpath_of 不改变调用者的工作目录"

# --- child_path: the real node's directory must come first ------------------
# This is the fix for the measured failure "dsh-mfw: cannot find a usable pnpm":
# pnpm and corepack sit next to the real node, not next to a symlink to it.
# Compared as spelled, not as resolved: child_path keeps the symlink's own
# directory verbatim (dirname), while REAL_DIR above is the physical path.
SYM_DIR=$(dirname "$TMP/symbin/node")
cp="$(child_path "$TMP/symbin/node")"
assert_eq "$REAL_DIR" "${cp%%:*}" "child_path 把 node 的 realpath 目录放在最前"
assert_contains "$cp" "$SYM_DIR" "child_path 同时保留 symlink 所在目录"
assert_not_contains ":$cp" "::" "child_path 不产生空的 PATH 段"

# A node that is not a symlink must not be listed twice.
cp_direct="$(child_path "$TMP/realbin/node")"
dupes=$(printf '%s' "$cp_direct" | tr ':' '\n' | grep -cx "$REAL_DIR")
assert_eq "1" "$dupes" "child_path 对非 symlink 的 node 不重复列目录"

# --- node_major -------------------------------------------------------------
assert_eq "22" "$(node_major "$TMP/realbin/node")" "node_major 取主版本号"
printf '#!/bin/sh\necho v18.20.1\n' > "$TMP/realbin/old-node"; chmod +x "$TMP/realbin/old-node"
assert_eq "18" "$(node_major "$TMP/realbin/old-node")" "node_major 认出低版本"
assert_eq "" "$(node_major "$TMP/does-not-exist" 2>/dev/null)" "node_major 对不存在的 node 返回空"

# --- pkg_version ------------------------------------------------------------
cat > "$TMP/package.json" <<'JSON'
{
  "name": "@deepseek-ai/dsh",
  "version": "0.1.1-rc.2",
  "dependencies": { "commander": "^12.0.0" }
}
JSON
assert_eq "0.1.1-rc.2" "$(pkg_version "$TMP/package.json")" "pkg_version 读出版本号"
assert_eq "" "$(pkg_version "$TMP/nope.json" 2>/dev/null)" "pkg_version 对缺失文件返回空"

# --- proc_tree: the listener may be any descendant, not the first child -----
# The old walk took `pgrep -P | head -1` at every level, so a sibling that came
# later was invisible -- and with the mfw backend the tree is a level deeper.
# stderr is dropped because the inner shell announces its killed children.
bash -c 'sleep 30 & sleep 30 & sleep 30 & wait' 2>/dev/null &
parent=$!
sleep 0.7
kids=$(pgrep -P "$parent" | tr '\n' ' ')
first=$(echo "$kids" | awk '{print $1}')
last=$(echo "$kids" | awk '{print $NF}')
tree=" $(proc_tree "$parent") "

if [ -z "$last" ] || [ "$first" = "$last" ]; then
    skip "proc_tree 兄弟进程用例（未能造出多子进程树）"
else
    assert_contains "$tree" " $parent " "proc_tree 含根进程"
    assert_contains "$tree" " $first "  "proc_tree 含第一个子进程"
    assert_contains "$tree" " $last "   "proc_tree 含最后一个子进程（旧单链算法会漏）"

    # Reverse verification: prove the old algorithm really did miss it.
    old=""; walk="$parent"
    while [ -n "$walk" ]; do
        old="$old $walk"
        walk=$(pgrep -P "$walk" 2>/dev/null | head -1)
    done
    assert_not_contains " $old " " $last " "反向验证：旧的单链走法确实漏掉该子进程"
fi
kill_tree "$parent" KILL 2>/dev/null
wait 2>/dev/null

# --- port_listener degrades quietly when lsof is unavailable ---------------
LSOF="$TMP/no-such-lsof"
assert_eq "" "$(port_listener)" "lsof 不可用时 port_listener 返回空而不是报错"
assert_exit 0 "lsof 不可用时 port_listener 仍返回成功" -- port_listener

finish
