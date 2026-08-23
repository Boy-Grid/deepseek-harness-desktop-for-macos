#!/bin/bash
# Backend selection, state-directory partitioning and DSH_HOME resolution.
# These run through the real CLI (status touches nothing) so the parsing and the
# derived paths are checked exactly as a caller would see them.
set -u
TEST_NAME="t-02-args"
cd "$(dirname "$0")" || exit 1
. lib/assert.sh

L="$(cd .. && pwd)/launcher"
BASE="$HOME/Library/Application Support/DSH Desktop"

status() { "$L" status "$@" 2>&1; }
field() { # field-name, then status args
    local name="$1"; shift
    status "$@" | awk -v k="$name:" '$1 == k { $1=""; sub(/^ +/, ""); print; exit }'
}

# --- backend validation -----------------------------------------------------
assert_eq "stock" "$(field backend)" "默认后端是 stock"
assert_eq "mfw" "$(field backend --backend mfw)" "--backend mfw 被接受"
assert_eq "mfw" "$(DSH_LAUNCHER_BACKEND=mfw "$L" status | awk '$1=="backend:"{print $2}')" \
    "DSH_LAUNCHER_BACKEND 也生效"
assert_exit 2 "未知后端被拒绝（退出码 2）" -- "$L" status --backend bogus
assert_contains "$(status --backend bogus)" "unknown backend" "未知后端给出可读原因"

# --- state directory partitioning ------------------------------------------
# stock + 3080 must keep the historical path: an existing install's cached
# paths and logs live there.
assert_eq "$BASE" "$(field state)" "stock+3080 沿用历史状态目录"
assert_eq "$BASE/ports/3099" "$(field state --port 3099)" "非默认端口下沉到 ports/<port>"
assert_eq "$BASE/mfw" "$(field state --backend mfw)" "mfw 后端有自己的一级目录"
assert_eq "$BASE/mfw/ports/3099" "$(field state --backend mfw --port 3099)" \
    "后端与端口叠加分区"
assert_eq "/tmp/explicit-state" "$(field state --state /tmp/explicit-state --backend mfw --port 3099)" \
    "--state 显式指定时不再叠加分区"

# Two differently-booted instances must never share a pid file.
a="$(field state --backend stock --port 3099)"
b="$(field state --backend mfw --port 3099)"
assert_ne "$a" "$b" "同端口不同后端的状态目录必须不同"

# --- DSH_HOME resolution ----------------------------------------------------
assert_eq "$HOME/.dsh" "$(field home)" "默认 DSH home 是 ~/.dsh"
assert_contains "$(field home --dsh-home /tmp/alt-home)" "/tmp/alt-home" "--dsh-home 生效"
assert_contains "$(field home --dsh-home /tmp/alt-home)" "(isolated)" \
    "指向别处的 home 被标记为 isolated"
assert_not_contains "$(field home)" "(isolated)" "共享 home 不标 isolated"
assert_contains "$(DSH_HOME=/tmp/env-home "$L" status | awk '$1=="home:"{print $2}')" \
    "/tmp/env-home" "继承的 DSH_HOME 被采纳"
# An explicit --dsh-home equal to the inherited one is still the shared home.
assert_not_contains "$(DSH_HOME=/tmp/env-home "$L" status --dsh-home /tmp/env-home)" "(isolated)" \
    "显式指定成同一个 home 时不算隔离"

# --- help text --------------------------------------------------------------
# The header block is extracted between its banner rules; a fixed line range
# silently truncated it once the block grew.
h="$("$L" help)"
for opt in --port --backend --dsh --mfw --node --dsh-home --allow-version-skew --no-browser --state; do
    assert_contains "$h" "$opt" "help 覆盖 $opt"
done
assert_contains "$h" "launcher status" "help 覆盖子命令列表"
assert_contains "$h" "multi-folder-workspace" "help 给出 mfw 仓库链接"

finish
