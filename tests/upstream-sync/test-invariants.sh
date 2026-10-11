#!/usr/bin/env bash
set -uo pipefail
TESTS_FAILED=0
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib-assert.sh"

# G1：harness 自检。lib-assert.sh 没加载成功时断言会退化成空操作，
# 整个套件会"没有任何失败"地退出 0——那比失败更危险，故此处立即大声失败。
for _fn in assert_eq assert_exit scratch_setup scratch_teardown; do
  command -v "$_fn" >/dev/null 2>&1 \
    || { printf 'harness missing: lib-assert.sh did not load (%s)\n' "$_fn" >&2; exit 2; }
done

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export SYNC_REPO_ROOT="$REPO"
LIB="$REPO/skills/upstream-sync/scripts/sync-lib.sh"
. "$REPO/skills/upstream-sync/scripts/sync-lib.sh"

assert_eq "local" "$(sync_branch)" "I1 前提：当前分支为 local"
# B：镜像 ref 必须"存在"。旧写法 `rev-parse upstream/main 2>/dev/null || rev-parse main`
# 在 ref 缺失时会拿 main 和它自己比较，从而打印 ok（同义反复）；这里先断言存在，
# 再不带任何兜底地比较，缺失即表现为失败。
assert_exit 0 "I1：upstream/main 镜像 ref 必须存在" -- sync_ref_exists "$SYNC_UPSTREAM_REMOTE/main"
assert_eq "$(sync_git rev-parse main)" \
          "$(sync_git rev-parse "$SYNC_UPSTREAM_REMOTE/main")" \
          "I1：main 是 upstream 镜像"
assert_eq "" "$(sync_non_added_paths)" "I2：相对 main 全部为新增"

# F4：锁定冲突预演的输出契约——每个冲突只输出路径本身，每行一个。
# 用临时三处仓库构造同名技能（skills/<name>/SKILL.md）在 main 与 local 上的真实冲突。
scratch_setup
trap scratch_teardown EXIT

# A：锁定 fixture 的远端拓扑契约。origin = 用户自己的 fork，upstream = 上游本尊，
# 两者必须是不同的仓库；否则"fork 与 upstream 不同"的场景（apply 的 push 目标、
# push-range 扫描、origin/local 是否存在）根本无法构造。
A_ORIGIN_URL="$(git -C "$SCRATCH_REPO" remote get-url "$SYNC_ORIGIN_REMOTE")"
A_UPSTREAM_URL="$(git -C "$SCRATCH_REPO" remote get-url "$SYNC_UPSTREAM_REMOTE")"
if [ "$A_ORIGIN_URL" = "$A_UPSTREAM_URL" ]; then A_SAME="SAME"; else A_SAME="different"; fi
assert_eq "$SCRATCH_ORIGIN" "$A_ORIGIN_URL" "A：origin 指向 fork（即 SCRATCH_ORIGIN）"
assert_eq "$SCRATCH_UPSTREAM" "$A_UPSTREAM_URL" "A：upstream 指向上游（即 SCRATCH_UPSTREAM）"
assert_eq "different" "$A_SAME" "A：origin 与 upstream 不是同一个仓库"

git -C "$SCRATCH_REPO" switch -q main
printf 'from main\n' >> "$SCRATCH_REPO/skills/alpha/SKILL.md"
git -C "$SCRATCH_REPO" commit -qam "main 侧改动同名技能"
git -C "$SCRATCH_REPO" switch -q local
printf 'from local\n' >> "$SCRATCH_REPO/skills/alpha/SKILL.md"
git -C "$SCRATCH_REPO" commit -qam "local 侧改动同名技能"

assert_eq "1" "$(sync_conflict_preflight | wc -l | tr -d ' ')" \
          "F4：一个冲突只输出一行（不含 git 的 Auto-merging/CONFLICT 提示）"
assert_eq "skills/alpha/SKILL.md" "$(sync_conflict_preflight)" \
          "F4：输出的就是冲突路径本身"

# G2：锁定消费者的真实上下文。plan.sh / apply.sh 以 set -euo pipefail 运行。
# 实测（bash 3.2.57）：预演函数在冲突时返回非 0，只有"直接调用/管道"形状会被 set -e
# 杀死并丢掉全部输出；"$(预演)" 形状在 bash 3.2 里不受 -e 约束（见 G2b 注释）。
# 因此 G2a 用直接调用形状——它才是对 `|| true` 敏感的那条断言。
G2_DIR="$SCRATCH/g2"
mkdir -p "$G2_DIR"
G2_OUT_FILE="$G2_DIR/preflight-direct.txt"

G2_RC=0
SYNC_REPO_ROOT="$SCRATCH_REPO" bash -c '
  set -euo pipefail
  . "$1"
  sync_conflict_preflight > "$2"
' upstream-sync-preflight-child "$LIB" "$G2_OUT_FILE" || G2_RC=$?

assert_eq "0" "$G2_RC" \
          "G2a：set -euo pipefail 子壳里直接调用预演，不因冲突而中断（rc=0）"
assert_eq "skills/alpha/SKILL.md" "$(cat "$G2_OUT_FILE" 2>/dev/null)" \
          "G2a：直接调用取到的就是冲突路径（非空且相等）"

# G2b 记录 plan/apply 的实际调用形状，保证它在 set -euo pipefail 下也拿得到路径。
# 注意：bash 3.2 的 $( ) 不继承 -e，该形状即使去掉 `|| true` 也照样有输出，
# 故它不承担"守卫 `|| true`"的职责——那是 G2a 的职责。
G2_SUB_OUT="$(
  SYNC_REPO_ROOT="$SCRATCH_REPO" bash -c '
    set -euo pipefail
    . "$1"
    CONFLICTS="$(sync_conflict_preflight)"
    printf "%s" "$CONFLICTS"
  ' upstream-sync-preflight-child "$LIB"
)"
assert_eq "skills/alpha/SKILL.md" "$G2_SUB_OUT" \
          "G2b：plan/apply 的 CONFLICTS=\"\$(预演)\" 调用形状照常取到冲突路径"

# E：补上 Tasks 3–7 要消费、此前却没有断言的三处接口。
assert_exit 0 "E：sync_ref_exists 对存在的 ref 返回 0" -- sync_ref_exists "$SYNC_LOCAL_BRANCH"
assert_exit 1 "E：sync_ref_exists 对不存在的 ref 返回 1" -- sync_ref_exists refs/heads/no-such-ref

mkdir -p "$SCRATCH_REPO/skills/zeta"
printf 'x\n' > "$SCRATCH_REPO/skills/zeta/SKILL.md"
assert_eq "zeta" "$(sync_untracked_skills)" "E：未跟踪的 skills/<name>/ 被列为游离技能"

# 在 main 上、以 plan/apply 的 set -euo pipefail 上下文调用分支守卫。
git -C "$SCRATCH_REPO" switch -q main
E_BRANCH_RC=0
E_BRANCH_ERR="$(SYNC_REPO_ROOT="$SCRATCH_REPO" bash -c '
  set -euo pipefail
  . "$1"
  sync_require_local_branch
' upstream-sync-branch-child "$LIB" 2>&1)" || E_BRANCH_RC=$?

assert_eq "1" "$E_BRANCH_RC" "E：在 main 上子壳里的分支守卫以 1 退出"
case "$E_BRANCH_ERR" in
  upstream-sync:*main*) E_BRANCH_MSG="ok" ;;
  *)                    E_BRANCH_MSG="MISSING: $E_BRANCH_ERR" ;;
esac
assert_eq "ok" "$E_BRANCH_MSG" "E：拒绝消息带 upstream-sync: 前缀，且含分支名 main（A1 回归）"

if [ "${TESTS_FAILED:-0}" -gt 0 ]; then
  printf '%s 项断言失败\n' "$TESTS_FAILED"
  exit 1
fi
exit 0
