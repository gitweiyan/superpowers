#!/usr/bin/env bash
set -uo pipefail
TESTS_FAILED=0
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib-assert.sh"
# G1：harness 自检。lib-assert.sh 没加载成功时断言会退化成空操作，整个套件会"零失败"
# 地退出 0——那比失败更危险。
command -v assert_eq >/dev/null 2>&1 || { printf 'harness missing: lib-assert.sh did not load\n' >&2; exit 2; }
MECH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)/skills/upstream-sync/scripts"
PLAN="$MECH/plan.sh"
APPLY="$MECH/apply.sh"

# 64 个 0：必然不等于任何真实凭证（多条用例复用）
ZERO_ID="0000000000000000000000000000000000000000000000000000000000000000"
# upstream 的推送 URL 哨兵（与 lib-assert.sh 夹具、apply.sh 里的常量同一字面量）
SENTINEL_PUSH_URL="DISABLED-no-push"
# 敏感信息的运行时拼装：测试文件自身必须能通过扫描器，故不出现完整密钥字面量。
AWS_HEAD="AKIA"
AWS_TAIL="IOSFODNN7EXAMPLE"

# scratch_setup 只造好"从 fork 克隆、挂了 upstream 但未 fetch"的工作仓库；要让 upstream 前进，
# 还需要第二份可提交并推回上游裸库的工作拷贝（与 test-plan.sh 同名同义）。缺了这个变量，
# 下面的 "$SCRATCH_SEED2" 会在 set -u 下直接以 unbound variable 中止整个测试文件。
# 它必须跟着 SCRATCH 走：多段用例各自重开夹具（SCRATCH 是新临时目录），
# 用第一份的旧值去 clone 会在**已被删掉**的旧目录下重新长出目录树，成为漏在临时区里的垃圾。
seed2_path() { SCRATCH_SEED2="$SCRATCH/seed2"; }
# 造一个游离技能（未跟踪的 skills/<name>/SKILL.md）
make_skill() { # name description
  mkdir -p "$SCRATCH_REPO/skills/$1"
  printf -- '---\nname: %s\ndescription: %s\n---\n\n# %s\n' "$1" "$2" "$1" > "$SCRATCH_REPO/skills/$1/SKILL.md"
}
# 让 upstream 前进一个提交（返回前 fetch 由 plan 负责）；用于"本次确有合入动作"的夹具。
advance_upstream() { # skill-name
  git clone -q "$SCRATCH_UPSTREAM" "$SCRATCH_SEED2"
  git -C "$SCRATCH_SEED2" config user.name "$SCRATCH_USER"
  git -C "$SCRATCH_SEED2" config user.email "$SCRATCH_USER@$SCRATCH_DOMAIN"
  mkdir -p "$SCRATCH_SEED2/skills/$1"
  printf -- '---\nname: %s\ndescription: 上游新增\n---\n\n# %s\n' "$1" "$1" > "$SCRATCH_SEED2/skills/$1/SKILL.md"
  git -C "$SCRATCH_SEED2" add -A
  git -C "$SCRATCH_SEED2" commit -qm "$1"
  git -C "$SCRATCH_SEED2" push -q origin main
}
# 计划凭证必须形如 64 位十六进制
assert_plan_id() { # id desc
  assert_eq "1" "$(printf '%s' "$1" | grep -c '^[0-9a-f]\{64\}$')" "$2"
}

scratch_setup
trap scratch_teardown EXIT
seed2_path

# 1) PLAN_ID 不匹配 → 3
assert_exit 3 "过期的 PLAN_ID 被拒绝" -- bash "$APPLY" --plan-id "$ZERO_ID"
# C3：这一轮**不带 --no-push**，所以"没有推送"这句话真的可能为假（推送只被 --no-push 拦着时，
# 断言永远不可能因为"其实推了"而失败）。fork 上必须仍然没有 local 分支。
assert_exit 1 "C3：过期凭证被拒时 fork 上没有被推送 local 分支（本轮不带 --no-push）" \
  -- git -C "$SCRATCH_ORIGIN" rev-parse --verify --quiet refs/heads/local
# B7：清空注入（否则默认自检的构造根本不会跑，这条断言就测不到东西）后，
# 审批门拒绝的运行**不得**打出"跳过 graphviz"这类自检期提示——读起来像 apply 已经往下走了。
assert_eq "0" "$(SYNC_SELFTEST_CMD= bash "$APPLY" --plan-id "$ZERO_ID" 2>&1 | grep -c 'graphviz')" \
  "B7：审批门拒绝的运行不打出自检提示"

# 2) 工作区有非技能脏文件 → 4
# 注意顺序：审批门在干净检查之前，所以必须先弄脏、再取 PLAN_ID，否则会先撞 exit 3
printf 'dirty\n' >> "$SCRATCH_REPO/README.md"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_exit 4 "工作区不干净被拒绝" -- bash "$APPLY" --plan-id "$ID"
git -C "$SCRATCH_REPO" checkout -- README.md
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_plan_id "$ID" "恢复干净后可以重新取得计划"

# 3) upstream 新增同名技能 → 冲突预演 → 7
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
mkdir -p "$SCRATCH_REPO/skills/mine"
printf -- '---\nname: mine\ndescription: 我的同名\n---\n\n# mine\n' > "$SCRATCH_REPO/skills/mine/SKILL.md"
git -C "$SCRATCH_REPO" add skills/mine
git -C "$SCRATCH_REPO" commit -qm "add mine"
advance_upstream mine
ID="$(bash "$PLAN" | sed -n 's/^PLAN_ID=//p')"
assert_exit 7 "同名技能冲突被拒绝" -- bash "$APPLY" --plan-id "$ID"
assert_exit 1 "C3：冲突被拒时 fork 上没有被推送 local 分支（本轮不带 --no-push）" \
  -- git -C "$SCRATCH_ORIGIN" rev-parse --verify --quiet refs/heads/local

# 4) adopt + 合入：游离技能被采纳，upstream 新提交被 merge，提交后工作区干净
git -C "$SCRATCH_REPO" mv skills/mine skills/mine-local
git -C "$SCRATCH_REPO" commit -qm rename
make_skill fresh 新技能
ID="$(bash "$PLAN" | sed -n 's/^PLAN_ID=//p')"
assert_exit 0 "adopt 与合入成功（--adopt --no-push）" -- bash "$APPLY" --plan-id "$ID" --adopt --no-push
assert_eq "" "$(git -C "$SCRATCH_REPO" status --porcelain=v1)" "落地后工作区干净"
assert_eq "1" "$(git -C "$SCRATCH_REPO" log --oneline --merges main..local | wc -l | tr -d ' ')" "合入产生了 merge 提交"
# B5：先 merge 再 adopt 才成立——采纳提交的父提交必须是那个双亲 merge 提交。
# 反过来（先 adopt 再 merge）会让采纳在合并提交之前，甚至把暂存内容与合并混在一起。
assert_eq "merge" \
  "$(git -C "$SCRATCH_REPO" rev-list --parents -n 1 HEAD^ | awk '{ print (NF > 2) ? "merge" : "single" }')" \
  "B5：合入先于采纳（HEAD 的父提交是双亲 merge 提交）"

# 5) 幂等：无新提交、无游离技能时 apply 报"无需变更"并退出 0
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_exit 0 "无变更时 apply 退出 0" -- bash "$APPLY" --plan-id "$ID" --adopt --no-push

# 6) 命令行契约：缺值/未知选项/把选项当成值，都是用法错误（2），且要有可读消息。
# 旧形状 `PLAN_ID="${2:-}"; shift 2` 在 $#=1 时让 shift 失败、set -e 当场以 exit 1 静默中止，
# 连"缺少 --plan-id"都打不出来——退出码契约要求用法错误为 2。
assert_exit 2 "--plan-id 缺值为用法错误（2）" -- bash "$APPLY" --plan-id
assert_exit 2 "未知选项为用法错误（2）" -- bash "$APPLY" --bogus
assert_eq "1" "$(bash "$APPLY" --plan-id 2>&1 | grep -c '用法')" "缺值时给出一条用法消息（不是静默失败）"
# B8：`--plan-id --adopt` 是明显的命令行笔误。不拦的话 "--adopt" 会被当成凭证去比对，
# 报"计划已过期"（3）——把"参数写错了"说成"上游变了"，会把人指去重新审阅。
assert_exit 2 "B8：--plan-id 的取值形如选项时为用法错误（2）" -- bash "$APPLY" --plan-id --adopt

# 7) 仓库自检失败 → 6，且**不得提交、不得推送**。
# 换一份干净夹具：上面的夹具已经落地过，状态不该被后续用例污染。
scratch_teardown
scratch_setup
make_skill fresh 新技能
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
HEAD_BEFORE="$(git -C "$SCRATCH_REPO" rev-parse HEAD)"
# 自检命令由环境变量注入（夹具默认 true），这里让它失败。
SYNC_SELFTEST_CMD=false
export SYNC_SELFTEST_CMD
S6_ERR="$(bash "$APPLY" --plan-id "$ID" --adopt --no-push 2>&1 >/dev/null)" || S6_RC=$?
assert_eq "6" "${S6_RC:-0}" "仓库自检失败时拒绝（6）"
assert_eq "$HEAD_BEFORE" "$(git -C "$SCRATCH_REPO" rev-parse HEAD)" "自检失败时没有创建提交"
assert_exit 1 "前置：自检失败后 fork 上仍没有 local 分支（本轮以 --no-push 运行）" \
  -- git -C "$SCRATCH_ORIGIN" rev-parse --verify --quiet refs/heads/local
# B4：merge/采纳可能已经发生过，本地状态与批准时的凭证不再一致——文案必须说出来。
assert_eq "1" "$(printf '%s' "$S6_ERR" | grep -c '重新运行 plan')" \
  "B4：exit 6 的文案说明必须重新 plan（merge 可能已改本地状态）"
SYNC_SELFTEST_CMD=true
export SYNC_SELFTEST_CMD

# 8) A1b：`.sync/` 仍在**跟踪集**里 → 5，且必须在变更（merge/commit）之前拒绝。
# 旧的"查暂存区"守卫（git diff --cached）是死代码：它上面的 commit 已经消费掉索引，
# git diff --cached 必然为空，永远不可能触发。真正的风险是 .sync/ 被**误提交**过。
# 这里同时让 upstream 前进一个提交：若守卫放在 merge 之后，HEAD 就会变——断言把它钉死。
scratch_teardown
scratch_setup
seed2_path
mkdir -p "$SCRATCH_REPO/.sync"
printf 'local state\n' > "$SCRATCH_REPO/.sync/note.txt"
git -C "$SCRATCH_REPO" add -f .sync/note.txt
git -C "$SCRATCH_REPO" commit -qm "track local state"
advance_upstream upstreamnew
ID="$(bash "$PLAN" | sed -n 's/^PLAN_ID=//p')"
assert_plan_id "$ID" "A1b 前置：该夹具仍能取得计划（.sync/ 不阻断 plan）"
S8_HEAD="$(git -C "$SCRATCH_REPO" rev-parse HEAD)"
assert_exit 5 "A1b：已跟踪的 .sync/ 被拒绝（5）" -- bash "$APPLY" --plan-id "$ID" --no-push
assert_eq "$S8_HEAD" "$(git -C "$SCRATCH_REPO" rev-parse HEAD)" \
  "A1b：拒绝发生在 merge/commit 之前（本地零痕迹）"
assert_exit 1 "前置：A1b 拒绝后 fork 上仍没有 local 分支（--no-push 运行）" \
  -- git -C "$SCRATCH_ORIGIN" rev-parse --verify --quiet refs/heads/local

# 9) A1：`.sync/` 只在**历史**里（先提交、后删除）时，已跟踪检查沉默，只能靠"推送范围"这条
# 守卫拦住 —— 而它恰恰是 `producer | grep -q` 静默失效的那一类：grep -q 命中即退出，
# producer(git log) 收到 SIGPIPE 而死，pipefail 把 141 冒到 if 条件上，"命中"被读成"没命中"，
# 于是推送照常进行。守卫的存在理由就是这种长范围（首次推送一个长期分叉的 fork）。
scratch_teardown
scratch_setup
mkdir -p "$SCRATCH_REPO/.sync"
printf 'local state\n' > "$SCRATCH_REPO/.sync/note.txt"
git -C "$SCRATCH_REPO" add -f .sync/note.txt
git -C "$SCRATCH_REPO" commit -qm "track local state"
# 一次提交加进 4000 条路径、下一次提交把它们连同 .sync/note.txt 一起删掉：
#   - git log --name-only 在这段范围上的输出远超 64KB 管道缓冲（守卫失效的条件）
#   - 净 diff 为空 → 扫描器无需扫任何文件（夹具保持快）
#   - .sync/note.txt 出现在**最新**提交里，即输出开头，grep -q 会立刻命中并退出
mkdir -p "$SCRATCH_REPO/padding"
seq 1 4000 | awk '{ printf "padding/pad-%05d-0123456789012345678901234567890123456789.txt\n", $1 }' \
  | ( cd "$SCRATCH_REPO" && xargs touch )
git -C "$SCRATCH_REPO" add padding
git -C "$SCRATCH_REPO" commit -qm padding
git -C "$SCRATCH_REPO" rm -r -q padding .sync/note.txt
git -C "$SCRATCH_REPO" commit -qm "drop padding and local state"
make_skill fresh 新技能
A1_BYTES="$(git -C "$SCRATCH_REPO" log --format= --name-only main..local | wc -c | tr -d ' ')"
assert_eq "1" "$([ "$A1_BYTES" -gt 200000 ] && printf 1 || printf 0)" \
  "A1 前置：推送范围的路径清单远超管道缓冲（实测 ${A1_BYTES} 字节）"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_plan_id "$ID" "A1 前置：该夹具仍能取得计划"
A1_RC=0
A1_ERR="$(bash "$APPLY" --plan-id "$ID" --adopt --no-push 2>&1 >/dev/null)" || A1_RC=$?
assert_eq "5" "$A1_RC" "A1：长推送范围里含 .sync/ 时仍然拒绝（不得因 SIGPIPE 静默放行）"
assert_eq "1" "$(printf '%s' "$A1_ERR" | grep -c '推送范围内含 .sync/')" \
  "A1：拒绝理由是推送范围含 .sync/（不是别的闸门）"
assert_eq "1" "$(printf '%s' "$A1_ERR" | grep -c '重新运行 plan')" \
  "B4：exit 5 的文案说明必须重新 plan"
assert_exit 1 "前置：A1 拒绝后 fork 上仍没有 local 分支（--no-push 运行）" \
  -- git -C "$SCRATCH_ORIGIN" rev-parse --verify --quiet refs/heads/local

# 10) B3：adopt 里的 `sed … | head -1` 与 plan.sh 是同一形状，必须同样带 `|| true`。
# head -1 读够一行就退出，sed 若还有匹配行要写就会被 SIGPIPE 掉，pipefail 把这个 141 冒到
# 赋值语句上——set -e 当场中止一次本该成功的采纳。用超过 64KB 管道缓冲的匹配行逼出该形状。
scratch_teardown
scratch_setup
mkdir -p "$SCRATCH_REPO/skills/fat"
{
  printf -- '---\nname: fat\ndescription: 大量重复行\n---\n\n'
  i=1
  while [ "$i" -le 10000 ]; do printf 'name: fat\n'; i=$((i + 1)); done
} > "$SCRATCH_REPO/skills/fat/SKILL.md"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_exit 0 "B3：frontmatter 很长时采纳仍成功（sed|head 不得被 SIGPIPE 打断）" \
  -- bash "$APPLY" --plan-id "$ID" --adopt --no-push

# 11) A3：唯一的退出码映射表 —— 2 = 用法错误、分支错误，或调用方数据/计划期本应检出的问题；
# 1 只留给运行错误（git/IO）。分支不是 local 与 plan 的 I1 是同一个不变量，必须是 2。
scratch_teardown
scratch_setup
git -C "$SCRATCH_REPO" checkout -q main
assert_exit 2 "A3：不在 local 上时退出 2（与 plan 的 I1 一致，不再是 1）" -- bash "$APPLY" --plan-id "$ZERO_ID"
git -C "$SCRATCH_REPO" checkout -q local
mkdir -p "$SCRATCH_REPO/skills/badname"
printf -- '---\nname: somethingelse\ndescription: 名字与目录不一致\n---\n\n# bad\n' > "$SCRATCH_REPO/skills/badname/SKILL.md"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_exit 2 "A3：游离技能 frontmatter 不合法时退出 2（计划期本应检出）" \
  -- bash "$APPLY" --plan-id "$ID" --adopt --no-push
assert_eq "" "$(git -C "$SCRATCH_REPO" diff --cached --name-only)" \
  "A3：校验先于 git add，拒绝时没有留下暂存内容"

# 12) A2：推送目的地安全检查。origin 必须是自己的 fork —— 若它与 upstream 指向同一个仓库，
# 一次 apply 就会把整个分叉（含 .sync/ 历史）发布到上游，不可逆。
scratch_teardown
scratch_setup
make_skill fresh 新技能
git -C "$SCRATCH_REPO" remote set-url origin "$SCRATCH_UPSTREAM"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_exit 5 "A2a：origin 与 upstream 同源时拒绝（5）" -- bash "$APPLY" --plan-id "$ID" --adopt --no-push
assert_exit 1 "前置：A2a 拒绝后上游仍没有被写入 local 分支（--no-push 运行）" \
  -- git -C "$SCRATCH_UPSTREAM" rev-parse --verify --quiet refs/heads/local

# A2b：file:// 形态与裸路径指的是同一个仓库 —— 只做字符串比较会漏判，而漏判的后果
# 是把整个分叉推进上游。物理路径归一化后必须仍然判等。
scratch_teardown
scratch_setup
make_skill fresh 新技能
git -C "$SCRATCH_REPO" remote set-url origin "file://$SCRATCH_UPSTREAM"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_exit 5 "A2b：file:// 与裸路径同源时仍被识别（5）" -- bash "$APPLY" --plan-id "$ID" --adopt --no-push

# A2c：成对不变量 —— upstream 的**推送** URL 必须仍是禁用标记（本机制绝不向上游推送）
scratch_teardown
scratch_setup
make_skill fresh 新技能
git -C "$SCRATCH_REPO" remote set-url --push upstream "$SCRATCH_UPSTREAM"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
A2C_RC=0
A2C_ERR="$(bash "$APPLY" --plan-id "$ID" --adopt --no-push 2>&1 >/dev/null)" || A2C_RC=$?
assert_eq "5" "$A2C_RC" "A2c：upstream 推送 URL 不是禁用标记时拒绝（5）"
assert_eq "1" "$(printf '%s' "$A2C_ERR" | grep -c '不是禁用标记')" \
  "D2：此时给出的是哨兵不变量那条消息（检查顺序在前）"
assert_eq "0" "$(printf '%s' "$A2C_ERR" | grep -c '推送会把整个分叉')" \
  "D2：此时不得误报成「推送 URL 指向 upstream」"

# 22) D2：origin 的推送 URL 恰好等于那个哨兵时**不得**被误报成"指向 upstream"。
# 旧顺序先拿 origin 的 URL 去比 upstream 的推送 URL（= 哨兵），两者相等 → 报出与事实不符的理由，
# 而且更准确的哨兵消息被抢先。正确顺序：先判哨兵不变量，再拿 origin 的 URL 比 upstream 的 **fetch** URL。
scratch_teardown
scratch_setup
make_skill fresh 新技能
git -C "$SCRATCH_REPO" remote set-url --push origin "$SENTINEL_PUSH_URL"
D2_RC=0
D2_ERR="$(bash "$APPLY" --plan-id "$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')" --adopt --no-push 2>&1 >/dev/null)" || D2_RC=$?
assert_eq "0" "$D2_RC" "D2：origin 的 push URL 恰是哨兵时应放行（不得误报成「指向 upstream」）"
assert_eq "0" "$(printf '%s' "$D2_ERR" | grep -c '推送会把整个分叉')" \
  "D2：不得给出与事实不符的拒绝理由"

# 13) A4：真正执行一次推送（只对本地裸库夹具，绝不碰网络），证明"落地"这一步真的能用。
# 上面所有"没有推送"的断言只证明了否定命题，推不出去一样能让它们全绿。
scratch_teardown
scratch_setup
make_skill fresh 新技能
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_exit 0 "A4：不带 --no-push 时推送成功" -- bash "$APPLY" --plan-id "$ID" --adopt
assert_exit 0 "A4：fork 上出现了 local 分支" \
  -- git -C "$SCRATCH_ORIGIN" rev-parse --verify --quiet refs/heads/local
assert_eq "$(git -C "$SCRATCH_REPO" rev-parse local)" \
          "$(git -C "$SCRATCH_ORIGIN" rev-parse refs/heads/local)" \
          "A4：推上去的就是 local 的当前提交"

# 14) B1/B7：默认自检的构造路径（把注入的 SYNC_SELFTEST_CMD 清空）。
# 夹具里没有仓库自检文件，故必须失败为 6；同时"跳过 graphviz 测试"的响亮提示必须出现在
# **stderr**（不混进可解析的 stdout），而且只在真正走到自检那一步时才出现。
scratch_teardown
scratch_setup
make_skill fresh 新技能
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
B1_RC=0
SYNC_SELFTEST_CMD= bash "$APPLY" --plan-id "$ID" --adopt --no-push \
  > "$SCRATCH/b1out" 2> "$SCRATCH/b1err" || B1_RC=$?
assert_eq "6" "$B1_RC" "B1：不注入自检命令时（默认自检）夹具里自检失败 → 6"
# C4：跳过提示只在**没有** dot 的机器上出现，断言必须跟着环境走，
# 否则装了 graphviz 的机器会在这里假失败。
if command -v dot >/dev/null 2>&1; then
  assert_eq "0" "$(grep -c 'graphviz' "$SCRATCH/b1err")" "C4：有 dot 时不得打「跳过 graphviz」提示"
  assert_eq "1" "$(grep -c 'test-render-graphs' "$SCRATCH/b1err")" \
    "C4：有 dot 时 render-graphs 测试被前置进自检命令（缺失文件由 bash 报错可见）"
else
  assert_eq "1" "$(grep -c 'graphviz' "$SCRATCH/b1err")" "B7：无 dot 时跳过提示出现在 stderr"
  assert_eq "0" "$(grep -c 'graphviz' "$SCRATCH/b1out")" "B7：该提示不混进 stdout"
fi
assert_eq "1" "$(grep -c '重新运行 plan' "$SCRATCH/b1err")" "B4：默认自检失败的文案同样要求重新 plan"

# 15) B6：扫描器**命中**时不得说成"扫描器不可用"（否则会把人指去修一份其实没问题的内容）。
# plan.sh 已有三态文案，apply 必须一致。这里让一个待采纳的游离技能里带上密钥形状的内容。
scratch_teardown
scratch_setup
mkdir -p "$SCRATCH_REPO/skills/leaky"
printf -- '---\nname: leaky\ndescription: 泄漏用\n---\n\n' > "$SCRATCH_REPO/skills/leaky/SKILL.md"
printf '%s%s\n' "$AWS_HEAD" "$AWS_TAIL" >> "$SCRATCH_REPO/skills/leaky/SKILL.md"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_plan_id "$ID" "B6 前置：未跟踪的泄漏文件不影响 plan（它不在已提交范围里）"
B6_RC=0
B6_ERR="$(bash "$APPLY" --plan-id "$ID" --adopt --no-push 2>&1 >/dev/null)" || B6_RC=$?
assert_eq "5" "$B6_RC" "B6：暂存内容命中敏感信息时拒绝（5）"
assert_eq "1" "$(printf '%s' "$B6_ERR" | grep -c '暂存内容敏感信息复检命中')" \
  "B6：文案明确指出是命中"
assert_eq "0" "$(printf '%s' "$B6_ERR" | grep -c '不可用')" \
  "B6：命中时不得说扫描器不可用"
assert_exit 1 "前置：B6 拒绝后 fork 上仍没有 local 分支（--no-push 运行）" \
  -- git -C "$SCRATCH_ORIGIN" rev-parse --verify --quiet refs/heads/local

# 16) B2：脏工作区检查的 producer 失败必须**失败关闭**。
# 旧写法 `sync_status_porcelain | grep -v … || true` 里的 `|| true` 本意是吞掉 grep"无匹配"的 1，
# 却把 producer（git status）自身失败一起吞掉：DIRTY 退化成空，一个**根本读不出来**的工作区
# 被当成干净放行（fail-open），后面还会继续往 merge/commit 走。
# 这里用不可读的索引把 git status 逼成失败；rev-parse 仍可用，故门卫与审批门照常通过
#（干净夹具下 plan 与 apply 两边的降级结果一致，凭证仍然匹配）。
# 顺序很重要：plan 必须在索引**可读**时取凭证——索引不可读时 plan 自己会以 128 中止。
scratch_teardown
scratch_setup
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_plan_id "$ID" "B2 前置：干净夹具取得计划"
B2_INDEX_MODE="$(stat -f '%Lp' "$SCRATCH_REPO/.git/index")"
chmod 000 "$SCRATCH_REPO/.git/index"
if git -C "$SCRATCH_REPO" status --porcelain=v1 >/dev/null 2>&1; then B2_BROKEN=0; else B2_BROKEN=1; fi
assert_eq "1" "$B2_BROKEN" "B2 前置：索引不可读后 git status 确实失败（否则本用例是空转）"
B2_RC=0
B2_ERR="$(bash "$APPLY" --plan-id "$ID" --no-push 2>&1 >/dev/null)" || B2_RC=$?
chmod "$B2_INDEX_MODE" "$SCRATCH_REPO/.git/index"
assert_eq "1" "$B2_RC" "B2：读不出工作区状态时以运行错误（1）拒绝，而不是当成干净放行"
assert_eq "1" "$(printf '%s' "$B2_ERR" | grep -c '无法读取工作区状态')" "B2：给出可读的拒绝原因"

# 17) C1a：pushurl 覆盖。`git push origin local` 用的是 **push** URL，而 `remote.origin.pushurl`
# 可以被单独改成 upstream——只看 origin 的 fetch URL 会放行，而实际推送却发往上游，
# 正是 A2 存在要防的那件事。
scratch_teardown
scratch_setup
make_skill fresh 新技能
git -C "$SCRATCH_REPO" remote set-url --push origin "$SCRATCH_UPSTREAM"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_exit 5 "C1a：origin 的推送 URL 指向 upstream 时拒绝（5）" \
  -- bash "$APPLY" --plan-id "$ID" --adopt
assert_exit 1 "C1a：上游没有被写入 local 分支（本轮不带 --no-push：检查若失效，这里真的会被写上去）" \
  -- git -C "$SCRATCH_UPSTREAM" rev-parse --verify --quiet refs/heads/local

# 18) C1b：读不到 upstream 远端时必须**失败关闭**。旧写法 `… get-url upstream 2>/dev/null || true`
# 会把它变成空串，而空串永远不等于非空的 origin URL，于是"同源"检查静默放行。
scratch_teardown
scratch_setup
make_skill fresh 新技能
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
git -C "$SCRATCH_REPO" remote remove upstream
C1_RC=0
C1_ERR="$(bash "$APPLY" --plan-id "$ID" --adopt --no-push 2>&1 >/dev/null)" || C1_RC=$?
assert_eq "1" "$C1_RC" "C1b：读不到 upstream 远端时以运行错误（1）拒绝，而不是静默放行"
assert_eq "1" "$(printf '%s' "$C1_ERR" | grep -c '读不到远端 upstream')" \
  "C1b：拒绝原因点名是读不到远端 upstream"

# 19) C2：B6 的"扫描器不可用"分支**是可达的**（先前把它判成不可达是错的）。
# 机理：sync_state_hash 只把扫描器的 **stdout** 计入哈希，而扫描器不可用时 fail_usage 走 stderr，
# 于是哈希块与"干净扫描"逐字节相同——规则表**不是**哈希输入。
# 路由：在干净状态取凭证 → 让规则表不可读（chmod 只改读位；夹具里根本不含该文件，
# 故夹具的 git status 保持干净、脏检查不会先拦）→ 审批门照样通过 → 走到暂存区复检 → rc 2。
# 关键：**不碰被审查的检出**。按 test-scanner.sh 的 mk_engine 套路，把整套机制复制到临时目录里，
# 让 apply/plan/扫描器/hash 全都用那份副本（脚本按自身目录定位规则表），
# 真实仓库的文件从头到尾没被改过——SIGKILL 或 harness 超时也不会留下不可读的规则表。
mk_engine_full() { # 目标目录：整套机制 + 规则表
  mkdir -p "$1"
  cp "$MECH/apply.sh" "$MECH/plan.sh" "$MECH/sync-lib.sh" "$MECH/scan-sensitive.sh" "$MECH/patterns.tsv" "$1/"
}
scratch_teardown
scratch_setup
make_skill fresh 新技能
ENGINE="$SCRATCH/engine"
mk_engine_full "$ENGINE"
ID="$(bash "$ENGINE/plan.sh" --no-fetch | sed -n 's/^PLAN_ID=//p')"
MECH_TABLE_MODE="$(stat -f '%Lp' "$MECH/patterns.tsv")"
ENGINE_TABLE_MODE="$(stat -f '%Lp' "$ENGINE/patterns.tsv")"
chmod 000 "$ENGINE/patterns.tsv"
C2_SCAN_RC=0
bash "$ENGINE/scan-sensitive.sh" --staged >/dev/null 2>&1 || C2_SCAN_RC=$?
assert_eq "2" "$C2_SCAN_RC" "C2 前置：规则表不可读时扫描器返回 2（不可用）"
C2_RC=0
C2_ERR="$(bash "$ENGINE/apply.sh" --plan-id "$ID" --adopt 2>&1 >/dev/null)" || C2_RC=$?
chmod "$ENGINE_TABLE_MODE" "$ENGINE/patterns.tsv"
assert_eq "5" "$C2_RC" "C2：扫描器不可用时 apply 以 5 拒绝（该分支确实可达）"
assert_eq "1" "$(printf '%s' "$C2_ERR" | grep -c '复检无法完成')" \
  "C2：文案说的是「无法完成」，不是「命中」"
assert_eq "0" "$(printf '%s' "$C2_ERR" | grep -c '复检命中')" \
  "C2：扫描器不可用时不得说成命中（否则会把人指去改一份其实没问题的内容）"
assert_exit 1 "C2：拒绝时没有推送（本轮不带 --no-push，故该项真的能失败）" \
  -- git -C "$SCRATCH_ORIGIN" rev-parse --verify --quiet refs/heads/local
assert_eq "1" "$([ -r "$ENGINE/patterns.tsv" ] && printf 1 || printf 0)" \
  "C2：副本规则表的读权限已恢复"
assert_eq "$MECH_TABLE_MODE" "$(stat -f '%Lp' "$MECH/patterns.tsv")" \
  "C2：被审查检出的规则表模式前后一致（本用例只动临时副本）"

# 23) D1：origin 配了**多个** pushurl 时，只能读到第一个是不够的。
# `git push origin local` 会把每一个 pushurl 都推一遍，而 `git remote get-url --push origin`
# （不带 --all）只打印第一个。于是 [fork, upstream] 这种配置下，旧检查读到 fork 就放行，
# 实际推送却同时在 upstream 里建出 local 分支——正是 A2/C1 要防的那件事。
scratch_teardown
scratch_setup
make_skill fresh 新技能
git -C "$SCRATCH_REPO" remote set-url --push origin "$SCRATCH_ORIGIN"
git -C "$SCRATCH_REPO" remote set-url --add --push origin "$SCRATCH_UPSTREAM"
assert_eq "$SCRATCH_ORIGIN" "$(git -C "$SCRATCH_REPO" remote get-url --push origin)" \
  "D1 前置：不带 --all 的读取只返回第一个 pushurl（这就是绕过点）"
assert_eq "2" "$(git -C "$SCRATCH_REPO" remote get-url --all --push origin | wc -l | tr -d ' ')" \
  "D1 前置：夹具确实配了两个 pushurl"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_exit 5 "D1：多个 pushurl 里有 upstream 时拒绝（5）" -- bash "$APPLY" --plan-id "$ID" --adopt
assert_exit 1 "D1：上游替身没有被写入 local 分支（本轮不带 --no-push）" \
  -- git -C "$SCRATCH_UPSTREAM" rev-parse --verify --quiet refs/heads/local
assert_exit 1 "D1：fork 同样没有被写入（拒绝发生在任何推送之前）" \
  -- git -C "$SCRATCH_ORIGIN" rev-parse --verify --quiet refs/heads/local

# 20) C6：`git push` 失败必须有可读消息（并说清本地提交没丢、重试即可），
# 不能带着 git 的原始退出码静默中止。
scratch_teardown
scratch_setup
make_skill fresh 新技能
git -C "$SCRATCH_REPO" remote set-url origin "$SCRATCH/nonexistent-origin.git"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
C6_RC=0
C6_ERR="$(bash "$APPLY" --plan-id "$ID" --adopt 2>&1 >/dev/null)" || C6_RC=$?
assert_eq "1" "$C6_RC" "C6：推送失败以运行错误（1）退出"
assert_eq "1" "$(printf '%s' "$C6_ERR" | grep -c '本地提交')" \
  "C6：文案说明本地提交完好、重试即可"
# F3：那句"重跑 apply 即可重试"只在**这一轮没有产生提交**时成立。本轮带了 --adopt，采纳提交
# 已经落在 local 上：本地状态与批准时的凭证不再一致，重跑会先卡在审批门以 exit 3 拒绝，
# 必须重新 plan 取新凭证。说成"重跑即可"会把人送进一个必然失败的循环——脚本自己修过这一类
# 假承诺（N5/P1），这里不是例外。
assert_eq "1" "$(printf '%s' "$C6_ERR" | grep -c 'exit 3')" \
  "C6b：推送失败的文案必须条件化，点名「已产生提交时重跑会先撞审批门（exit 3）」"
assert_eq "1" "$(printf '%s' "$C6_ERR" | grep -c '重新 plan')" \
  "C6b：条件化之后必须给出正确的下一步（重新 plan）"

# 21) C7：`.sync/` 守卫锚定的是**字面前缀 ".sync/"**（用 awk 的 index() 做前缀匹配，
# 前缀由 $SYNC_STATE_DIR 插值），既不是"名字里含 sync"，也不是未转义的正则。
# 两条反向路径各自抓一类写坏法：
#   - xsync/note.txt ：抓"漏转义"——写成 ^${SYNC_STATE_DIR}/ 时 . 变成任意字符，x 也会命中；
#   - .xsync/note.txt：抓"按子串/含 sync 匹配"——那种写法会把它一起拦下。
# 两者都必须放行；旧写法 ^[.]sync/ 恰好也不匹配它们，所以这条用例锁定的是性质而不是旧缺陷。
scratch_teardown
scratch_setup
mkdir -p "$SCRATCH_REPO/xsync" "$SCRATCH_REPO/.xsync"
printf 'local state\n' > "$SCRATCH_REPO/xsync/note.txt"
printf 'local state\n' > "$SCRATCH_REPO/.xsync/note.txt"
git -C "$SCRATCH_REPO" add xsync/note.txt .xsync/note.txt
git -C "$SCRATCH_REPO" commit -qm "add xsync and .xsync (neither is .sync)"
make_skill fresh 新技能
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_exit 0 "C7：xsync/note.txt 与 .xsync/note.txt 都不得触发 .sync/ 守卫" \
  -- bash "$APPLY" --plan-id "$ID" --adopt --no-push

# 24) N1：手工提交的内容必须能被发布。
# 旧早退条件只看 CHANGED（只有 merge 或 adopt 才算"有事要做"），于是最普通的一条用户路径被
# 静默丢掉：自己把改动提交进 local、upstream 恰好没有新提交、又没有游离技能 —— apply 打印
# "无需变更"、退出 0，本地提交永远出不了门。这正是"把本地新增同步进代码库"这个核心要求本身，
# 故早退必须同时看"有没有事要做"和"有没有东西要推"。
scratch_teardown
scratch_setup
mkdir -p "$SCRATCH_REPO/docs/local"
printf 'hand written\n' > "$SCRATCH_REPO/docs/local/notes.md"
git -C "$SCRATCH_REPO" add docs/local/notes.md
git -C "$SCRATCH_REPO" commit -qm "manual addition"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_plan_id "$ID" "N1 前置：手工提交后仍能取得计划（纯新增，I2 通过）"
assert_exit 1 "N1 前置：推送前 fork 上还没有 local 分支" \
  -- git -C "$SCRATCH_ORIGIN" rev-parse --verify --quiet refs/heads/local
N1_RC=0
N1_OUT="$(bash "$APPLY" --plan-id "$ID" 2>&1)" || N1_RC=$?
# 注意这条的判别力：旧代码在这条上**也是 0**（它打印"无需变更"然后什么都没推），所以它本身
# 不是 RED —— 真正判红的是下面两条（身份报告 / fork 上的 local 引用）。这里只断言"退出码为 0"，
# 不声称它区分新旧行为。
assert_eq "0" "$N1_RC" "N1：手工提交后 apply 退出 0（该值新旧代码相同，判别力在下面两条断言）"
assert_eq "1" "$(printf '%s' "$N1_OUT" | grep -c '将推送的提交身份')" \
  "N1：这条路径确实跑到了推送前的身份报告"
assert_exit 0 "N1：fork 上出现了 local 分支" \
  -- git -C "$SCRATCH_ORIGIN" rev-parse --verify --quiet refs/heads/local
assert_eq "$(git -C "$SCRATCH_REPO" rev-parse local)" \
          "$(git -C "$SCRATCH_ORIGIN" rev-parse refs/heads/local)" \
          "N1：推上去的就是 local 的当前提交"

# 24b) N1 的反面：真的无事可做时仍然早退，且什么都不推。
# 最后一条把"早退"钉在**自检之前**：自检命令被设成失败，若这一轮仍然是 0，说明它根本没走到自检，
# 而不是"跑完了所有闸门之后恰好没东西可推"。
N1_FORK_BEFORE="$(git -C "$SCRATCH_ORIGIN" rev-parse refs/heads/local)"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
N1B_RC=0
N1B_OUT="$(bash "$APPLY" --plan-id "$ID" 2>&1)" || N1B_RC=$?
assert_eq "0" "$N1B_RC" "N1b：无事可做时仍然退出 0"
assert_eq "1" "$(printf '%s' "$N1B_OUT" | grep -c '无需变更')" "N1b：无事可做时文案仍是「无需变更」"
assert_eq "$N1_FORK_BEFORE" "$(git -C "$SCRATCH_ORIGIN" rev-parse refs/heads/local)" \
  "N1b：无事可做时不推送（fork 的 local 一动没动）"
assert_exit 0 "N1b：早退发生在自检之前（自检失败也不影响无事可做的 0）" \
  -- env SYNC_SELFTEST_CMD=false bash "$APPLY" --plan-id "$ID"

# 25) N1c：新的"有东西要推"路径必须照旧走完整的推送前序列（推送范围 → 身份报告 → G3 → .sync/ 守卫）。
# 用只有"推送范围"守卫能拦的形状：历史里曾经提交过 .sync/，现在已删掉。
#   - 净 diff 为空 → I2 通过；索引干净 → 工作区干净检查通过；
#   - .sync/ 路径被扫描器按定义跳过 → G1（plan）与 G3 都报干净；
#   - 剩下的只有 has_dot_sync_path 这一条，而它坐在身份报告与 G3 **之后**。
# 若新的推送路径把这段整段跳过，这个提交会真的落到 fork 上。
scratch_teardown
scratch_setup
mkdir -p "$SCRATCH_REPO/.sync"
printf 'local state\n' > "$SCRATCH_REPO/.sync/note.txt"
git -C "$SCRATCH_REPO" add -f .sync/note.txt
git -C "$SCRATCH_REPO" commit -qm "track local state"
git -C "$SCRATCH_REPO" rm -r -q .sync
git -C "$SCRATCH_REPO" commit -qm "untrack local state"
assert_eq "" "$(git -C "$SCRATCH_REPO" status --porcelain=v1)" "N1c 前置：工作区干净"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_plan_id "$ID" "N1c 前置：I2 与 G1 都通过（该夹具仍能取得计划）"
N1C_RC=0
N1C_OUT="$(bash "$APPLY" --plan-id "$ID" 2>&1)" || N1C_RC=$?
assert_eq "5" "$N1C_RC" "N1c：手工提交路径上，推送范围里的 .sync/ 仍被拦下（5）"
assert_eq "1" "$(printf '%s' "$N1C_OUT" | grep -c '推送范围内含 .sync/')" \
  "N1c：拒绝理由是推送范围含 .sync/（不是别的闸门）"
assert_eq "1" "$(printf '%s' "$N1C_OUT" | grep -c '将推送的提交身份')" \
  "N1c：推送前序列确实跑到了身份报告那一步（守卫没有整段被跳过）"
assert_exit 1 "N1c：拒绝时没有推送（本轮不带 --no-push，故该项真的能失败）" \
  -- git -C "$SCRATCH_ORIGIN" rev-parse --verify --quiet refs/heads/local

# 26) N1d：同一条路径上的推送目的地守卫不得被跳过 —— origin 指着 upstream 时拒绝，
# 而且两台远端都不许出现 local。
scratch_teardown
scratch_setup
mkdir -p "$SCRATCH_REPO/docs/local"
printf 'hand written\n' > "$SCRATCH_REPO/docs/local/notes.md"
git -C "$SCRATCH_REPO" add docs/local/notes.md
git -C "$SCRATCH_REPO" commit -qm "manual addition"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
git -C "$SCRATCH_REPO" remote set-url origin "$SCRATCH_UPSTREAM"
assert_exit 5 "N1d：手工提交路径上 origin 指向 upstream 时仍拒绝（5）" -- bash "$APPLY" --plan-id "$ID"
assert_exit 1 "N1d：fork 上没有 local（拒绝发生在任何推送之前）" \
  -- git -C "$SCRATCH_ORIGIN" rev-parse --verify --quiet refs/heads/local
assert_exit 1 "N1d：上游也没有被写入 local" \
  -- git -C "$SCRATCH_UPSTREAM" rev-parse --verify --quiet refs/heads/local

# 27) N1e：有东西要推的时候，脏工作区检查仍然在推送之前（4）。
scratch_teardown
scratch_setup
mkdir -p "$SCRATCH_REPO/docs/local"
printf 'hand written\n' > "$SCRATCH_REPO/docs/local/notes.md"
git -C "$SCRATCH_REPO" add docs/local/notes.md
git -C "$SCRATCH_REPO" commit -qm "manual addition"
printf 'dirty\n' >> "$SCRATCH_REPO/README.md"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_exit 4 "N1e：有东西要推但工作区脏时仍然拒绝（4）" -- bash "$APPLY" --plan-id "$ID"
assert_exit 1 "N1e：拒绝时没有推送（本轮不带 --no-push）" \
  -- git -C "$SCRATCH_ORIGIN" rev-parse --verify --quiet refs/heads/local

# 28) P1：自检失败时的"运行时可见性"文案必须**条件化**，不能无条件宣称"因运行时是符号链接"。
# 在一次性收敛 M6 尚未执行的机器上那句宣称是假的；而 N1 之后这条路径更容易被走到 —— 任何
# "手工提交 + 自检失败"的发布都停在这里。
# 两个分支各自一份夹具：自检失败发生在采纳提交**之前**，但它前面的 `git add` 已经动了索引，
# 于是同一份凭证在第二次运行里会先撞上 exit 3（状态已变），不能在同一夹具上连着跑两次。
# 运行时根用 SYNC_RUNTIME_SKILLS_ROOT 显式指定，免得断言随开发机 ~/.dsh/skills 的实际状态漂移。
scratch_teardown
scratch_setup
make_skill fresh 新技能
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
P1A_RC=0
P1A_ERR="$(SYNC_SELFTEST_CMD=false SYNC_RUNTIME_SKILLS_ROOT="$SCRATCH/no-runtime-root" \
  bash "$APPLY" --plan-id "$ID" --adopt --no-push 2>&1 >/dev/null)" || P1A_RC=$?
assert_eq "6" "$P1A_RC" "P1 前置：自检失败仍以 6 拒绝"
assert_eq "1" "$(printf '%s' "$P1A_ERR" | grep -c '尚未生效')" \
  "P1a：运行时根不是符号链接时必须说「尚未生效」"
assert_eq "0" "$(printf '%s' "$P1A_ERR" | grep -c '已在运行时可见')" \
  "P1a：此时不得宣称新内容已在运行时可见"

scratch_teardown
scratch_setup
make_skill fresh 新技能
ln -s "$SCRATCH_REPO/skills" "$SCRATCH/runtime-link"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
P1B_RC=0
P1B_ERR="$(SYNC_SELFTEST_CMD=false SYNC_RUNTIME_SKILLS_ROOT="$SCRATCH/runtime-link" \
  bash "$APPLY" --plan-id "$ID" --adopt --no-push 2>&1 >/dev/null)" || P1B_RC=$?
assert_eq "6" "$P1B_RC" "P1 前置：符号链接分支同样以 6 拒绝"
assert_eq "1" "$(printf '%s' "$P1B_ERR" | grep -c '已在运行时可见')" \
  "P1b：运行时根确实指向本仓库 skills/ 时才说「已在运行时可见」"
assert_eq "0" "$(printf '%s' "$P1B_ERR" | grep -c '尚未生效')" \
  "P1b：此时不得说「尚未生效」"

# 29) F1：静态扫描的跳过集必须与两道**根锚定**的 `.sync/` 守卫一致。
# `skills/<x>/.sync/key.txt` 正好落在两者之间的缝里：`git ls-files -- .sync/` 匹配不到它
# （pathspec 是根锚定的），`has_dot_sync_path` 只认行首的 `.sync/`，故两道守卫都不会拦；
# 而扫描器又只因为它名字里带 `.sync/` 就豁免它。旧实现的结果是：plan 照常签发 PLAN_ID、
# apply 以 rc=0 把这份凭据推上 fork（review 实测：内容真的到了远端）。跳过清单收窄成
# "仓库根的 `.sync/*` 加这一个规则表文件"之后，两边一致 —— 缝没了，G1 当场命中。
scratch_teardown
scratch_setup
mkdir -p "$SCRATCH_REPO/skills/probe/.sync"
printf 'aws_key = %s%s\n' "$AWS_HEAD" "$AWS_TAIL" > "$SCRATCH_REPO/skills/probe/.sync/key.txt"
# -f：`.sync/` 在 .git/info/exclude 里的写法是按目录名匹配的（plan.sh 为根状态目录写的），
# 这里的嵌套目录只是夹具的一部分，必须能入库。
git -C "$SCRATCH_REPO" add -f skills/probe/.sync/key.txt
git -C "$SCRATCH_REPO" commit -qm "hand written: nested .sync path carrying a credential"
# 判别力前置：三道闸门里**只有扫描器**够得着这条路径（两道守卫按设计都匹配不到它）。
assert_eq "" "$(git -C "$SCRATCH_REPO" ls-files -- .sync/)" \
  "F1 前置：跟踪集守卫（pathspec .sync/）匹配不到这条嵌套路径"
assert_eq "0" "$(git -C "$SCRATCH_REPO" log --format= --name-only main..local | grep -c '^\.sync/')" \
  "F1 前置：推送范围守卫（只认行首 .sync/）同样匹配不到它"
assert_eq "1" "$(git -C "$SCRATCH_REPO" log --format= --name-only main..local \
  | grep -c '^skills/probe/\.sync/key\.txt$')" \
  "F1 前置：这条路径确实在 G1 与推送范围里（否则上面两条前置都是空转）"
NEST_RC=0
NEST_OUT="$(bash "$PLAN" --no-fetch 2>&1)" || NEST_RC=$?
assert_eq "2" "$NEST_RC" "F1：嵌套 .sync/ 里的凭据形状必须让 plan 以 2 拒绝（旧实现签发 PLAN_ID）"
assert_eq "0" "$(printf '%s\n' "$NEST_OUT" | grep -c '^PLAN_ID=')" \
  "F1：拒绝时不给 PLAN_ID —— 没有凭证，就没有能把它推出去的那条路"
assert_eq "1" "$(printf '%s\n' "$NEST_OUT" | grep -c '^敏感信息扫描   : 命中，已阻断$')" \
  "F1：报告说的是命中（不是「扫描器不可用」这类别的理由）"
assert_eq "1" "$(printf '%s\n' "$NEST_OUT" | grep -c 'skills/probe/\.sync/key\.txt:1:cred-aws-access-key: ')" \
  "F1：报告点名的是那条嵌套路径上的内容命中"

# 30) F5.3：合入前的提交数比较必须**显式失败关闭**。
# 旧写法 `[ "$(sync_git rev-list --count "$LOCAL..$MIRROR")" != "0" ]`：git 读不出来时命令替换
# 给出空串，而空串永远"不等于 0"——于是"读不到"被读成"有东西要合入"，紧接着 `git merge --no-ff`
# 也读不出来、在 set -e 上中止：实测 apply 以 **128、零消息**结束，用户只看到一个数字（与
# "静默放行"方向相反，但同属把失败降级成猜测）。这里把镜像尖端的提交对象弄坏来逼出它。
scratch_teardown
scratch_setup
mkdir -p "$SCRATCH_REPO/docs/local"
printf 'hand written\n' > "$SCRATCH_REPO/docs/local/notes.md"
git -C "$SCRATCH_REPO" add docs/local/notes.md
git -C "$SCRATCH_REPO" commit -qm "manual addition"
# 镜像尖端用**新造的松散提交**（plumbing，不 checkout 任何分支）：它在 local 一侧不可达，
# 故 `git status` 不会去读它，只有 `rev-list --count local..main` 会。克隆来的对象在包里，
# 改不动；新提交一定是松散对象，才改得动（这也是下面那条前置断言存在的理由）。
# 分支名写死 `main`：本文件不 source sync-lib.sh，而上面的用例本来就用字面量 `main..local`。
F53_TREE="$(git -C "$SCRATCH_REPO" rev-parse "main^{tree}")"
F53_OLD="$(git -C "$SCRATCH_REPO" rev-parse main)"
F53_NEW="$(git -C "$SCRATCH_REPO" commit-tree "$F53_TREE" -p "$F53_OLD" -m "mirror advance (fixture)")"
git -C "$SCRATCH_REPO" update-ref "refs/heads/main" "$F53_NEW"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_plan_id "$ID" "F5.3 前置：夹具仍能取得计划（坏对象发生在取凭证之后）"
F53_OBJ="$SCRATCH_REPO/.git/objects/${F53_NEW:0:2}/${F53_NEW:2}"
assert_eq "1" "$([ -f "$F53_OBJ" ] && printf 1 || printf 0)" \
  "F5.3 前置：镜像尖端是松散对象（否则这个夹具改不动它）"
F53_MODE="$(stat -f '%Lp' "$F53_OBJ")"
cp "$F53_OBJ" "$SCRATCH/f53.bak"
chmod 644 "$F53_OBJ"
printf 'not-a-valid-zlib-object' > "$F53_OBJ"
F53_RL=0
git -C "$SCRATCH_REPO" rev-list --count "local..main" >/dev/null 2>&1 || F53_RL=$?
F53_ST=0
git -C "$SCRATCH_REPO" -c core.quotePath=false -c status.showUntrackedFiles=all status --porcelain=v1 >/dev/null 2>&1 || F53_ST=$?
F53_RC=0
F53_ERR="$(bash "$APPLY" --plan-id "$ID" --no-push 2>&1 >/dev/null)" || F53_RC=$?
cp "$SCRATCH/f53.bak" "$F53_OBJ"
chmod "$F53_MODE" "$F53_OBJ"
assert_eq "128" "$F53_RL" "F5.3 前置：坏对象之后 rev-list --count 确实失败（否则本用例是空转）"
assert_eq "0" "$F53_ST" "F5.3 前置：git status 不受影响（所以不会先撞上工作区那条守卫）"
assert_eq "1" "$F53_RC" "F5.3：读不出待合入提交数时以运行错误（1）拒绝，而不是静默中止"
assert_eq "1" "$(printf '%s' "$F53_ERR" | grep -c '无法读取待合入提交数')" \
  "F5.3：给出可读的拒绝原因（旧实现这里一个字都不打）"

if [ "${TESTS_FAILED:-0}" -gt 0 ]; then
  printf '%s 项断言失败\n' "$TESTS_FAILED"
  exit 1
fi
exit 0
