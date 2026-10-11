#!/usr/bin/env bash
set -uo pipefail
TESTS_FAILED=0
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib-assert.sh"
command -v assert_eq >/dev/null 2>&1 || { printf 'harness missing: lib-assert.sh did not load\n' >&2; exit 2; }
MECH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)/skills/upstream-sync/scripts"

scratch_setup
trap scratch_teardown EXIT
. "$MECH/sync-lib.sh"
command -v sync_git >/dev/null 2>&1 || { printf 'sync-lib missing\n' >&2; exit 2; }

h1="$(sync_state_hash)"
h2="$(sync_state_hash)"
assert_eq "$h1" "$h2" "同一状态两次哈希相同"
assert_eq "64" "$(printf '%s' "$h1" | wc -c | tr -d ' ')" "哈希长度为 64"

printf 'dirty\n' >> "$SCRATCH_REPO/README.md"
h3="$(sync_state_hash)"
if [ "$h1" = "$h3" ]; then
  assert_eq "变化" "未变化" "工作区内容变化必须改变哈希"
else
  assert_eq "changed" "changed" "工作区内容变化必须改变哈希"
fi

# A1/A2：哈希必须绑定到未跟踪技能目录里的"内容"，而不只是目录名。
# 此前 untracked_skills= 只记录目录名，`ls-files --directory` 的目录折叠与 porcelain
# 的 "?? skills/zeta/" 折叠叠加，使目录内文件的增删改对哈希完全不可见——而 apply 的
# 全部职责恰是采纳这些目录，等于"批准"没有绑定到它所批准的内容。
mkdir -p "$SCRATCH_REPO/skills/zeta"
printf 'first\n' > "$SCRATCH_REPO/skills/zeta/SKILL.md"
h_z1="$(sync_state_hash)"
printf 'second\n' > "$SCRATCH_REPO/skills/zeta/SKILL.md"
h_z2="$(sync_state_hash)"
if [ "$h_z1" = "$h_z2" ]; then
  assert_eq "变化" "未变化" "A1：未跟踪技能内文件内容变化必须改变哈希"
else
  assert_eq "changed" "changed" "A1：未跟踪技能内文件内容变化必须改变哈希"
fi

printf 'extra\n' > "$SCRATCH_REPO/skills/zeta/extra.md"
h_z3="$(sync_state_hash)"
if [ "$h_z2" = "$h_z3" ]; then
  assert_eq "变化" "未变化" "A2：未跟踪技能目录内新增文件必须改变哈希"
else
  assert_eq "changed" "changed" "A2：未跟踪技能目录内新增文件必须改变哈希"
fi

# A4：非 ASCII 文件名的内容也必须可摘要。core.quotePath=true（默认）会把名字输出成
# 带转义的引号形式，逐文件 hash-object 会失败并退化成 unhashable，内容变化随即不可见。
mkdir -p "$SCRATCH_REPO/skills/测试"
printf 'one\n' > "$SCRATCH_REPO/skills/测试/SKILL.md"
h_n1="$(sync_state_hash)"
printf 'two\n' > "$SCRATCH_REPO/skills/测试/SKILL.md"
h_n2="$(sync_state_hash)"
if [ "$h_n1" = "$h_n2" ]; then
  assert_eq "变化" "未变化" "A4：非 ASCII 文件名的未跟踪技能内容变化必须改变哈希"
else
  assert_eq "changed" "changed" "A4：非 ASCII 文件名的未跟踪技能内容变化必须改变哈希"
fi

# B：哈希不得依赖调用者的 git 配置。showUntrackedFiles=no 会让 porcelain 丢掉全部
# 未跟踪项，使同一仓库在不同机器上哈希不同（甚至看不见 apply 的目标）。
git -C "$SCRATCH_REPO" config status.showUntrackedFiles no
h_cfg="$(sync_state_hash)"
git -C "$SCRATCH_REPO" config --unset status.showUntrackedFiles
if [ "$h_n2" = "$h_cfg" ]; then
  assert_eq "same" "same" "B：status.showUntrackedFiles=no 不得改变哈希"
else
  assert_eq "同一状态" "受配置影响" "B：status.showUntrackedFiles=no 不得改变哈希"
fi

# F3.1（功能面）：非 ASCII 目录名必须被 sync_untracked_skills 列出。
# 此前该函数里的 ls-files 不带 -c core.quotePath=false，默认配置下 git 会把名字输出成
# "skills/\346…/" 这样的 C 转义形式，sed 过滤完全匹配不到 → 清单为空。这不是可移植性
# 小毛病：plan 用这份清单报"游离技能"，apply --adopt 用它迭代，于是非 ASCII 命名的
# 技能目录在本机被静默漏掉——plan 显示"无"，apply 永不采纳。
git -C "$SCRATCH_REPO" config core.quotePath true
F3_SKILLS="$(sync_untracked_skills)"
case "$F3_SKILLS" in
  *测试*) assert_eq "listed" "listed" "F3.1：非 ASCII 名下未跟踪技能必须被列出（quotePath=true）" ;;
  *)      assert_eq "listed" "missing:[$F3_SKILLS]" "F3.1：非 ASCII 名下未跟踪技能必须被列出（quotePath=true）" ;;
esac

# F3.2（可移植面）：同一份工作区状态，core.quotePath 取任何值都必须得到同一个哈希。
# 用仓库本地配置设置，库内部的 -c 必须压过它——这正是本断言的判别力所在。
h_qp_base="$(sync_state_hash)"
git -C "$SCRATCH_REPO" config core.quotePath false
h_qp_false="$(sync_state_hash)"
git -C "$SCRATCH_REPO" config core.quotePath true
h_qp_true="$(sync_state_hash)"
git -C "$SCRATCH_REPO" config --unset core.quotePath
if [ "$h_qp_base" = "$h_qp_true" ] && [ "$h_qp_base" = "$h_qp_false" ]; then
  assert_eq "same" "same" "F3.2：core.quotePath 的取值不得改变哈希"
else
  assert_eq "同一状态" "受配置影响" "F3.2：core.quotePath 的取值不得改变哈希"
fi

# F3.3（字节面）：core.autocrlf 不得改写摘要。hash-object 只给路径会走 attributes/convert
# 链，autocrlf=true 时 CRLF 被转成 LF，同一份字节在两台机器上得到不同 blob 摘要——
# 批准凭证必须绑定文件字节，而不是检查者的 git 配置。
# 故意用 ASCII 目录名（skills/zeta/）：让这条断言只受 F2 驱动，不与 F3.1 的缺陷纠缠。
printf 'a\r\nb\r\n' > "$SCRATCH_REPO/skills/zeta/crlf.md"
h_crlf_base="$(sync_state_hash)"
git -C "$SCRATCH_REPO" config core.autocrlf true
h_crlf_on="$(sync_state_hash)"
git -C "$SCRATCH_REPO" config --unset core.autocrlf
if [ "$h_crlf_base" = "$h_crlf_on" ]; then
  assert_eq "same" "same" "F3.3：core.autocrlf=true 不得改变哈希（CRLF 字节）"
else
  assert_eq "同一状态" "受配置影响" "F3.3：core.autocrlf=true 不得改变哈希（CRLF 字节）"
fi

# F3.4a 前置：把非 ASCII 路径放进 merge base。
# sync_conflict_preflight / sync_non_added_paths 上的 -c core.quotePath=false 也必须有
# 断言兜住，而"两侧各自修改同一路径"要在 diff 里显示为 M，该路径就必须已存在于共同
# 祖先。此时 main == local（A3 之前没有任何提交），先在 local 提交它、让 main 快进到
# 同一提交，A3"恰好一个冲突"的断言因此不受影响。
mkdir -p "$SCRATCH_REPO/skills/测试技能"
printf 'base\n' > "$SCRATCH_REPO/skills/测试技能/SKILL.md"
git -C "$SCRATCH_REPO" add skills/测试技能
git -C "$SCRATCH_REPO" commit -qm "local: 纳入非 ASCII 技能路径"
git -C "$SCRATCH_REPO" switch -q main
git -C "$SCRATCH_REPO" merge -q --ff-only local
git -C "$SCRATCH_REPO" switch -q local

# A3：main 与 local 的同名真实冲突必须改变哈希。
# 先把本地游离技能提交进去（否则游离内容会污染后续两次比较），再在两侧改同一路径。
git -C "$SCRATCH_REPO" add -A
git -C "$SCRATCH_REPO" commit -qm "local: 纳入待比较状态"
h_pre="$(sync_state_hash)"
git -C "$SCRATCH_REPO" switch -q main
printf 'from main\n' >> "$SCRATCH_REPO/skills/alpha/SKILL.md"
git -C "$SCRATCH_REPO" commit -qam "main 侧改动同名技能"
git -C "$SCRATCH_REPO" switch -q local
printf 'from local\n' >> "$SCRATCH_REPO/skills/alpha/SKILL.md"
git -C "$SCRATCH_REPO" commit -qam "local 侧改动同名技能"
assert_eq "skills/alpha/SKILL.md" "$(sync_conflict_preflight)" "A3 前提：构造出真实同名冲突"
h_conf="$(sync_state_hash)"
if [ "$h_pre" = "$h_conf" ]; then
  assert_eq "变化" "未变化" "A3：同名冲突出现必须改变哈希"
else
  assert_eq "changed" "changed" "A3：同名冲突出现必须改变哈希"
fi

# F3.4b：非 ASCII 的冲突路径必须按字节出现在预演与 I2 诊断里，且不得影响哈希。
# 两侧各自修改同一个非 ASCII 路径 → modify/modify 冲突（该路径已在 merge base 里）。
git -C "$SCRATCH_REPO" switch -q main
printf 'from main\n' >> "$SCRATCH_REPO/skills/测试技能/SKILL.md"
git -C "$SCRATCH_REPO" commit -qam "main 侧改动非 ASCII 技能"
git -C "$SCRATCH_REPO" switch -q local
printf 'from local\n' >> "$SCRATCH_REPO/skills/测试技能/SKILL.md"
git -C "$SCRATCH_REPO" commit -qam "local 侧改动非 ASCII 技能"

case "$(sync_conflict_preflight)" in
  *skills/测试技能/SKILL.md*) assert_eq "listed" "listed" "F3.4：冲突预演按字节输出非 ASCII 路径" ;;
  *)                          assert_eq "listed" "quoted-or-missing" "F3.4：冲突预演按字节输出非 ASCII 路径" ;;
esac
case "$(sync_non_added_paths)" in
  *skills/测试技能/SKILL.md*) assert_eq "listed" "listed" "F3.4：非新增诊断按字节输出非 ASCII 路径" ;;
  *)                          assert_eq "listed" "quoted-or-missing" "F3.4：非新增诊断按字节输出非 ASCII 路径" ;;
esac
h_cjk_base="$(sync_state_hash)"
git -C "$SCRATCH_REPO" config core.quotePath true
h_cjk_true="$(sync_state_hash)"
git -C "$SCRATCH_REPO" config core.quotePath false
h_cjk_false="$(sync_state_hash)"
git -C "$SCRATCH_REPO" config --unset core.quotePath
if [ "$h_cjk_base" = "$h_cjk_true" ] && [ "$h_cjk_base" = "$h_cjk_false" ]; then
  assert_eq "same" "same" "F3.4：存在非 ASCII 冲突时哈希仍与 core.quotePath 无关"
else
  assert_eq "同一状态" "受配置影响" "F3.4：存在非 ASCII 冲突时哈希仍与 core.quotePath 无关"
fi

# A5：扫描结果必须真正进入哈希，且扫描器必须按 SYNC_SCRIPT_DIR 定位。
# 判别方式：把机制脚本与规则表复制到仓库外，只往"副本"规则表里追加一条规则——工作区、
# 提交、状态一律不动，于是哈希若变化，变化只可能来自"换了一份规则表"。若 sync_state_hash
# 改用 sync_repo_root 找扫描器（测试的临时仓库里根本没有机制脚本），两次都是空扫描，
# 哈希相等，断言即失败。
mkdir -p "$SCRATCH_REPO/skills/tmpscan"
printf 'syncscanfx-present\n' > "$SCRATCH_REPO/skills/tmpscan/SKILL.md"
git -C "$SCRATCH_REPO" add skills/tmpscan
git -C "$SCRATCH_REPO" commit -qm "local: 扫描定位夹具"
SEC_DIR="$SCRATCH/sec"
mkdir -p "$SEC_DIR"
cp "$MECH/sync-lib.sh" "$MECH/scan-sensitive.sh" "$MECH/patterns.tsv" "$SEC_DIR/"
printf 'scan-fx\tcontent\tsyncscanfx[-]present\t测试用规则：只存在于副本\n' >> "$SEC_DIR/patterns.tsv"
h_scan_real="$(sync_state_hash)"
SYNC_SCRIPT_DIR="$SEC_DIR"
h_scan_copy="$(sync_state_hash)"
SYNC_SCRIPT_DIR="$MECH"
if [ "$h_scan_real" = "$h_scan_copy" ]; then
  assert_eq "变化" "未变化" "A5：扫描结果进入哈希，且扫描器按 SYNC_SCRIPT_DIR 定位"
else
  assert_eq "changed" "changed" "A5：扫描结果进入哈希，且扫描器按 SYNC_SCRIPT_DIR 定位"
fi

# 提交一个命中敏感信息的文件后，哈希必须改变。
# 说明：这条是"敏感文件出现即改变凭证"的回归守卫，它不做隔离——此处的 h3 早于上面若干
# 次提交，状态本来就不同。真正把"扫描结果"单独隔离出来的判别断言是紧邻上面的 A5。
mkdir -p "$SCRATCH_REPO/skills/tmpsec"
printf 'key = %s\n' "$(printf 'AK%s' 'IAIOSFODNN7EXAMPLE')" > "$SCRATCH_REPO/skills/tmpsec/SKILL.md"
h4="$(sync_state_hash)"
if [ "$h3" = "$h4" ]; then
  assert_eq "变化" "未变化" "新增命中敏感信息的文件后哈希必须改变"
else
  assert_eq "changed" "changed" "新增命中敏感信息的文件后哈希必须改变"
fi

if [ "${TESTS_FAILED:-0}" -gt 0 ]; then
  printf '%s 项断言失败\n' "$TESTS_FAILED"
  exit 1
fi
exit 0
