#!/usr/bin/env bash
# 落地：审批门 → 冲突预演 → 干净检查 → merge → adopt → 自检 → 暂存区复检 → 采纳提交 →
#       推送范围与身份报告 → G3 复检 → .sync/ 守卫 → push
# （顺序即代码顺序：采纳提交在身份报告之前，故"将要推送的提交"里也包含它。）
#
# 退出码（唯一的映射表，plan.sh 与本脚本共用同一套语义）：
#   0 成功（含"无需变更"）
#   1 运行错误：git/IO 失败之类——**只**用于这一类
#   2 用法错误、分支错误（不在 local 上），或调用方数据/计划期本应检出的问题
#     （游离技能缺 SKILL.md、frontmatter 与目录不同名、缺 description、含嵌套 SKILL.md）
#   3 PLAN_ID 与当前状态不符（计划已过期）
#   4 工作区不干净
#   5 安全闸门：敏感信息命中、扫描器不可用，或本地状态（.sync/）/推送目的地不安全
#   6 仓库自检失败
#   7 合入预演存在冲突
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$HERE/sync-lib.sh"

# upstream 的**推送** URL 必须是这个禁用标记：本机制绝不向上游推送（成对不变量之一）。
# 与 tests/upstream-sync/lib-assert.sh 的夹具、以及真实仓库的现状一致。
SYNC_UPSTREAM_DISABLED_PUSH_URL="DISABLED-no-push"

usage() { printf '用法: apply.sh --plan-id <hash> [--adopt] [--no-push]\n' >&2; exit 2; }
# 调用方数据/用法类拒绝 → 2（与运行错误 1 分开，见文件头的映射表）
refuse_caller() { printf 'REFUSED：%s\n' "$*" >&2; exit 2; }
# 运行错误类拒绝（git/IO 读不出来）→ 1。所有"读不到就拒绝"的地方一律走这里，
# 绝不用 `|| true` 把失败降级成空串——空串在比较里永远"不等于"，等于静默放行。
refuse_runtime() { printf 'REFUSED：%s，未推送。\n%s\n' "$*" "$REPLAN_NOTE" >&2; exit 1; }

PLAN_ID=""
ADOPT=0
PUSH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --plan-id)
      # 缺值必须先判再 shift：`shift 2` 在 $#=1 时返回非 0，set -e 会当场以 exit 1 **静默**中止，
      # 连下面那句"缺少 --plan-id"都到不了。命令行写错属用法错误，按映射表必须是 2。
      [ $# -ge 2 ] || usage
      # 取值形如选项（如 `--plan-id --adopt`）是明显的命令行笔误。不拦的话 "--adopt" 会被当成
      # 凭证去比对，报"计划已过期"（3）——把"参数写错了"说成"上游变了"，会把人指去重新审阅。
      case "$2" in -*) usage ;; esac
      PLAN_ID="$2"; shift 2 ;;
    --adopt)   ADOPT=1; shift ;;
    --no-push) PUSH=0; shift ;;
    *) usage ;;
  esac
done
[ -n "$PLAN_ID" ] || { printf '缺少 --plan-id\n' >&2; exit 2; }

# 文本里有没有匹配给定 ERE 的行。
# 绝不能用 `producer | grep -q`：grep -q 命中即退出，producer 收到 SIGPIPE 而死，pipefail
# 把 141 冒到 if 条件上，于是"命中"被读成"没命中"——守卫恰好在输入很长时失效（实测
# `set -euo pipefail; yes | grep -q y` 判为"没命中"），而"推送范围很长"正是这些守卫存在的场景。
# 这里没有管道：输入是 here-string，判定方 awk 会读完整个输入再在 END 里定退出码。
text_matches() { # ere text
  awk -v re="$1" '$0 ~ re { hit = 1 } END { exit(hit ? 0 : 1) }' <<<"${2:-}"
}
# 判"文本里有没有以 $SYNC_STATE_DIR/ 开头的行"。
# 用 awk 的 index() 做**字面前缀**匹配，而不是拼正则：既不被正则元字符绊到
#（SYNC_STATE_DIR 里的 . 在正则里会退化成"任意字符"，`.xsync/` 这种路径就会被误伤），
# 也保证这里的路径来源与消息、跟踪集检查用的是同一个常量——常量改了不会分家。
has_dot_sync_path() { # text
  awk -v p="$SYNC_STATE_DIR/" 'index($0, p) == 1 { hit = 1 } END { exit(hit ? 0 : 1) }' <<<"${1:-}"
}

# 待推送的提交条数（stdout 只有数字）。`--not --remotes=origin` 与推送的用途一致：远端还没有
# local 时，它给出的就是"首次推送"要发的全部提交。
# 枚举失败必须**失败关闭**（调用方一律 `|| refuse_runtime …`）：把"读不到"当成"没有东西要推"，
# 与早退那条要堵的静默丢弃是同一件事，只是方向相反。
# 这个函数有**两个**调用点，且两处都必须各自算一次：
#   - 早退判定在采纳提交之前（那时 CHANGED 已定，HEAD 却可能还要因采纳而前进）；
#   - 推送范围与推送前闸门在采纳提交**之后**重算（用早退处那次快照会让刚采纳的内容落在
#     范围与闸门之外，G3、身份报告、.sync/ 守卫会被整段跳过）。
count_outgoing() {
  sync_git log --oneline "$SYNC_LOCAL_BRANCH" --not --remotes="$SYNC_ORIGIN_REMOTE" \
    | awk 'NF { c += 1 } END { print c + 0 }'
}

# 远端 URL 归一化，用于判断"origin 与 upstream 是不是同一个仓库"。
# 本地形态必须按物理路径比：file:///x/y、/x/y、/private/var/… 与 /var/… 都可能指向同一个裸库，
# 只做字符串比较会漏判——而漏判的后果是把整个分叉（含 .sync/ 历史）推进上游，不可逆。
normalize_remote() { # url
  local u d
  u="$1"
  case "$u" in
    file://*) u="${u#file://}" ;;
  esac
  case "$u" in
    /*)
      d="$(cd "$(dirname "$u")" 2>/dev/null && pwd -P)" || d=""
      if [ -n "$d" ]; then
        printf '%s/%s\n' "$d" "$(basename "$u")"
      else
        printf '%s\n' "$u"
      fi
      ;;
    *) printf '%s\n' "$u" ;;
  esac
}

ROOT="$(sync_repo_root)"
SCAN="$HERE/scan-sensitive.sh"
SELFTEST="${SYNC_SELFTEST_CMD:-node tests/opencode/test-skill-registration.mjs .opencode/plugins/superpowers.js}"

# 走到这一步之后，merge/采纳可能已经在 local 上产生了新提交：本地状态与人类批准时的凭证不再
# 一致，修完必须重新 plan。所有"变更之后才可能拒绝"的消息都要带上这句话（B4）。
REPLAN_NOTE='注意：此时本地可能已产生新提交（merge/采纳），本地状态已与批准时的凭证不同——请在修复后重新运行 plan 取新凭证，再执行 apply。'

# 分支不是 local 是 I1 不变量，与 plan.sh 同一条判断。子壳让同步库继续做这条判断与消息的
# 唯一出处，外层只把它的退出码翻译成本脚本的语义（映射表：2 = 用法/不变量/调用方数据）。
( sync_require_local_branch ) || exit 2

CURRENT="$(sync_state_hash)"
if [ "$CURRENT" != "$PLAN_ID" ]; then
  printf 'REFUSED：计划已过期。\n  计划: %s\n  当前: %s\n请重新运行 plan 并重新审阅。\n' "$PLAN_ID" "$CURRENT" >&2
  exit 3
fi

CONFLICTS="$(sync_conflict_preflight)"
if [ -n "$CONFLICTS" ]; then
  printf 'REFUSED：合入预演存在冲突：\n%s\n按纯新增约定，冲突只可能来自同名技能——请为你的技能改名后重新 plan。\n' "$CONFLICTS" >&2
  exit 7
fi

# 先取整份 porcelain，再在内存里过滤。不能写成 `sync_status_porcelain | grep -v … || true`：
# 那个 `|| true` 本意是吞掉 grep"无匹配"的 1，却会连 producer 自身失败（git status 报错）一起
# 吞掉，于是 DIRTY 退化成空、脏工作区被静默放行（fail-open）。分开写，两种情况才可分辨。
PORC="$(sync_status_porcelain)" \
  || { printf 'REFUSED：无法读取工作区状态（git status 失败），出于安全拒绝继续。\n' >&2; exit 1; }
DIRTY="$(awk 'NF && $0 !~ /^\?\? skills\//' <<<"$PORC")"
if [ -n "$DIRTY" ]; then
  printf 'REFUSED：工作区不干净（不 stash、不覆盖你的改动）：\n%s\n' "$DIRTY" >&2
  exit 4
fi

# .sync/ 永不入库、永不推送：白名单就在里面，扫描器的内容规则按定义抓不到 allowlist.txt
# 这种路径。这里查的是**跟踪集**，并且放在 merge/commit **之前**：
#   - 查暂存区（git diff --cached）在这里必然为空——它上面的 commit 已经消费掉索引，
#     那样的守卫永远不会触发，是死代码而不是纵深防御；真正的风险是 .sync/ 被**误提交**过。
#   - 放在任何变更之前，拒绝时本地不留任何痕迹，人类不需要重新 plan。
# 历史里已经删掉的 .sync/ 路径由后面的"推送范围"守卫负责（推送仍会带出那段历史）。
TRACKED_SYNC="$(sync_git ls-files -- "$SYNC_STATE_DIR/")" \
  || sync_die "无法枚举 ${SYNC_STATE_DIR}/ 下的已跟踪路径"
if [ -n "$TRACKED_SYNC" ]; then
  printf 'REFUSED：%s/ 下有已跟踪文件（本地状态目录不得入库、不得推送）：\n%s\n先把它从版本库移除（git rm -r --cached %s）再重新 plan。\n' \
    "$SYNC_STATE_DIR" "$TRACKED_SYNC" "$SYNC_STATE_DIR" >&2
  exit 5
fi

CHANGED=0

# 先 merge 再 adopt：避免"暂存内容 + 合并"这一组合，语义更清晰。
# 合入前的提交数比较必须**显式失败关闭**。旧写法 `[ "$(sync_git rev-list --count …)" != "0" ]`
# 在 git 读不出来时拿到空串，而空串永远"不等于 0"——于是"读不到"被读成"有东西要合入"，紧接着
# `git merge --no-ff` 会凭空造一个合并提交。方向与"静默放行"相反，但同属把失败降级成猜测。
# 此处尚未做任何改动，故拒绝时本地零痕迹、不需要重新 plan（与下面 REPLAN_NOTE 的场景不同）。
MIRROR_AHEAD="$(sync_git rev-list --count "$SYNC_LOCAL_BRANCH..$SYNC_MIRROR_BRANCH")" \
  || { printf 'REFUSED：无法读取待合入提交数（git rev-list 失败），出于安全拒绝继续，未做任何改动。\n' >&2; exit 1; }
case "$MIRROR_AHEAD" in
  ''|*[!0-9]*)
    printf 'REFUSED：待合入提交数读出来不是数字（%s），出于安全拒绝继续，未做任何改动。\n' "$MIRROR_AHEAD" >&2
    exit 1 ;;
esac
if [ "$MIRROR_AHEAD" != "0" ]; then
  sync_git merge --no-ff "$SYNC_MIRROR_BRANCH" -m "merge: 合入 upstream $SYNC_MIRROR_BRANCH ($(sync_git rev-parse --short "$SYNC_MIRROR_BRANCH"))"
  printf 'merge: 已合入 %s\n' "$(sync_git rev-parse --short "$SYNC_MIRROR_BRANCH")"
  CHANGED=1
fi

if [ "$ADOPT" = "1" ]; then
  # 先收进变量再迭代：`for name in $(sync_untracked_skills)` 会把 producer 失败读成"没有游离技能"
  #（git ls-files 挂掉 → 输出为空 → 一个不采纳、apply 却照样报成功）。分词本身按裁定仍 deferred，
  # 这里只堵住"失败被吞掉"这一半。
  UNTRACKED_SKILLS="$(sync_untracked_skills)" \
    || refuse_runtime "无法枚举游离技能（git ls-files 失败）"
  for name in $UNTRACKED_SKILLS; do
    dir="skills/$name"
    # 文件系统读取必须用 "$ROOT/$dir"：dir 是"仓库相对"路径，而调用者的 cwd 未必是仓库根
    #（测试从别处调用 apply；人也可能在自己的目录里调用）。git 侧由 sync_git 的 -C 兜住，
    # 但 [ -f ] / sed / find 这些裸调用只认 cwd——直接读相对路径会在正常 adopt 时报
    # "游离技能 X 缺少 SKILL.md" 并以非 0 退出，把一次该成功的落地变成失败。
    # pathspec 仍用仓库相对的 "$dir"：git -C <root> 按仓库根解析它。
    skill_md="$ROOT/$dir/SKILL.md"
    # 这些校验失败都是"计划期本应检出"的调用方数据问题 → 2（见文件头的映射表）
    [ -f "$skill_md" ] || refuse_caller "游离技能 ${name} 缺少 SKILL.md"
    # `|| true`：head -1 读够一行即退出，sed 若还有匹配行要写会收到 SIGPIPE，pipefail 把这个
    # 141 冒到赋值语句上，set -e 就会中止一次本该成功的采纳（plan.sh 对同一形状已有此写法）。
    fm_name="$(sed -n 's/^name: *//p' "$skill_md" | head -1 || true)"
    fm_desc="$(sed -n 's/^description: *//p' "$skill_md" | head -1 || true)"
    [ "$fm_name" = "$name" ] || refuse_caller "游离技能 ${name} 的 frontmatter name 为 '${fm_name}'，必须与目录同名"
    [ -n "$fm_desc" ] || refuse_caller "游离技能 ${name} 缺少 description"
    # find 同样先收进变量再判：find 在管道里被 grep -q 提前掐断会因 SIGPIPE 变成"没找到"，
    # 于是嵌套技能被静默采纳（与推送范围守卫同一类失效）。
    NESTED="$(find "$ROOT/$dir" -mindepth 2 -name SKILL.md)"
    [ -z "$NESTED" ] || refuse_caller "游离技能 ${name} 含嵌套 SKILL.md（DSH 不支持嵌套发现）：${NESTED}"
    sync_git add "$dir"
    printf 'adopt: %s\n' "$dir"
    CHANGED=1
  done
fi

# 早退必须同时看两件事：有没有事要做（CHANGED），以及有没有东西要推（OUTGOING_PENDING）。
# 只看 CHANGED 会把最普通的一条用户路径静默丢掉：自己把改动提交进 local、upstream 恰好没有
# 新提交、又没有游离技能 —— apply 打印"无需变更"、退出 0，本地提交永远出不了门（"把本地新增
# 同步进代码库"这个要求本身就被绕过去了）。此时必须继续往下走：推送范围、身份报告、G3 扫描、
# .sync/ 与推送目的地守卫全都在下面，位置一律不变。
# 这一次计数是**判定用**的快照，不是推送用的那一次（见下面 OUTGOING 处的注释）。
OUTGOING_PENDING="$(count_outgoing)" \
  || refuse_runtime "无法枚举待推送的提交（git log 失败）"
if [ "$CHANGED" = "0" ] && [ "$OUTGOING_PENDING" = "0" ]; then
  printf '无需变更：upstream 无新提交，没有待 adopt 的游离技能，也没有待推送的提交。\n'
  exit 0
fi

# 自检命令的构造放在**自检这一步**。graphviz 依赖的测试按环境条件纳入：本机未安装 dot，
# 该测试**必然** exit 1，若无条件纳入会让 apply 永远以 exit 6 拒绝推送。
# 跳过时必须响亮提示，绝不静默（R3）；提示走 stderr，且不能提前到审批门之前打印——
# 那样在 exit 3/4/7 的运行里也会出现，读起来像"apply 已经往下走了"。
if [ -z "${SYNC_SELFTEST_CMD:-}" ]; then
  if command -v dot >/dev/null 2>&1; then
    SELFTEST="bash tests/writing-skills/test-render-graphs.sh && $SELFTEST"
  else
    printf '注意：未检测到 graphviz(dot)，跳过 tests/writing-skills/test-render-graphs.sh（该测试在本机必然失败，属环境缺失而非代码缺陷）。\n' >&2
  fi
fi

# 可选闸门：仅在 ShellCheck 可用且本次确有 shell 改动时才追加（本机未安装 ShellCheck）
if [ -z "${SYNC_SELFTEST_CMD:-}" ] && command -v shellcheck >/dev/null 2>&1; then
  # 先收进变量再做匹配：`git diff | grep -q …` 在改动很多时会被 SIGPIPE 掐断而判成"没有 shell 改动"。
  CHANGED_PATHS="$(sync_git diff --name-only "$SYNC_MIRROR_BRANCH...$SYNC_LOCAL_BRANCH")" \
    || sync_die "无法枚举本次变更的路径"
  if text_matches '[.]sh$' "$CHANGED_PATHS"; then
    SELFTEST="$SELFTEST && bash scripts/lint-shell.sh"
    printf '自检：追加 scripts/lint-shell.sh（检测到 shell 改动且 ShellCheck 可用）\n'
  fi
fi

# 自检失败时的"运行时可见性"必须**按事实说**，不能无条件宣称符号链接。一次性收敛 M6 还没执行
# 的机器上，运行时技能根就是一个普通目录，此时说"新内容已在运行时可见"是假话 —— 而这条路径
# 恰恰会被"手工提交 + 自检失败"的发布走到（N1 之后更是如此）。
# 判定要做到底：不只是"是不是符号链接"，而是它**解析后是否等于本仓库的 skills/**；指向别处的
# 符号链接一样不代表新内容可见。SYNC_RUNTIME_SKILLS_ROOT 是给测试用的注入点（与 SYNC_REPO_ROOT、
# SYNC_SELFTEST_CMD 同一套路），免得断言随开发机 ~/.dsh/skills 的实际状态漂移。
runtime_skills_root() { printf '%s\n' "${SYNC_RUNTIME_SKILLS_ROOT:-${HOME:-}/.dsh/skills}"; }
runtime_note() {
  local rt target resolved
  rt="$(runtime_skills_root)"
  if [ -L "$rt" ]; then
    target="$(readlink "$rt")" 2>/dev/null || target=""
    case "$target" in
      "") resolved="" ;;
      /*) resolved="$target" ;;
      *)  resolved="$(dirname "$rt")/$target" ;;
    esac
    # 解析目标的物理路径；目标不存在时 cd 失败 → 空串 → 走"尚未生效"那一支（fail conservative）。
    resolved="$(cd "$resolved" 2>/dev/null && pwd -P)" || resolved=""
    if [ -n "$resolved" ] && [ "$resolved" = "$ROOT/skills" ]; then
      printf '注意：运行时技能根 %s 是指向本仓库 skills/ 的符号链接，新内容此刻已在运行时可见。\n' "$rt"
      return 0
    fi
  fi
  printf '注意：运行时技能根 %s 还不是指向本仓库 skills/ 的符号链接 —— 新内容只在工作区与本地提交里，运行时尚未生效。\n' "$rt"
}

( cd "$ROOT" && eval "$SELFTEST" ) || {
  printf 'REFUSED：仓库自检失败，未推送。\n' >&2
  runtime_note >&2
  printf '%s\n' "$REPLAN_NOTE" >&2
  exit 6
}

# 复检的文案分三态，与 plan.sh 一致：1 是"命中"，其他（2）是"扫描器不可用（规则表/用法错误）"。
# 把 2 也印成"命中"会让人照着一套对这种情况无效的补救指引去改内容——等于误报。
STAGED_RC=0
STAGED="$("$SCAN" --staged 2>&1)" || STAGED_RC=$?
if [ "$STAGED_RC" != "0" ]; then
  case "$STAGED_RC" in
    1) printf 'REFUSED：暂存内容敏感信息复检命中，已阻断。\n' >&2 ;;
    *) printf 'REFUSED：暂存内容敏感信息复检无法完成（扫描器不可用：规则表或用法错误），已阻断。\n' >&2 ;;
  esac
  printf '%s\n%s\n' "$STAGED" "$REPLAN_NOTE" >&2
  exit 5
fi

# 暂存区状态要判 producer 的退出码：`[ -n "$(git diff --cached …)" ]` 会把**失败**读成
# "没有暂存内容"，于是采纳提交被静默跳过、apply 却仍然报成功（同一类 fail-open）。
STAGED_NOW="$(sync_git diff --cached --name-only)" \
  || refuse_runtime "无法读取暂存区状态（git diff 失败）"
if [ -n "$STAGED_NOW" ]; then
  sync_git commit -m "sync: 采纳本地新增技能"
fi

# 推送前的**权威**计数：必须在采纳提交**之后**重算。用早退处那次快照会让刚刚采纳的内容落在
# 推送范围与推送前闸门之外——G3、身份报告、.sync/ 守卫会被整段跳过，那正是"先假干净再推上去"
# 的形状（采纳提交本身也可能就是首次要推出去的提交）。
# 显式判失败：原来 `… | wc -l` 在 2>/dev/null 下失败时，pipefail + set -e 会带着 git 的原始
# 退出码静默中止（没有任何可读消息）；这里把它变成一条能读懂的运行错误。
OUTGOING="$(count_outgoing)" \
  || refuse_runtime "无法枚举待推送的提交（git log 失败）"
PUSH_RANGE=""

# A2 / C1 / D1 / D2：推送目的地安全检查。**它不挂在 `OUTGOING != 0` 那一段里**——它校验的是
# 配置不变量（远端配成什么样），不是"这次有没有东西要推"，也与 --no-push 无关。旧形状把它塞在
# 那个条件里，只在 `git push` 恰好也在这个条件下时才是等价的；而下面的 `git push` 是**无条件**
# 执行的（只被 --no-push 拦着），一次重构就会让真的在推送的那条路少跑一道守卫。配置读取不过
# 几次 fork，没有理由让它依附于一个与它无关的计数。
# 三件必须做对的事：
#   1) 读 URL 失败一律**失败关闭**。旧写法 `… 2>/dev/null || true` 把它降级成空串，而空串
#      永远"不等于"任何非空 URL，于是"同源"检查静默放行——正是这条守卫要防的事。
#      读不到远端是 git/IO 运行错误 → 1。
#   2) 必须用 `--all` 读**全部** URL：`git push origin local` 会把每一个 pushurl 都推一遍，
#      而不带 --all 的 `get-url --push` 只打印第一个。配成 [自己的 fork, upstream] 时，
#      只读第一个就放行了一次实际发往 upstream 的推送（实测：两个仓库里都建出了 local 分支）。
#   3) 先判 upstream 的哨兵不变量，再拿 origin 的 URL 比 upstream 的 **fetch** URL：
#      origin 的推送 URL 恰好奇妙地等于哨兵时，先比 upstream 的推送 URL 会报出
#      "推送 URL 指向 upstream"这种与事实不符的理由，还会抢掉更准确的哨兵消息；
#      哨兵确认之后，upstream 的推送 URL 已不是仓库地址，再拿它比只会误导。
ORIGIN_FETCH_URLS="$(sync_git remote get-url --all "$SYNC_ORIGIN_REMOTE" 2>/dev/null)" \
  || refuse_runtime "读不到远端 ${SYNC_ORIGIN_REMOTE} 的 fetch URL，出于安全拒绝推送"
ORIGIN_PUSH_URLS="$(sync_git remote get-url --all --push "$SYNC_ORIGIN_REMOTE" 2>/dev/null)" \
  || refuse_runtime "读不到远端 ${SYNC_ORIGIN_REMOTE} 的 push URL，出于安全拒绝推送"
UPSTREAM_FETCH_URLS="$(sync_git remote get-url --all "$SYNC_UPSTREAM_REMOTE" 2>/dev/null)" \
  || refuse_runtime "读不到远端 ${SYNC_UPSTREAM_REMOTE} 的 fetch URL，出于安全拒绝推送"
UPSTREAM_PUSH_URLS="$(sync_git remote get-url --all --push "$SYNC_UPSTREAM_REMOTE" 2>/dev/null)" \
  || refuse_runtime "读不到远端 ${SYNC_UPSTREAM_REMOTE} 的 push URL，出于安全拒绝推送"

# (3a) 成对不变量：upstream 的**每一个**推送 URL 都必须是禁用标记
while IFS= read -r u; do
  [ -n "$u" ] || continue
  if [ "$u" != "$SYNC_UPSTREAM_DISABLED_PUSH_URL" ]; then
    printf 'REFUSED：%s 的推送 URL 为「%s」，不是禁用标记「%s」——本机制绝不向上游推送。\n%s\n' \
      "$SYNC_UPSTREAM_REMOTE" "$u" "$SYNC_UPSTREAM_DISABLED_PUSH_URL" "$REPLAN_NOTE" >&2
    exit 5
  fi
done <<UPSTREAM_PUSH_URLS_EOF
$UPSTREAM_PUSH_URLS
UPSTREAM_PUSH_URLS_EOF

# (3b) origin 的**每一个** URL（fetch 与 push，且 push 可能是多条）都不得等于 upstream 的
#      fetch URL——也就是不得等于上游本尊。
ORIGIN_ALL_URLS="$ORIGIN_FETCH_URLS
$ORIGIN_PUSH_URLS"
while IFS= read -r o; do
  [ -n "$o" ] || continue
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    if [ "$(normalize_remote "$o")" = "$(normalize_remote "$u")" ]; then
      printf 'REFUSED：%s 的 URL（%s）指向 %s——推送会把整个分叉发布到上游，不可逆。\n%s\n' \
        "$SYNC_ORIGIN_REMOTE" "$o" "$SYNC_UPSTREAM_REMOTE" "$REPLAN_NOTE" >&2
      exit 5
    fi
  done <<UPSTREAM_FETCH_URLS_EOF
$UPSTREAM_FETCH_URLS
UPSTREAM_FETCH_URLS_EOF
done <<ORIGIN_ALL_URLS_EOF
$ORIGIN_ALL_URLS
ORIGIN_ALL_URLS_EOF

# 下面这一段的每一件都**只对"这批推送范围"有意义**（范围为空时它什么都没有可查），故仍然
# 只在确有东西要推时跑；推送目的地那一段已经在上面跑完了，不会再被这个条件跳过。
if [ "$OUTGOING" != "0" ]; then
  if sync_ref_exists "refs/remotes/$SYNC_ORIGIN_REMOTE/$SYNC_LOCAL_BRANCH"; then
    PUSH_RANGE="$SYNC_ORIGIN_REMOTE/$SYNC_LOCAL_BRANCH..$SYNC_LOCAL_BRANCH"
  else
    PUSH_RANGE="$SYNC_MIRROR_BRANCH..$SYNC_LOCAL_BRANCH"
  fi

  # 提交身份是元数据，内容扫描器抓不到 —— 必须在此显式报告
  printf '将推送的提交身份：\n'
  sync_git log --format='  %h  %an <%ae>' "$PUSH_RANGE" \
    || refuse_runtime "无法读取待推送提交的身份（git log 失败），出于安全拒绝推送"
  printf '预期身份：取自全局 git 配置；若上面出现非预期身份，请停止并检查。\n'

  # F4：G3 的范围扫描成本与范围线性同阶（本仓库实测约 37ms/blob、整段范围约 10s；长期分叉的
  # 首次推送是分钟级）。扫描器的进度行是**被这里捕获**的（下面要把它的输出放进拒绝消息里），
  # 捕获之后 stderr 不会流到终端，故这一段自己打起止两行，让慢扫描看上去在工作——否则读的人
  # 分不清"在扫"和"卡死"，而那种误判正是 `--no-verify` 的入口。stdout 报告契约不受影响。
  printf '开始扫描推送范围 %s（逐个读该范围新引入的 blob，耗时随范围线性增长，可能是数秒到数分钟）。\n' \
    "$PUSH_RANGE" >&2
  SCAN_T0="$SECONDS"
  PUSH_SCAN_RC=0
  PUSH_SCAN="$("$SCAN" --range "$PUSH_RANGE" 2>&1)" || PUSH_SCAN_RC=$?
  printf '推送范围扫描完成：用时 %s 秒。\n' "$((SECONDS - SCAN_T0))" >&2
  if [ "$PUSH_SCAN_RC" != "0" ]; then
    case "$PUSH_SCAN_RC" in
      1) printf 'REFUSED：推送范围敏感信息复检命中，已阻断。\n' >&2 ;;
      *) printf 'REFUSED：推送范围敏感信息复检无法完成（扫描器不可用：规则表或用法错误），已阻断。\n' >&2 ;;
    esac
    printf '%s\n%s\n' "$PUSH_SCAN" "$REPLAN_NOTE" >&2
    exit 5
  fi

  # 本地状态目录永不推送（白名单就在里面；扫描器的内容规则抓不到它）。这一条管的是**历史**：
  # 现在已经不在跟踪集里的 .sync/ 路径（先提交、后删除）仍会随推送发出去。
  # 先把路径清单收进变量再匹配，绝不用 `git log … | grep -q`（长范围下会因 SIGPIPE 静默失效，
  # 而那正是守卫存在的场景）。
  RANGE_PATHS="$(sync_git log --format= --name-only "$PUSH_RANGE")" \
    || refuse_runtime "无法枚举推送范围内的路径（git log 失败）"
  if has_dot_sync_path "$RANGE_PATHS"; then
    printf 'REFUSED：推送范围内含 %s/ 路径（本地状态目录不得推送）。\n%s\n' "$SYNC_STATE_DIR" "$REPLAN_NOTE" >&2
    exit 5
  fi
fi

if [ "$PUSH" = "1" ]; then
  # 显式判失败：否则 set -e 会带着 git 的原始退出码中止，用户只看到一个数字。
  # 文案必须**条件化**：本地提交固然没丢，但"重跑 apply 就是重试"只在**这一轮没有产生提交**时
  # 成立。走到这里的运行往往已经 merge 或采纳过（那正是本地多出提交的原因），此时本地状态与
  # 批准时的凭证不再一致，重跑会先卡在审批门以 exit 3 拒绝——说成"重跑即可"会把人送进一个必然
  # 失败的循环（review 实测：同凭证重跑确实死于 exit 3）。
  sync_git push "$SYNC_ORIGIN_REMOTE" "$SYNC_LOCAL_BRANCH" || {
    printf 'REFUSED：推送失败（远端不可达、权限或网络问题）。本地提交完好，没有丢失。\n' >&2
    printf '重试前先看清这一轮做到哪一步：本轮没有产生过 merge/采纳提交时，本地状态与批准时一致，直接重跑 apply 就是重试（原凭证仍然有效）；\n本轮已经产生过 merge 或采纳提交时，本地状态已与批准时的凭证不同，重跑会先卡在审批门以 exit 3 拒绝 —— 必须先重新 plan、重新审阅、拿到新凭证再 apply。\n' >&2
    exit 1
  }
  printf 'push: 已推送到 %s/%s\n' "$SYNC_ORIGIN_REMOTE" "$SYNC_LOCAL_BRANCH"
else
  printf '已落地（未推送，--no-push）。\n'
fi
exit 0
