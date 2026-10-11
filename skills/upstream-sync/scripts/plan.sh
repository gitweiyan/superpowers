#!/usr/bin/env bash
# 只读计划：拉取镜像、体检、预演冲突、扫描、出报告与 PLAN_ID。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$HERE/sync-lib.sh"

FETCH=1
[ "${1:-}" = "--no-fetch" ] && FETCH=0

ROOT="$(sync_repo_root)"
SCAN="$HERE/scan-sensitive.sh"
STATE_PATH="$ROOT/$SYNC_STATE_DIR"
EXCLUDE="$ROOT/.git/info/exclude"

# 作废盘上的旧凭证：下面的分支守卫、拉取、镜像检查任意一条失败都会直接 exit，若等到最后
# 才写 plan.json，这些路径失败时盘上留下的就是上一次那份**看起来已被批准**的凭证
# （plan_id 非空、refused=false），而这一轮的运行其实什么都没产出——审批链上最危险的一格。
# 所以这里在第一个可能 exit 的守卫之前，就把文件改写成"本次运行没有产出任何计划"。
# 能走到最后的运行会用完整内容覆盖它；因此"盘上永远代表最新一次运行"这一点也仍然成立。
invalidate_plan_artifact() {
  local ts branch_now
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  branch_now="$(sync_branch 2>/dev/null || true)"
  {
    printf '{\n'
    printf '  "plan_id": "",\n'
    printf '  "created_at": "%s",\n' "$ts"
    printf '  "branch": "%s",\n' "$branch_now"
    printf '  "mirror_sha": "",\n'
    printf '  "local_sha": "",\n'
    printf '  "upstream_new_commits": 0,\n'
    printf '  "upstream_version": "",\n'
    printf '  "conflicts": "",\n'
    printf '  "untracked_skills": "",\n'
    printf '  "note": "本次运行未走到计划产出（分支守卫/拉取/镜像检查失败即退出），此文件仅用于作废上一次的凭证",\n'
    printf '  "invariants_ok": false,\n'
    printf '  "scan_ok": false,\n'
    printf '  "refused": true\n'
    printf '}\n'
  } > "$STATE_PATH/plan.json"
}

mkdir -p "$STATE_PATH"
# 排除放这里（而不是只在最后）是必需的：下面的作废写入会让 .sync/ 出现在 status 里，
# 若此刻还没排除，同一仓库状态在同一轮里就会算出不同的哈希。
# best-effort：linked worktree 里 .git 是文件，这一行写不进去；那不是目标工作流，
# 不该在这里变成一个新的硬失败（最后的严格版本照旧保留）。2>/dev/null：/… 路径不存在时不刷屏。
grep -qxF "$SYNC_STATE_DIR/" "$EXCLUDE" 2>/dev/null \
  || printf '%s/\n' "$SYNC_STATE_DIR" >> "$EXCLUDE" 2>/dev/null || true
invalidate_plan_artifact

# I1 分支守卫：放在子壳里调用。库里的 sync_require_local_branch 走 sync_die（exit 1，那是库
# 对"运行错误"的定义），而本脚本的契约规定"不在 local 上"属于不变量违规，必须是 2。
# 子壳让同步库继续做这条判断与消息的唯一出处，外层只把它的退出码翻译成本脚本的语义。
( sync_require_local_branch ) || exit 2

if [ "$FETCH" = "1" ]; then
  # 有界拉取：远端不可达时必须"失败退出"并给出可读错误，绝不允许无限期挂住。
  # 关掉交互式凭据提示，并给 http 传输设低速阈值与超时。
  ( export GIT_TERMINAL_PROMPT=0
    sync_git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
      fetch "$SYNC_UPSTREAM_REMOTE" "$SYNC_MIRROR_BRANCH:$SYNC_MIRROR_BRANCH" ) \
    || sync_die "拉取 upstream 失败：网络不可达，或 upstream 强推过历史需要人工处置（已设有界超时，不会无限等待）"
fi

# 镜像引用缺失时给出可读错误（不要让它退化成后续步骤的晦涩失败）
sync_ref_exists "$SYNC_MIRROR_BRANCH" || sync_die "缺少本地镜像分支 ${SYNC_MIRROR_BRANCH}：先按一次性收敛步骤建立它"

# 待合入提交数：先收完整输出，再判 producer 的退出码，最后才计数。
# 旧写法 `sync_git log … 2>/dev/null | wc -l | tr -d ' '` 把 git 的失败降级成一条**另外的**
# 结果：管道里 wc/tr 恒成功，pipefail 把 git 的退出码冒到赋值语句上，set -e 当场中止——用户
# 只看到一个数字，没有任何"读不到"的消息；换个 shell 选项（或将来有人补一个 `|| true`）它就
# 直接变成 0，而 0 会写进报告的"待合入提交数"与 plan.json 的 upstream_new_commits，人会照着
# 一个少报的计划去审批。这里与文件里其余读操作一致：读不到就报错退出。
NEW_LOG="$(sync_git log --oneline "$SYNC_LOCAL_BRANCH..$SYNC_MIRROR_BRANCH")" \
  || sync_die "无法枚举待合入提交（git log 失败），拒绝出一份数字不可信的计划"
NEW_COMMITS="$(awk 'NF { c += 1 } END { print c + 0 }' <<<"$NEW_LOG")"
CHANGED_SKILLS="$(sync_git diff --name-only "$SYNC_LOCAL_BRANCH...$SYNC_MIRROR_BRANCH" -- skills/ 2>/dev/null \
  | awk -F/ 'NF>1 { print $2 }' | LC_ALL=C sort -u | tr '\n' ' ')"
# 末尾 || true 是功能必需：镜像里没有 package.json 时 git show 退出 128，set -o pipefail 会把
# 整条管道判为失败并触发 set -e，plan 直接以 128 退出——而版本号只是报告里的一行，读不到它
# 应当是"未知"，不该让整份计划失败（测试夹具里正是没有 package.json）。
# 同理它兜住 head -1 提前关闭管道时 sed 收到 SIGPIPE（141）的情形。
VERSION="$(sync_git show "$SYNC_MIRROR_BRANCH:package.json" 2>/dev/null | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -1 || true)"
UNTRACKED="$(sync_untracked_skills)"
CONFLICTS="$(sync_conflict_preflight)"
VIOLATIONS="$(sync_non_added_paths)"

SCAN_OUT=""
SCAN_RC=0
# F4：G1 的范围扫描成本与范围线性同阶（本仓库实测约 37ms/blob、整段范围约 10s；长期分叉的
# 首次推送/首次 plan 是分钟级）。扫描器的进度行会被下面这行捕获（它的输出要原样带进拒绝消息），
# 捕获之后 stderr 不流到终端，故这里自己打一行，免得慢扫描被读成"卡死了"。
printf '开始扫描范围 %s...%s（逐个读该范围新引入的 blob，耗时随范围线性增长，可能是数秒到数分钟）。\n' \
  "$SYNC_MIRROR_BRANCH" "$SYNC_LOCAL_BRANCH" >&2
SCAN_T0="$SECONDS"
SCAN_OUT="$("$SCAN" --range "$SYNC_MIRROR_BRANCH...$SYNC_LOCAL_BRANCH" 2>&1)" || SCAN_RC=$?
printf '范围扫描完成：用时 %s 秒。\n' "$((SECONDS - SCAN_T0))" >&2

# 可审批性：I2 违规或 G1 未通过都不审批。先判定，因为报告与 plan.json 都要如实写出这件事。
REFUSED=0
SCAN_OK=1
if [ -n "$VIOLATIONS" ]; then
  REFUSED=1
fi
if [ "$SCAN_RC" != "0" ]; then
  REFUSED=1
  SCAN_OK=0
fi

# 扫描状态文案必须区分 1 与 2：1 是"命中"，2 是"扫描器不可用（规则表读不到/用法错误）"。
# 把 2 也印成"命中"会让人照着一套对这种情况无效的补救指引去处理，等于误报。
case "$SCAN_RC" in
  0) SCAN_LABEL='通过' ;;
  1) SCAN_LABEL='命中，已阻断' ;;
  *) SCAN_LABEL='扫描器不可用（规则表或用法错误），已阻断' ;;
esac

# .sync/ 是本地状态目录：通过 .git/info/exclude 排除（不改 .gitignore —— 那会破坏 I2）。
# 开头已经排除过一次（那里是 best-effort），这里保留严格版本：走到这一步正常运行必须排除成功，
# 否则下面的哈希会把 .sync/plan.json 本身算进去。
if ! grep -qxF "$SYNC_STATE_DIR/" "$EXCLUDE" 2>/dev/null; then
  printf '%s/\n' "$SYNC_STATE_DIR" >> "$EXCLUDE"
fi

# 凭证哈希只算一次，plan.json 与打印的 PLAN_ID 共用它。两次调用会各自重扫一遍 range
# 并各跑一次 merge-tree；一旦两次结果不同，落盘的 plan_id 就与人类实际批准的凭证不是同一个值，
# 而这种不一致是静默的——审批链最不该有的东西。
# 这一次内部扫描的进度行由 sync_state_hash 丢弃（它只把扫描器的 stdout 计入哈希，stderr 一律
# 2>/dev/null），故这里另打一行：不然"第二次扫同一个范围"的等待是完全静默的（F4）。
printf '计算状态哈希（会再扫一遍同一个范围并跑一次 merge-tree，可能耗时数秒到数分钟）…\n' >&2
HASH_T0="$SECONDS"
HASH="$(sync_state_hash)"
printf '状态哈希完成：用时 %s 秒。\n' "$((SECONDS - HASH_T0))" >&2
PLAN_ID_OUT=""
if [ "$REFUSED" = "0" ]; then
  PLAN_ID_OUT="$HASH"
fi

printf '=== upstream-sync 计划 ===\n'
printf '分支           : %s\n' "$(sync_branch)"
printf '镜像 %-10s: %s\n' "$SYNC_MIRROR_BRANCH" "$(sync_git rev-parse "$SYNC_MIRROR_BRANCH")"
printf '工作 local     : %s\n' "$(sync_git rev-parse "$SYNC_LOCAL_BRANCH")"
printf '上游版本       : %s\n' "${VERSION:-未知}"
printf '待合入提交数   : %s\n' "$NEW_COMMITS"
printf '受影响技能     : %s\n' "${CHANGED_SKILLS:-（无）}"
printf '游离技能       : %s\n' "$(printf '%s' "$UNTRACKED" | tr '\n' ' ')"
printf '冲突预演       : %s\n' "${CONFLICTS:-无冲突}"
printf 'I2 违规        : %s\n' "${VIOLATIONS:-无}"
printf '敏感信息扫描   : %s\n' "$SCAN_LABEL"
if [ -n "$(sync_status_porcelain)" ]; then
  printf '工作区         : 不干净\n'
else
  printf '工作区         : 干净\n'
fi

# plan.json 每次运行都重写（只写"通过"的那次会让上一轮的旧 plan_id 留在盘上，比这更糟），
# 但被拒绝的那次必须诚实：plan_id 留空（它不是一个可用的凭证），并显式写下 refused/scan_ok。
# invariants_ok 仍然只表示 I2；G1 的结果看 scan_ok。
{
  printf '{\n'
  printf '  "plan_id": "%s",\n' "$PLAN_ID_OUT"
  printf '  "created_at": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '  "branch": "%s",\n' "$(sync_branch)"
  printf '  "mirror_sha": "%s",\n' "$(sync_git rev-parse "$SYNC_MIRROR_BRANCH")"
  printf '  "local_sha": "%s",\n' "$(sync_git rev-parse "$SYNC_LOCAL_BRANCH")"
  printf '  "upstream_new_commits": %s,\n' "$NEW_COMMITS"
  printf '  "upstream_version": "%s",\n' "${VERSION:-未知}"
  # 与 untracked_skills 同样地把换行折成逗号：JSON 字符串字面量里不能出现裸换行，
  # 有两条以上冲突时原样输出会让 plan.json 变成非法 JSON（解析方直接报错），
  # 而这份文件正是给人看、给 apply 对账的结构化证据。
  printf '  "conflicts": "%s",\n' "$(printf '%s' "$CONFLICTS" | tr '\n' ',')"
  printf '  "untracked_skills": "%s",\n' "$(printf '%s' "$UNTRACKED" | tr '\n' ',')"
  printf '  "invariants_ok": %s,\n' "$([ -z "$VIOLATIONS" ] && printf 'true' || printf 'false')"
  printf '  "scan_ok": %s,\n' "$([ "$SCAN_OK" = "1" ] && printf 'true' || printf 'false')"
  printf '  "refused": %s\n' "$([ "$REFUSED" = "0" ] && printf 'false' || printf 'true')"
  printf '}\n'
} > "$STATE_PATH/plan.json"

if [ -n "$VIOLATIONS" ]; then
  printf '\nREFUSED：以下路径不是纯新增，需人工决策：\n%s\n' "$VIOLATIONS" >&2
  exit 2
fi
if [ "$SCAN_RC" != "0" ]; then
  printf '\n%s\n' "$SCAN_OUT" >&2
  exit 2
fi

printf '\nPLAN_ID=%s\n' "$PLAN_ID_OUT"
