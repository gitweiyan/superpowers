#!/usr/bin/env bash
set -uo pipefail
TESTS_FAILED=0
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib-assert.sh"
# G1：harness 自检。lib-assert.sh 没加载成功时断言会退化成空操作，整个套件会"零失败"
# 地退出 0——那比失败更危险。
command -v assert_eq >/dev/null 2>&1 || { printf 'harness missing: lib-assert.sh did not load\n' >&2; exit 2; }
MECH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)/skills/upstream-sync/scripts"
PLAN="$MECH/plan.sh"
. "$MECH/sync-lib.sh"
command -v sync_git >/dev/null 2>&1 || { printf 'sync-lib missing\n' >&2; exit 2; }

scratch_setup
trap scratch_teardown EXIT
# scratch_setup 只造好"从 fork 克隆、并挂了 upstream 但未 fetch"的工作仓库；要驱动 upstream
# 前进，还得有第二份可以提交并推回上游裸库的工作拷贝，故这里自行定义它的路径。
SCRATCH_SEED2="$SCRATCH/seed2"
PLAN_JSON="$SCRATCH_REPO/$SYNC_STATE_DIR/plan.json"

# plan.json 里取一个字符串字段：这个片段被三处（H1 的诚实性、H3 的凭证绑定）复用。
json_str() { # file key
  sed -n "s/^  \"$2\": \"\(.*\)\",$/\1/p" "$1" | head -1
}
# 同一份 JSON 里的布尔/数字字段（末行无逗号，故两种写法都接受）
json_raw() { # file key
  sed -n "s/^  \"$2\": \(.*\),$/\1/p;s/^  \"$2\": \(.*\)$/\1/p" "$1" | head -1
}
# plan.json 形状检查：逐行必须匹配"两个空格 + 键 + 冒号 + 带引号字符串/布尔/数字"，
# 返回不匹配的行数。JSON 字符串里不能有裸换行，所以"有字段被折成两行"正是非法 JSON 的签名：
# 冲突预演有两条以上路径时（每行一条），旧写法会直接把换行塞进字符串，第二行就落进这里。
json_bad_lines() { # file
  awk '
    NR == 1 && $0 == "{" { next }
    $0 == "}" { next }
    /^  "[a-z_]+": ".*",$/ { next }
    /^  "[a-z_]+": ".*"$/ { next }
    /^  "[a-z_]+": (true|false|true,|false,)$/ { next }
    /^  "[a-z_]+": [0-9]+,?$/ { next }
    { n++ }
    END { print n + 0 }
  ' "$1"
}

out="$(bash "$PLAN" --no-fetch)"; rc=$?
assert_eq "0" "$rc" "干净状态 plan 退出 0"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '^PLAN_ID=[0-9a-f]\{64\}$')" "报告最后给出 PLAN_ID"
# H5：镜像行的标签用的是变量值，不是写死的 main（改镜像分支名时报告不会说谎）
assert_eq "1" "$(printf '%s\n' "$out" | grep -c "^镜像 $SYNC_MIRROR_BRANCH")" "H5：镜像行标签取自 SYNC_MIRROR_BRANCH"

# upstream 前进一个提交后，plan 必须报告新增
git clone -q "$SCRATCH_UPSTREAM" "$SCRATCH_SEED2"
git -C "$SCRATCH_SEED2" config user.name "$SCRATCH_USER"
git -C "$SCRATCH_SEED2" config user.email "$SCRATCH_USER@$SCRATCH_DOMAIN"
printf 'upstream new\n' >> "$SCRATCH_SEED2/README.md"
git -C "$SCRATCH_SEED2" commit -qam new
git -C "$SCRATCH_SEED2" push -q origin main
out2="$(bash "$PLAN" 2>&1)"; rc=$?
assert_eq "0" "$rc" "fetch 后 plan 仍退出 0"
assert_eq "1" "$(printf '%s\n' "$out2" | grep -c '待合入提交数   : 1')" "plan 报告出 1 个待合入提交"

# 违反 I2（改了 upstream 拥有的文件）必须被拦
printf 'mutated\n' >> "$SCRATCH_REPO/README.md"
git -C "$SCRATCH_REPO" commit -qam "modify upstream file"
bash "$PLAN" --no-fetch >/dev/null 2>&1
assert_eq "2" "$?" "修改 upstream 文件时 plan 退出 2（I2 违规）"

# G1：提交了含敏感信息的文件时，plan 必须退出 2 且不给 PLAN_ID
git -C "$SCRATCH_REPO" reset -q --hard HEAD~1
mkdir -p "$SCRATCH_REPO/skills/leaky"
{
  printf -- '---\n'
  printf 'name: leaky\n'
  printf 'description: 泄漏演示\n'
  printf -- '---\n\nkey = %s\n' "$(printf 'AK%s' 'IAIOSFODNN7EXAMPLE')"
} > "$SCRATCH_REPO/skills/leaky/SKILL.md"
git -C "$SCRATCH_REPO" add skills/leaky
git -C "$SCRATCH_REPO" commit -qm leaky
out3="$(bash "$PLAN" --no-fetch 2>&1)"; rc=$?
assert_eq "2" "$rc" "G1 命中时 plan 退出 2"
assert_eq "0" "$(printf '%s\n' "$out3" | grep -c '^PLAN_ID=')" "G1 命中时不提供 PLAN_ID"
# H5：扫描器退出码 1 才是"命中"，文案必须这么说
assert_eq "1" "$(printf '%s\n' "$out3" | grep -c '^敏感信息扫描   : 命中，已阻断$')" "H5：扫描命中时文案是命中"

# H1：被拒绝的那次也会落盘（否则盘上留着上一轮的旧 plan_id，比这更糟），但必须诚实——
# plan_id 留空（它不是可用的凭证），refused=true，scan_ok=false，且不谎报 I2 也违规。
assert_eq "1" "$([ -f "$PLAN_JSON" ] && printf '1' || printf '0')" "H1：被拒绝的运行也写 plan.json"
assert_eq "" "$(json_str "$PLAN_JSON" plan_id)" "H1：G1 被拒绝时 plan.json 的 plan_id 为空"
assert_eq "true" "$(json_raw "$PLAN_JSON" refused)" "H1：G1 被拒绝时 refused=true"
assert_eq "false" "$(json_raw "$PLAN_JSON" scan_ok)" "H1：G1 被拒绝时 scan_ok=false"
assert_eq "true" "$(json_raw "$PLAN_JSON" invariants_ok)" "H1：G1 被拒绝时 invariants_ok 仍只反映 I2（不谎报）"

# 脏工作区：plan 仍能出计划（审批门的哈希会把脏状态算进去），但必须明确报告
git -C "$SCRATCH_REPO" reset -q --hard HEAD~1
printf 'dirty\n' >> "$SCRATCH_REPO/README.md"
out4="$(bash "$PLAN" --no-fetch 2>&1)"; rc=$?
assert_eq "0" "$rc" "脏工作区时 plan 仍能出计划"
assert_eq "1" "$(printf '%s\n' "$out4" | grep -c '工作区         : 不干净')" "plan 报告工作区不干净"

# H3a：可审批的运行，plan.json 里的 plan_id 必须就是报告最后那行的 PLAN_ID——
# 人类批准的是那个字符串，盘上留下的若是另一个值，审批链就断了。
pid="$(printf '%s\n' "$out4" | sed -n 's/^PLAN_ID=//p')"
assert_eq "$pid" "$(json_str "$PLAN_JSON" plan_id)" "H3a：plan.json 的 plan_id 等于打印的 PLAN_ID"
assert_eq "false" "$(json_raw "$PLAN_JSON" refused)" "H3a：可审批时 refused=false"
assert_eq "true" "$(json_raw "$PLAN_JSON" scan_ok)" "H3a：可审批时 scan_ok=true"
assert_eq "0" "$(json_bad_lines "$PLAN_JSON")" "H3a：可审批时 plan.json 结构合法"
# H5：镜像里没有 package.json 时，报告与 JSON 必须用同一份占位文案（曾经一个 未知 一个 unknown）
assert_eq "1" "$(printf '%s\n' "$out4" | grep -c '^上游版本       : 未知$')" "H5：报告里版本缺失时写 未知"
assert_eq "未知" "$(json_str "$PLAN_JSON" upstream_version)" "H5：JSON 与报告用同一份版本占位文案"
# 有 python3 时再加一道真解析（解释器缺失时明确 skip，绝不静默算通过）
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$PLAN_JSON" >/dev/null 2>&1
  assert_eq "0" "$?" "H3a：plan.json 是真 JSON（python3 解析）"
else
  printf 'skip H3a：plan.json 真解析检查（本机无 python3）\n'
fi

# H3b：冲突预演非空（两条以上路径）时，plan.json 仍必须是合法 JSON。
# 构造：双方都改 README.md 与 skills/alpha/SKILL.md —— merge-tree 报两条冲突，
# 旧写法把 "a\nb" 原样塞进 JSON 字符串，文件即刻非法。
printf 'upstream both\n' >> "$SCRATCH_SEED2/README.md"
printf '\nupstream alpha\n' >> "$SCRATCH_SEED2/skills/alpha/SKILL.md"
git -C "$SCRATCH_SEED2" commit -qam both
git -C "$SCRATCH_SEED2" push -q origin main
git -C "$SCRATCH_REPO" fetch -q upstream main:main
printf 'mine\n' >> "$SCRATCH_REPO/README.md"
printf '\nmine alpha\n' >> "$SCRATCH_REPO/skills/alpha/SKILL.md"
git -C "$SCRATCH_REPO" commit -qam "modify both"
out6="$(bash "$PLAN" --no-fetch 2>&1)"; rc=$?
assert_eq "2" "$rc" "H3b：双方都改同一批文件时 plan 退出 2（I2 违规）"
assert_eq "1" "$(printf '%s\n' "$out6" | grep -c '^冲突预演       : README.md')" "H3b：报告列出冲突路径"
assert_eq "1" "$(grep -c '^  "conflicts": "README.md,skills/alpha/SKILL.md",$' "$PLAN_JSON")" \
  "H3b：plan.json 里多条冲突折成一行（逗号分隔，无裸换行）"
assert_eq "0" "$(json_bad_lines "$PLAN_JSON")" "H3b：冲突非空时 plan.json 结构仍合法"
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$PLAN_JSON" >/dev/null 2>&1
  assert_eq "0" "$?" "H3b：冲突非空时 plan.json 仍是真 JSON"
else
  printf 'skip H3b：plan.json 真解析检查（本机无 python3）\n'
fi
assert_eq "" "$(json_str "$PLAN_JSON" plan_id)" "H3b：被拒绝时 plan_id 仍为空"

# I1：不在 local 上必须按"不变量违规"拦下——退出 2，且不给 PLAN_ID。
# 库里 sync_require_local_branch 走 sync_die（1），平面脚本的契约要求把这条翻成 2。
git -C "$SCRATCH_REPO" reset -q --hard
git -C "$SCRATCH_REPO" switch -q main
out5="$(bash "$PLAN" --no-fetch 2>&1)"; rc=$?
assert_eq "2" "$rc" "不在 local 上时 plan 退出 2（I1 违规）"
assert_eq "0" "$(printf '%s\n' "$out5" | grep -c '^PLAN_ID=')" "不在 local 上时不提供 PLAN_ID"
git -C "$SCRATCH_REPO" switch -q local

# H4：运行错误必须退出 1 并给出可读消息（约束 3 的另一半），绝不允许挂住。
# (a) 远端不可达：把 upstream 指到一个不存在的本地路径——fetch 立刻失败，不涉及任何网络。
git -C "$SCRATCH_REPO" remote set-url upstream "$SCRATCH/nonexistent-remote.git"
out7="$(bash "$PLAN" 2>&1)"; rc=$?
assert_eq "1" "$rc" "H4a：远端不可达时 plan 退出 1"
assert_eq "1" "$(printf '%s\n' "$out7" | grep -c '拉取 upstream 失败')" "H4a：给出可读的拉取失败消息"
assert_eq "0" "$(printf '%s\n' "$out7" | grep -c '^PLAN_ID=')" "H4a：运行错误时不提供 PLAN_ID"

# H5：扫描器退出码 2（规则表读不到/用法错误）与 1（命中）必须印成不同的话——
# 把 2 印成"命中"会让人照着一套对这种情况无效的补救指引处理，等于误报。
# 用机制脚本的一份副本、抽掉规则表来构造：不改动仓库里的真规则表。
BROKEN_MECH="$SCRATCH/mech-broken"
cp -R "$MECH" "$BROKEN_MECH"
rm -f "$BROKEN_MECH/patterns.tsv"
out9="$(bash "$BROKEN_MECH/plan.sh" --no-fetch 2>&1)"; rc=$?
assert_eq "2" "$rc" "H5：扫描器不可用时 plan 退出 2（失败关闭）"
assert_eq "1" "$(printf '%s\n' "$out9" | grep -c '^敏感信息扫描   : 扫描器不可用（规则表或用法错误），已阻断$')" \
  "H5：扫描器不可用的文案与'命中'区分开"
assert_eq "0" "$(printf '%s\n' "$out9" | grep -c '^PLAN_ID=')" "H5：扫描器不可用时不给 PLAN_ID"

# H5：镜像行的标签必须跟着 SYNC_MIRROR_BRANCH 走。默认值恰好就是 main，
# 所以"标签是否写死"在默认配置下看不出来——这里用一份把镜像分支改成 mirror-trunk 的
# 机制副本 + 夹具里同名分支来构造，写死 main 的实现会在这条断言上现形。
RETARGET_MECH="$SCRATCH/mech-retarget"
cp -R "$MECH" "$RETARGET_MECH"
sed 's/^SYNC_MIRROR_BRANCH="main"$/SYNC_MIRROR_BRANCH="mirror-trunk"/' "$RETARGET_MECH/sync-lib.sh" \
  > "$RETARGET_MECH/sync-lib.sh.new"
mv "$RETARGET_MECH/sync-lib.sh.new" "$RETARGET_MECH/sync-lib.sh"
git -C "$SCRATCH_REPO" branch mirror-trunk main
out10="$(bash "$RETARGET_MECH/plan.sh" --no-fetch 2>&1)"
assert_eq "1" "$(printf '%s\n' "$out10" | grep -c '^镜像 mirror-trunk')" \
  "H5：镜像行标签随 SYNC_MIRROR_BRANCH 变化（不是写死的 main）"

# (b) 镜像分支缺失：删掉本地 main，--no-fetch 下必须报"缺少本地镜像分支"而不是晦涩失败。
git -C "$SCRATCH_REPO" branch -D main >/dev/null 2>&1
out8="$(bash "$PLAN" --no-fetch 2>&1)"; rc=$?
assert_eq "1" "$rc" "H4b：镜像分支缺失时 plan 退出 1"
assert_eq "1" "$(printf '%s\n' "$out8" | grep -c '缺少本地镜像分支')" "H4b：给出可读的镜像缺失消息"
assert_eq "0" "$(printf '%s\n' "$out8" | grep -c '^PLAN_ID=')" "H4b：运行错误时不提供 PLAN_ID"

# ---- H1b：守卫在写 artifact 之前就 exit 的那几条路，必须先把盘上的旧凭证作废 ----
# 顺序是这条测试的全部要点：每条失败路径之前都先来一次**可审批运行**，把真凭证写进盘里；
# 否则"被作废了"与"本来就是空的"无法区分，断言会退化成一堆空转（naive 版本正是如此）。
# 三条前置退出路径：I1 分支守卫、镜像分支缺失、fetch 失败。
git -C "$SCRATCH_REPO" remote set-url upstream "$SCRATCH_UPSTREAM"
git -C "$SCRATCH_REPO" branch main local      # 恢复镜像（H4b 删过），使本轮可审批
out11="$(bash "$PLAN" --no-fetch 2>&1)"; rc=$?
assert_eq "0" "$rc" "H1b.1：可审批运行退出 0"
assert_eq "1" "$(printf '%s\n' "$out11" | grep -c '^PLAN_ID=[0-9a-f]\{64\}$')" "H1b.1：给出 64 位 PLAN_ID"
assert_eq "false" "$(json_raw "$PLAN_JSON" refused)" "H1b.1 前提：此时盘上的凭证是可用的（refused=false）"
assert_eq "1" "$([ -n "$(json_str "$PLAN_JSON" plan_id)" ] && printf '1' || printf '0')" \
  "H1b.1 前提：此时盘上的 plan_id 非空"

# H1b.2：紧接着（中间不跑任何可审批运行）触发 I1 拒绝，盘上的凭证必须已被作废
h1b_before="$(shasum -a 256 < "$PLAN_JSON" | awk '{ print $1 }')"
git -C "$SCRATCH_REPO" switch -q main
out12="$(bash "$PLAN" --no-fetch 2>&1)"; rc=$?
assert_eq "2" "$rc" "H1b.2：不在 local 上退出 2（I1）"
assert_eq "0" "$(printf '%s\n' "$out12" | grep -c '^PLAN_ID=')" "H1b.2：I1 拒绝不给 PLAN_ID"
assert_eq "" "$(json_str "$PLAN_JSON" plan_id)" "H1b.2：I1 拒绝后盘上的 plan_id 已作废（空）"
assert_eq "true" "$(json_raw "$PLAN_JSON" refused)" "H1b.2：I1 拒绝后 refused=true"
assert_eq "false" "$(json_raw "$PLAN_JSON" scan_ok)" "H1b.2：未完成的运行 scan_ok=false"
assert_eq "false" "$(json_raw "$PLAN_JSON" invariants_ok)" "H1b.2：未完成的运行 invariants_ok=false"
assert_eq "1" "$([ -n "$(json_str "$PLAN_JSON" note)" ] && printf '1' || printf '0')" "H1b.2：note 说明本次运行未完成"
h1b_after="$(shasum -a 256 < "$PLAN_JSON" | awk '{ print $1 }')"
assert_eq "rewritten" "$([ "$h1b_before" = "$h1b_after" ] && printf 'stale' || printf 'rewritten')" \
  "H1b.2：失败的那次确实改写了盘上的文件（不是旧内容原样留着）"
assert_eq "0" "$(json_bad_lines "$PLAN_JSON")" "H1b.4：未完成产物结构合法"
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$PLAN_JSON" >/dev/null 2>&1
  assert_eq "0" "$?" "H1b.4：未完成产物是真 JSON（python3 解析）"
else
  printf 'skip H1b.4：未完成产物真解析检查（本机无 python3）\n'
fi

# H1b.3：退出 1 的第一条路——镜像分支缺失。先回到 local 重新做出一个真凭证，再触发失败。
git -C "$SCRATCH_REPO" switch -q local
out13="$(bash "$PLAN" --no-fetch 2>&1)"; rc=$?
assert_eq "0" "$rc" "H1b.3 前提：可审批运行退出 0"
assert_eq "1" "$([ -n "$(json_str "$PLAN_JSON" plan_id)" ] && printf '1' || printf '0')" \
  "H1b.3 前提：此时盘上的 plan_id 非空"
git -C "$SCRATCH_REPO" branch -D main >/dev/null 2>&1
out14="$(bash "$PLAN" --no-fetch 2>&1)"; rc=$?
assert_eq "1" "$rc" "H1b.3：缺镜像分支退出 1"
assert_eq "0" "$(printf '%s\n' "$out14" | grep -c '^PLAN_ID=')" "H1b.3：退出 1 时不给 PLAN_ID"
assert_eq "" "$(json_str "$PLAN_JSON" plan_id)" "H1b.3：退出 1 之后盘上的 plan_id 已作废（空）"
assert_eq "true" "$(json_raw "$PLAN_JSON" refused)" "H1b.3：退出 1 之后 refused=true"

# H1b.3b：退出 1 的第二条路——fetch 失败（远端指向不存在的本地路径，不碰网络）
git -C "$SCRATCH_REPO" branch main local
out15="$(bash "$PLAN" --no-fetch 2>&1)"; rc=$?
assert_eq "0" "$rc" "H1b.3b 前提：可审批运行退出 0"
assert_eq "1" "$([ -n "$(json_str "$PLAN_JSON" plan_id)" ] && printf '1' || printf '0')" \
  "H1b.3b 前提：此时盘上的 plan_id 非空"
git -C "$SCRATCH_REPO" remote set-url upstream "$SCRATCH/nonexistent-remote.git"
out16="$(bash "$PLAN" 2>&1)"; rc=$?
assert_eq "1" "$rc" "H1b.3b：拉取失败退出 1"
assert_eq "0" "$(printf '%s\n' "$out16" | grep -c '^PLAN_ID=')" "H1b.3b：拉取失败时不给 PLAN_ID"
assert_eq "" "$(json_str "$PLAN_JSON" plan_id)" "H1b.3b：拉取失败之后盘上的 plan_id 已作废（空）"
assert_eq "true" "$(json_raw "$PLAN_JSON" refused)" "H1b.3b：拉取失败之后 refused=true"
assert_eq "0" "$(json_bad_lines "$PLAN_JSON")" "H1b.3b：未完成产物结构仍合法"

# H1b.4（F5.2）：「待合入提交数」的读取失败必须**说人话**，不得静默中止。
# 旧写法 `sync_git log … 2>/dev/null | wc -l | tr -d ' '`：管道里 wc/tr 恒成功，pipefail 把 git
# 的退出码冒到赋值语句上，set -e 当场中止——实测 plan 以 **128、零消息**结束（review 的表述是
# "降级成 0"，实测更正为"静默中止"；只要有人补一个 `|| true` 它才会真的变成 0，而 0 会写进报告
# 与 plan.json 的 upstream_new_commits）。这里把镜像尖端的提交对象弄坏来逼出这条读失败。
# 用 `commit-tree` 造一个**松散**提交（克隆来的对象在包里、改不动；这也正是下面那条前置断言
# 存在的理由），它在 local 一侧不可达，故只有走 `local..main` 的那次 `git log` 会去读它。
git -C "$SCRATCH_REPO" remote set-url upstream "$SCRATCH_UPSTREAM"
H1B4_TREE="$(git -C "$SCRATCH_REPO" rev-parse "main^{tree}")"
H1B4_OLD="$(git -C "$SCRATCH_REPO" rev-parse main)"
H1B4_NEW="$(git -C "$SCRATCH_REPO" commit-tree "$H1B4_TREE" -p "$H1B4_OLD" -m "mirror advance (fixture)")"
git -C "$SCRATCH_REPO" update-ref "refs/heads/main" "$H1B4_NEW"
H1B4_OBJ="$SCRATCH_REPO/.git/objects/${H1B4_NEW:0:2}/${H1B4_NEW:2}"
assert_eq "1" "$([ -f "$H1B4_OBJ" ] && printf 1 || printf 0)" \
  "H1b.4 前置：镜像尖端是松散对象（否则这个夹具改不动它）"
H1B4_MODE="$(stat -f '%Lp' "$H1B4_OBJ")"
cp "$H1B4_OBJ" "$SCRATCH/h1b4.bak"
chmod 644 "$H1B4_OBJ"
printf 'not-a-valid-zlib-object' > "$H1B4_OBJ"
H1B4_RL=0
git -C "$SCRATCH_REPO" log --oneline "local..main" >/dev/null 2>&1 || H1B4_RL=$?
out17="$(bash "$PLAN" --no-fetch 2>&1)"; rc=$?
cp "$SCRATCH/h1b4.bak" "$H1B4_OBJ"
chmod "$H1B4_MODE" "$H1B4_OBJ"
assert_eq "128" "$H1B4_RL" "H1b.4 前置：坏对象之后 local..main 的枚举确实失败（否则本用例是空转）"
assert_eq "1" "$rc" "H1b.4：读不出待合入提交数时以运行错误（1）退出，而不是静默中止"
assert_eq "1" "$(printf '%s\n' "$out17" | grep -c '无法枚举待合入提交')" \
  "H1b.4：给出可读的拒绝原因（旧实现这里一个字都不打）"
assert_eq "0" "$(printf '%s\n' "$out17" | grep -c '^PLAN_ID=')" "H1b.4：读不到时不签发凭证"
assert_eq "" "$(json_str "$PLAN_JSON" plan_id)" "H1b.4：读不到时盘上的 plan_id 已作废（空）"
assert_eq "0" "$(json_bad_lines "$PLAN_JSON")" "H1b.4：未完成产物结构仍合法"
out18="$(bash "$PLAN" --no-fetch 2>&1)"
assert_eq "1" "$(printf '%s\n' "$out18" | grep -c '^PLAN_ID=[0-9a-f]\{64\}$')" \
  "H1b.4：对象复原之后 plan 照常给出凭证（夹具的破坏被完整回滚）"

if [ "${TESTS_FAILED:-0}" -gt 0 ]; then
  printf '%s 项断言失败\n' "$TESTS_FAILED"
  exit 1
fi
exit 0
