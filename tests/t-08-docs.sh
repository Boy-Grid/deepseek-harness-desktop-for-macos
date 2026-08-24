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
slug() { # heading text -> GitHub-style anchor
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9 -]//g; s/ /-/g'
}
bad_anchors=""
for f in ./*.md; do
    while read -r target; do
        case "$target" in
            *.md#*) ;;
            *) continue ;;
        esac
        file="${target%%#*}"
        anchor="${target#*#}"
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

readme=$(cat README.md)
assert_contains "$readme" "Unofficial" "README 开头即声明非官方"
assert_contains "$readme" "not affiliated with" "README 载有免责声明"
assert_contains "$readme" "macOS 14" "README 写明最低系统版本"
# Matched on a short fragment on purpose: the full sentence wraps, and an
# assertion that depends on where a line happens to break is a trap for the next
# person to reflow a paragraph.
assert_contains "$readme" "neither bundles" "README 写明不捆绑不代装运行时"

# --- the icon's provenance has to stay attributed --------------------------
notices=$(cat THIRD_PARTY_NOTICES.md)
assert_contains "$notices" "favicon" "第三方声明记录了图标出处"
assert_contains "$notices" "MIT" "第三方声明保留上游许可"

finish
