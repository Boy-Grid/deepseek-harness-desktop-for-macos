#!/bin/bash
# Documentation consistency.
#
# These were manual checks until a rewrite broke a link and shipped a file that
# told the reader to go and read itself. Cheap to assert, so assert them.
set -u
TEST_NAME="t-08-docs"
cd "$(dirname "$0")" || exit 1
. lib/assert.sh

REPO="$(cd .. && pwd)"
cd "$REPO" || exit 1

# --- the files a public repository is expected to carry --------------------
for f in README.md README.zh.md CONTRIBUTING.md SECURITY.md LICENSE \
         THIRD_PARTY_NOTICES.md Resources-README.md; do
    assert_true "$f 存在" -- test -f "$f"
done

# --- every relative link resolves ------------------------------------------
# Anchors and external URLs are skipped; what matters is that a file this
# repository points at actually exists.
broken=""
for f in ./*.md; do
    while read -r target; do
        [ -n "$target" ] || continue
        case "$target" in http://*|https://*|mailto:*) continue ;; esac
        path="${target%%#*}"
        [ -n "$path" ] || continue
        [ -e "$path" ] || broken="$broken $(basename "$f")→${path}"
    done <<EOF
$(grep -oE '\]\([^)]*\)' "$f" | sed 's/^](//; s/)$//')
EOF
done
assert_eq "" "$broken" "所有 md 的相对链接都存在"

# --- anchors must resolve to a heading -------------------------------------
# A wrong anchor is not a broken link: the file opens, the reader just lands at
# the top and has to go looking. Cheap to check, and it caught nothing only
# because the last one was verified by hand.
# The locale is pinned because the character class is the whole point: under a
# UTF-8 one, [:alnum:] keeps CJK -- which is what GitHub does with a Chinese
# heading -- while under LC_ALL=C it strips it and every anchor in README.zh.md
# would slug to the empty string and match nothing.
slug() { # heading text -> GitHub-style anchor
    printf '%s' "$1" | LC_ALL=en_US.UTF-8 tr '[:upper:]' '[:lower:]' \
        | LC_ALL=en_US.UTF-8 sed 's/[^[:alnum:] _-]//g; s/ /-/g'
}
bad_anchors=""
for f in ./*.md; do
    while read -r target; do
        # Both shapes: a link into another file, and one into this same file --
        # the second kind used to be skipped entirely, which is precisely where a
        # typo is easiest to make and hardest to notice.
        case "$target" in
            '#'*)     file="$f";           anchor="${target#\#}" ;;
            *.md'#'*) file="${target%%#*}"; anchor="${target#*#}" ;;
            *) continue ;;
        esac
        [ -n "$anchor" ] || continue
        [ -f "$file" ] || continue
        found=0
        while IFS= read -r heading; do
            [ "$(slug "$heading")" = "$anchor" ] && { found=1; break; }
        done <<EOF
$(sed -n 's/^#\{1,6\} //p' "$file")
EOF
        [ "$found" -eq 1 ] || bad_anchors="$bad_anchors $(basename "$f")→${target}"
    done <<EOF
$(grep -oE '\]\([^)]*\)' "$f" | sed 's/^](//; s/)$//')
EOF
done
assert_eq "" "$bad_anchors" "所有指向 md 的锚点都能对上标题"

# Reverse verification: the slug function has to match GitHub's shape, or the
# check above would pass by never matching anything.
assert_eq "not-built-yet" "$(slug 'Not built yet')" "反向验证：slug 规则正确"
assert_ne "not-built-yet" "$(slug 'Not Built Yet extra')" "反向验证：slug 能区分不同标题"
assert_eq "让其他设备访问" "$(slug '让其他设备访问')" "反向验证：中文标题的 slug 保留原字符"
assert_eq "why-node-is-resolved-explicitly" "$(slug 'Why node is resolved explicitly.')" \
    "反向验证：slug 去掉句末标点"

# Reverse verification: the walk above must actually be able to see a break.
probe=$(mktemp "${TMPDIR:-/tmp}/d4m-docs.XXXXXX").md
printf '[gone](no-such-file.md)\n' > "$probe"
probe_target=$(grep -oE '\]\([^)]*\)' "$probe" | sed 's/^](//; s/)$//')
rm -f "$probe"
assert_eq "no-such-file.md" "$probe_target" "反向验证：链接提取本身有效"
assert_false "反向验证：该目标确实不存在" -- test -e "no-such-file.md"

# --- the two READMEs must point at each other ------------------------------
# A translation nobody can find is a translation nobody reads.
assert_true "README.md 链到中文版" -- grep -q "README.zh.md" README.md
assert_true "README.zh.md 链到英文版" -- grep -q "README.md" README.zh.md

# --- badges must point at a workflow that exists ---------------------------
for wf in $(grep -oE 'actions/workflows/[A-Za-z0-9._-]+' README.md | sed 's|actions/workflows/||' | sort -u); do
    assert_true "badge 指向的 workflow 存在：$wf" -- test -f ".github/workflows/$wf"
done

# --- the in-bundle copy must not send the reader to itself -----------------
# It used to say "see README.md in Contents/Resources/" -- which is that file.
assert_not_contains "$(cat Resources-README.md)" "Contents/Resources/README.md" \
    "bundle 内说明不自指"
assert_true "bundle 内说明给出仓库地址" -- \
    grep -q "github.com/Boy-Grid/deepseek-harness-desktop-for-macos" Resources-README.md

# --- promises that must not quietly disappear ------------------------------
# The multi-folder backend widens the agent's write surface. If that statement
# ever falls out of the security documentation, the omission should fail a build
# rather than go unnoticed.
security=$(cat SECURITY.md)
assert_contains "$security" "write" "SECURITY 讲到写面"
assert_contains "$security" "mfw" "SECURITY 点名 mfw 后端"
assert_contains "$security" "not the default" "SECURITY 写明它不是默认值"
assert_contains "$security" "did not start" "SECURITY 载明「只停自己启动的」承诺"
# The bind address is the one setting that changes who can use the machine, so
# the documentation has to keep saying what that costs -- and has to keep saying
# that the trusted-host list is not a mitigation, because it reads like one.
assert_contains "$security" "no authentication" "SECURITY 写明 DSH 没有认证"
assert_contains "$security" "not access control" "SECURITY 写明受信任主机不是访问控制"
assert_contains "$security" "Cancel" "SECURITY 写明确认框默认在安全一侧"
# The update path replaces the running application, so the gates it applies -- and
# the reason the identity comparison is the load-bearing one -- have to stay
# written down. So does the refusal for ad-hoc builds, which is the surprising bit.
assert_contains "$security" "Team ID of the new app" "SECURITY 写明比对新版本的 Team ID"
assert_contains "$security" "somebody" "SECURITY 解释有效签名只证明「有人」签过"
assert_contains "$security" "ad-hoc signed" "SECURITY 写明 ad-hoc 构建被拒绝"
assert_contains "$security" "no background polling" "SECURITY 写明没有后台轮询"
assert_contains "$security" "per IP address" "SECURITY 写明 API 限额按 IP 计"

readme=$(cat README.md)
readme_zh=$(cat README.zh.md)
assert_contains "$readme" "Unofficial" "README 开头即声明非官方"
# Both READMEs have to state the exposure cost in plain words, not defer to
# SECURITY.md: the setting is reachable from the page that documents settings.
assert_contains "$readme" "No password, no token, nothing." "README 直白讲清无认证"
assert_contains "$readme" "is not access control" "README 写明受信任主机不是访问控制"
assert_contains "$readme_zh" "没有任何认证" "中文 README 直白讲清无认证"
assert_contains "$readme_zh" "不是访问控制" "中文 README 写明受信任主机不是访问控制"
assert_contains "$readme" "Team ID of the app being replaced" "README 写明比对被替换应用的 Team ID"
assert_contains "$readme_zh" "与被替换的应用一致" "中文 README 写明同样的比对"
# The mirror table is a promise about where bytes come from, and the asymmetry
# between its two halves is the part a reader most needs and most easily loses.
for host in registry.npmmirror.com mirrors.cloud.tencent.com repo.huaweicloud.com; do
    assert_contains "$readme" "$host" "README 列出镜像 $host"
    assert_contains "$readme_zh" "$host" "中文 README 列出镜像 $host"
done
assert_contains "$readme" "not a trust decision" "README 写明 Node 镜像不是信任选择"
assert_contains "$readme" "An npm registry is one" "README 写明 npm registry 是信任选择"
assert_contains "$readme_zh" "不是信任选择" "中文 README 写明 Node 镜像不是信任选择"
assert_contains "$readme_zh" "是信任选择" "中文 README 写明 npm registry 是信任选择"
assert_contains "$readme" "Nothing is passed by default" "README 写明默认不覆盖 npm 配置"
assert_contains "$security" "not a trust boundary" "SECURITY 写明 Node 镜像不是信任边界"
# Matched on a fragment that sits within one line: the sentence starts at the end
# of the previous one, and an assertion spanning the break would fail on a reflow.
assert_contains "$security" "copy of \`~/.npmrc\` is ever made" \
    "SECURITY 承诺不复制用户的 npmrc"
assert_contains "$readme" "not affiliated with" "README 载有免责声明"
assert_contains "$readme" "macOS 14" "README 写明最低系统版本"
# Matched on a short fragment on purpose: the full sentence wraps, and an
# assertion that depends on where a line happens to break is a trap for the next
# person to reflow a paragraph.
assert_contains "$readme" "bundles neither" "README 写明两个运行时都不捆绑"
# The managed runtime downloads and executes code, so its cost and its
# verification must both be stated where a user will see them.
assert_contains "$readme" "always wins" "README 写明用户自己的运行时优先"
assert_contains "$readme" "470 MB" "README 如实写出磁盘占用"
assert_contains "$readme" "pinned in the launcher" "README 说明校验和是固定在脚本里的"

# --- the icon's provenance has to stay attributed --------------------------
notices=$(cat THIRD_PARTY_NOTICES.md)
assert_contains "$notices" "favicon" "第三方声明记录了图标出处"
assert_contains "$notices" "MIT" "第三方声明保留上游许可"

finish
