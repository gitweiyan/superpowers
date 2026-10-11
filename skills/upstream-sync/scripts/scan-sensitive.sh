#!/usr/bin/env bash
# 敏感信息扫描器：G1/G2/G3 三道闸门共用。
# 用法：scan-sensitive.sh --staged | --range <rev-range> | --paths <path>...
# 契约：输出 <path>:<line>:<rule-id>: <脱敏片段>；文件名类规则输出 <path>::<rule-id>: <basename>
#       退出码 0 干净、1 命中、2 用法错误（规则表/输入不可用、枚举与实扫对不上）。
#
# 扫的是"将要被推上去的那份字节"，而不是工作区此刻的样子：
#   --staged  索引 blob（先 `rev-parse --verify :path` 取对象 id，再 `cat-file -t` 判类型、
#             `cat-file blob` 读内容）——正是 G2 要提交的内容
#   --paths   文件系统中的那些路径（这是它自己的契约：扫这些文件）
#   --range   该范围**新引入的全部 blob**（git rev-list --objects B --not A），也就是 git push
#             会发布的那批对象——不是"右端修订上的那份内容"。理由：推送的是范围内**所有提交
#             可达的**对象，提交 A 加入密钥、提交 B 把文件删掉或把那行改干净时，右端什么都看不到，
#             可那个 blob 照样会永久留在远端历史里；只读右端的实现恰好在"提交、发现、清理、推送"
#             这个最可能真实发生的次序上报"干净"，也就是对推送中最危险的那份字节豁免。
#             单位因此是对象而不是路径：同一个 blob 出现在多个路径/多个提交时按对象 id 去重、
#             只扫一次；报告的路径用 git 自己给的那个，git 没给路径时退回对象 id。
#             但**对象清单不是路径清单**：git 对每个对象只打印一个路径，同一份字节出现在两个
#             路径上时另一个路径根本不会出现。故 pathname 规则与"该不该跳过"都改在范围的
#             **全名清单**上评估（右端 ACMR diff ∪ 对象清单打印的路径），内容仍按对象 id 去重、
#             每个 blob 只读一次。否则"无辜路径 + 凭据路径同字节"会让凭据路径永不评估，
#             "跳过清单上的路径 + 别处同字节"则会让整份字节因为那一个名字而被跳过——两处都是漏扫。
#             （跳过清单今天只剩仓库根的 `.sync/*` 一项，但这条旁路仍然必需：状态目录先被误提交、
#             同一份字节又出现在别处，正是它唯一还能碰上的真实形状。）
#             两种写法都只取右端引入的对象：`A..B` 与 `A...B` 的左端一律按 A 处理（`A...B` 在
#             git 里是对称差，会连 A 一侧独有的对象一起列出，那样的范围会把远端早已发布的内容
#             算成本次推送的问题）。左端缺省（`..B` / `...B`）按 git 的规则取 HEAD。
#             代价：成本随本次推送的规模线性（与即将发布的内容同阶），首次推送一次性开销可接受。
# 读工作区是危险的：`git add` 之后再把手边的文件改干净，闸门会报 0 干净，而索引里那份
# 密钥照样会被推上去——它没有检查它声称担保的东西。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$HERE/sync-lib.sh"

PATTERNS="$HERE/patterns.tsv"
EXCERPT_MAX=100
CONTENT_RE=""
MODE=""
RANGE=""
RANGE_REV=""
RANGE_LEFT=""
PATHS=""
WORK=""
CONTENT_FILE=""
MATCH_FILE=""
HITS_FILE=""
UNITS=""
UNITS_ALL=""
UNITS_RAW=""
NAMES=""
NAMES_RAW=""
NAMES_OBJ=""
NAMES_EVAL_OBJ=""
NAMES_EVAL_DIFF=""
NAMES_DIFF_NONSKIP=""
UNIT_OIDS=""
UNIT_TYPES=""
NAME_SPECS=""
NAME_OIDS_RAW=""
SCAN_OIDS=""

usage() {
  printf '用法: scan-sensitive.sh --staged | --range <rev-range> | --paths <path>...\n' >&2
  exit 2
}

fail_usage() { # 输入/规则表不可用：一律 2，绝不返回 0（返回 0 等于放行）
  printf 'scan-sensitive: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  --staged) MODE="staged"; shift ;;
  --range)  MODE="range"; RANGE="${2:-}"; [ -n "$RANGE" ] || usage; shift 2 ;;
  --paths)  MODE="paths"; shift; PATHS="$*"; [ -n "$PATHS" ] || usage ;;
  *) usage ;;
esac

# C：规则表读不到时绝不能"判定干净"，也不能借用 1——1 的语义是"命中"，三个消费者会照着
# 它打印一套处理不了命中的补救指引。规则表不可用是用法/环境错误，即 2。
[ -r "$PATTERNS" ] || fail_usage "规则表不可读：${PATTERNS}（拒绝在无规则的情况下判定干净）"

# set -f：关闭路径名展开。命令替换的结果还要经过分词，路径里出现 * 或 ? 时会被展开成
# 别的文件名，于是"扫了哪些文件"取决于当前目录里恰好有什么。bash 3.2 没有 mapfile，
# 而管道里的 while 会跑在子壳里（HITS 计数会丢），故保留 for + 命令替换的形状。
set -f

# --paths 里有一条路径不存在时，绝不能"扫了 0 个文件然后报干净"：闸门会静默失效。
# 这是用法错误（2），不是干净（0）。校验必须在主壳里做——collect_files 跑在命令替换的
# 子壳里，在那里 exit 只会结束子壳，主循环照样按"无输出"收尾。
if [ "$MODE" = "paths" ]; then
  for p in $PATHS; do
    [ -e "$p" ] || fail_usage "路径不存在：${p}"
  done
fi

# ---------------------------------------------------------------------------
# B：规则表加载校验。表不可用（空表、字段错位、kind 拼错、正则编译不过）必须 fail closed：
#   - 非空行必须恰好 4 个 TAB 字段（整张空格分隔的表读出来是 0 条规则，于是"干净"）
#   - kind 只能是 content / pathname；id 非空且唯一；正则非空
#   - 两种 kind 都必须至少有一条规则（缺 content 就等于内容根本不扫）
#   - 每条正则可编译。一条坏正则会毁掉"合并匹配"这条脱敏链路，而逐条 grep 的检测仍然
#     命中，于是未脱敏的整行被当成片段打印出去——在源头拦住它。
# ---------------------------------------------------------------------------
TABLE_ERR="$(awk -F"$(printf '\t')" '
  /^[[:space:]]*$/ { next }
  NF != 4 { print "第 " NR " 行字段数为 " NF "（应为 4，TAB 分隔）"; bad = 1; next }
  $2 != "content" && $2 != "pathname" { print "第 " NR " 行 kind 为 [" $2 "]（只能是 content 或 pathname）"; bad = 1; next }
  $1 == "" { print "第 " NR " 行规则 id 为空"; bad = 1; next }
  $3 == "" { print "第 " NR " 行正则为空"; bad = 1; next }
  seen[$1]++ { print "第 " NR " 行规则 id 重复 [" $1 "]"; bad = 1 }
  END { exit(bad ? 1 : 0) }
' "$PATTERNS")" || fail_usage "规则表不可用：${PATTERNS}；${TABLE_ERR}"

TABLE_COUNTS="$(awk -F"$(printf '\t')" '
  /^[[:space:]]*$/ { next }
  $2 == "content" { c += 1 }
  $2 == "pathname" { p += 1 }
  END { printf "%d %d\n", c + 0, p + 0 }
' "$PATTERNS")" || fail_usage "规则表不可用：${PATTERNS}"
N_CONTENT="${TABLE_COUNTS%% *}"
N_PATHNAME="${TABLE_COUNTS##* }"
[ "$N_CONTENT" -gt 0 ] || fail_usage "规则表里没有任何 content 规则（拒绝在内容不扫的情况下判定干净）：${PATTERNS}"
[ "$N_PATHNAME" -gt 0 ] || fail_usage "规则表里没有任何 pathname 规则（拒绝在文件名不扫的情况下判定干净）：${PATTERNS}"

while IFS="$(printf '\t')" read -r rid kind re desc; do
  [ -n "${rid:-}" ] || continue
  if printf '' | grep -qE -- "$re"; then
    :
  else
    crc=$?
    # 1 = 没有匹配，说明这条正则可以编译；其余（grep 的 2）就是编译不过。
    case "$crc" in
      1) : ;;
      *) fail_usage "规则 ${rid} 的正则无法编译（拿它扫出的结果不可信）：${re}" ;;
    esac
  fi
done < "$PATTERNS"

# range：解析两端修订并确认它们存在。解析不出来的修订必须当场报错，不能留给下游的枚举去
# "悄悄什么都没枚举到"——枚举出空清单会被判成"没有东西要扫"，于是报 0 干净，这是 fail-open。
range_rev() { # rev-range -> 右端修订；A...B 取 B，A..B 取 B，单个修订原样返回
  case "$1" in
    *...*) printf '%s\n' "${1##*...}" ;;
    *..*)  printf '%s\n' "${1##*..}" ;;
    *)     printf '%s\n' "$1" ;;
  esac
}

range_left() { # rev-range -> 左端修订；A...B 取 A，A..B 取 A，单个修订为空
  case "$1" in
    *...*) printf '%s\n' "${1%%...*}" ;;
    *..*)  printf '%s\n' "${1%%..*}" ;;
    *)     printf '%s\n' "" ;;
  esac
}

if [ "$MODE" = "range" ]; then
  # G1：只接受真正的 rev-range。传单个修订（无 ..）时 `git diff <rev>` 比的是该修订与工作区，
  # 而内容从 <rev> 读——于是"索引/工作区里新增、修订里还没有"的路径被判成"已删除"跳过，
  # 报 0 干净（修复前这一形状读的是工作区，本来还能命中）。没有设计中的调用方会传单个修订
  #（plan.sh 用 A...B，apply.sh 与钩子用 A..B），语义含混的形状一律拒掉。
  case "$RANGE" in
    *..*) : ;;
    *) fail_usage "--range 需要的是 rev-range（形如 A..B 或 A...B），收到的是单个修订：${RANGE}" ;;
  esac
  RANGE_REV="$(range_rev "$RANGE")"
  RANGE_LEFT="$(range_left "$RANGE")"
  [ -n "$RANGE_REV" ] || fail_usage "无法从 rev-range 解析出右端修订：${RANGE}"
  sync_git rev-parse --verify --quiet "$RANGE_REV" >/dev/null 2>&1 \
    || fail_usage "rev-range 的右端修订不存在：${RANGE_REV}（范围：${RANGE}）"
  # 左端空串（形如 `..B` / `...B`）：git 自己的规则是"缺省那一侧即 HEAD"，这里照抄，
  # 免得同一串参数在 git 里和在扫描器里有两种含义。
  [ -n "$RANGE_LEFT" ] || RANGE_LEFT="HEAD"
  sync_git rev-parse --verify --quiet "$RANGE_LEFT" >/dev/null 2>&1 \
    || fail_usage "rev-range 的左端修订不存在：${RANGE_LEFT}（范围：${RANGE}）"
fi

WORK="$(mktemp -d)" || fail_usage "无法创建临时目录"
CONTENT_FILE="$WORK/content"
MATCH_FILE="$WORK/matches"
HITS_FILE="$WORK/hits"
UNITS="$WORK/units"
UNITS_ALL="$WORK/units.all"
UNITS_RAW="$WORK/units.raw"
NAMES="$WORK/names"
NAMES_RAW="$WORK/names.raw"
NAMES_OBJ="$WORK/names.obj"
NAMES_EVAL_OBJ="$WORK/names.eval.obj"
NAMES_EVAL_DIFF="$WORK/names.eval.diff"
NAMES_DIFF_NONSKIP="$WORK/names.diff.nonskip"
UNIT_OIDS="$WORK/unit.oids"
UNIT_TYPES="$WORK/unit.types"
NAME_SPECS="$WORK/name.specs"
NAME_OIDS_RAW="$WORK/name.oids.raw"
SCAN_OIDS="$WORK/scan.oids"
cleanup_work() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; return 0; }
trap cleanup_work EXIT

# 不参与扫描的文件：**只有一项**——**仓库根的** `.sync/*`。而且它必须精确到位、必须与**守卫集**
# 逐点一致。这不是风格问题，是安全边界：跳过集与守卫集之间只要留出一条缝，落在缝里的内容就
# 三道闸门都不扫、守卫也不拦，它会被签发 PLAN_ID 并推上远端。
#   - 仓库根的本地状态目录 `.sync/`：白名单条目按定义就是"规则 + 路径 + 原因"，其中的路径正是
#     某条路径类/环境类规则要匹配的东西。不排除它，allowlist.txt 会被它自己豁免的那条规则抓住，
#     而且没法给自己再写一条豁免（写下去又是同样一句话），闸门会卡在自我指涉里。
#     旧写法是 `*/"$SYNC_STATE_DIR"/*`（任意层级），而 apply.sh 的两道 .sync/ 守卫都是**根锚定**
#     的：跟踪集检查用 pathspec `.sync/`、推送范围检查只认行首的 `.sync/`。于是
#     `skills/<x>/.sync/**` 既不扫也不拦。这里只跳仓库根那一层，两边就一致了。
#     这一项是**有守卫的**豁免：跳过侧就是本函数，守卫侧是 apply.sh 的跟踪集检查与推送范围检查，
#     两边认的是同一批路径。
#   - 机制**自己的那一个规则表文件**曾经也在这里（仓库相对与绝对两条 arm），已**删除**：它没有
#     任何守卫兜底（apply 的两道守卫都只锚定 `.sync/`），写进规则表的凭据会被三道闸门全部跳过，
#     是本文件最该避免的那种"跳过但无守卫"的缝。删它的前提经过实测：这张表**并不自我命中**
#     （把出厂表逐字节复制到非豁免路径上扫，exit 0 零输出；`tests/upstream-sync/test-scanner.sh`
#     的 §12a 把这条事实钉成回归锚点），故那条豁免只是"精确的保险"而非必需。
#     副作用是好的，且是有意的：`--paths skills/upstream-sync` 这条**自净检查**从此真的扫这张表，
#     将来若有人加一条能匹配自己那一行文本的规则，自净检查会**立刻响亮失败**（此前那张表每次
#     都被整份跳过，与"干净"不可区分）。到那时要么改那条规则，要么把规则表写成本身不含自我
#     命中文本的形状 —— 两条路都比"悄悄跳过整张表"好。
# 除 `--paths` 外条目本来就是仓库相对路径；`--paths` 可能给绝对路径，故先按 `$ROOT/` 归一。
# 这条归一现在**只服务于上面那一条 arm**，两种传法（绝对路径与仓库相对路径）都必须仍然生效。
is_skipped() { # 路径
  local p
  case "$1" in
    "$ROOT"/*) p="${1#"$ROOT"/}" ;;
    *)         p="$1" ;;
  esac
  case "$p" in
    "$SYNC_STATE_DIR"/*) return 0 ;;                    # 仅仓库根的 .sync/
  esac
  return 1
}

# ---------------------------------------------------------------------------
# 枚举"这一轮到底要检查哪些字节"。每一行的单位是"一个待查条目"：
#   --staged / --paths  一行就是一条路径，内容随后从索引 blob / 文件系统读；
#   --range             一行是"<对象 id> <路径>"，路径可能为空（git 没给路径时），
#                       此时报告的路径退回对象 id。
# 三个枚举器都只在失败时返回非零：枚举失败绝不能当成"没有东西可以扫"（见下面的调用点）。
# ---------------------------------------------------------------------------
collect_files() {
  case "$MODE" in
    # -c core.quotePath=false 是功能必需，不只是可移植性：默认的 quotePath 会把非 ASCII
    # 路径输出成带引号的 C 转义形式，这些路径既读不开，又让同一份仓库状态的扫描结果随
    # 调用者的 git 配置变化——而扫描结果要进 state hash。
    staged) sync_git -c core.quotePath=false diff --cached --name-only --diff-filter=ACMR ;;
    paths)  for p in $PATHS; do
              if [ -d "$p" ]; then
                find "$p" -type f | LC_ALL=C sort
              else
                printf '%s\n' "$p"
              fi
            done ;;
  esac
}

range_objects() {
  # --range A..B 扫的是"B 引入的、A 那一侧还没有的对象"。用的是 `rev-list --objects B --not A`
  # 而不是把整串参数交给 rev-list：`A...B` 在 git 里是**对称差**，会把 A 侧（远端已经有的那些
  # 提交）的对象也列出来，于是远端既有的内容会被算成本次推送的问题，凭空阻断干净提交——
  # 与钩子 F2 那条"范围之外的既有命中不阻断"正相反。两种写法在这里都只取右端引入的对象。
  #
  # 头部那句"也就是 git push 会发布的那批对象"在**左端就是推送起点**时是字面成立的：钩子的两种
  # 形状（`remote_sha..local_sha` 与 `main..local_sha`）与 apply 的 `origin/local..local` 都属于
  # 这一类。但 `plan.sh` 与 `sync_state_hash` 传的是 `main...local`，那里的 main 是**镜像分支**、
  # 不一定是推送目的地上已有的那个提交，故那两处是"以镜像为基准的近似"，不是定理；"这次推送
  # 到底会不会发布这些字节"仍以钩子/apply 的复检为准。
  #
  # -c core.quotePath=false：rev-list 会打印路径，默认 quotePath 会把非 ASCII 路径写成带
  # 引号的 C 转义形式；那些路径既读不成路径，又让同一段范围的扫描结果随调用者的 git 配置
  # 变化——而扫描结果要进 state hash。
  sync_git -c core.quotePath=false rev-list --objects "$RANGE_REV" --not "$RANGE_LEFT"
}

range_names() {
  # 该范围在**右端**新增/改动/改名/复制的路径清单。它存在的唯一理由：`rev-list --objects`
  # 对每个对象只给**一个**路径（git 自己挑的），同一份字节出现在两个路径上时另一个路径根本
  # 不会出现。于是只看对象清单，两件事都会漏：
  #   - 同一份字节在 aaa.txt 与 server.key 上、git 挑中 aaa.txt → 凭据类文件名永不评估
  #     （4b 首版的实测回归：旧实现按路径枚举时本来拦得住）；
  #   - 同一份字节在跳过清单上的路径与别处、git 挑中前者 → 整个对象的字节因为那一个名字被
  #     跳过，而它确实会随推送发布（今天能撞上的写法是 `.sync/<x>` 与别处同字节）。
  # 被删掉的路径（范围内加了又删）不在 ACMR 里，但对象清单会打印它们的路径，故调用点取并集。
  #
  # -c core.quotePath=false：路径按字节输出（同 collect_files 的理由），且扫描结果进 state hash。
  sync_git -c core.quotePath=false diff --name-only --diff-filter=ACMR "$RANGE"
}

oid_has_scan_name() { # oid：该对象在范围内是否**有任何一个**不被跳过的名字
  # 只用于"git 打印的那个路径恰好在跳过清单上"这一罕见分支：那时若同一份字节在范围内还有别的
  # 名字，就不能跳过（见调用点与 range_names 的注释）。清单来自 `cat-file --batch-check`，
  # 每行一个对象 id（可能重复，无所谓：这里只做成员判定），整行精确匹配。
  # grep 读的是文件（不是管道），没有 SIGPIPE 那条 fail-open。
  [ -s "$SCAN_OIDS" ] || return 1
  local rc=0
  LC_ALL=C grep -qxF -- "$1" "$SCAN_OIDS" || rc=$?
  case "$rc" in
    0) return 0 ;;   # 有
    1) return 1 ;;   # 确实没有
    *) return 0 ;;   # grep 出错：宁可多扫一次，也不静默跳过（fail closed）
  esac
}

unitize_objects() { # rev-list --objects 的原始行 -> "<对象 id> <路径>" 行（路径为空则留空）
  # rev-list 的输出有两形状："<oid> <path>"（blob，以及带路径的树）与 "<oid>"（提交、无路径的树）。
  # 路径里可能有空格，故这里只剥掉第一个空格之前的那一段，剩下的原样保留。对象类型一概不在这里
  # 判断：单看"有没有路径"区分不出 blob 与树，那会把树当成文本扫（G3 的教训）。
  awk '{ if (NF >= 2) { oid = $1; p = $0; sub(/^[^ ]+ /, "", p); printf "%s %s\n", oid, p } else { printf "%s \n", $1 } }' "$1"
}

dedup_units() { # 按对象 id 去重：同一个 blob 出现在多个路径/多个提交里只扫一次
  # 排序在前是为了让"留下哪一个路径"是确定的（同 id 取字典序最小的那条），这样同一段范围的
  # 扫描输出不随 rev-list 的遍历顺序变化——而输出要进 state hash。
  LC_ALL=C sort | awk '!seen[$1]++'
}

# 片段脱敏。命中行直接回显原文等于让闸门变成第二次泄漏：截断（cut -c1-N）不是脱敏，
# 短密钥会被整行照抄。这里的做法是拿规则表把该行里"所有"规则的匹配文本都换成掩码
# （同一行里可能有另一条规则的原文），再用"全规则合并匹配"兜底；任何一步没跑成，就整行
# 隐去——绝不输出未被证明安全的原文。
withhold() { printf '[片段已隐去]\n'; }

load_content_re() {
  [ -n "$CONTENT_RE" ] && return 0
  CONTENT_RE="$(awk -F"$(printf '\t')" '$2 == "content" { printf "%s|", $3 }' "$PATTERNS")" || CONTENT_RE=""
  CONTENT_RE="${CONTENT_RE%|}"
}

redact_literal() { # 匹配原文
  printf '%s' "$1" | awk '{ n = length($0); if (n <= 6) print "***"; else print substr($0, 1, 3) "***" substr($0, n - 1, 2) }'
}

replace_literal() { # 文本 字面 替换串：按字面替换（不做正则解析，掩码里带 * 也不会被当成量词）
  SYNC_LIT="$2" SYNC_REP="$3" awk '{ lit = ENVIRON["SYNC_LIT"]; rep = ENVIRON["SYNC_REP"]; n = length(lit)
      if (n == 0) { print; next }
      line = $0; out = ""
      while ((p = index(line, lit)) > 0) { out = out substr(line, 1, p - 1) rep; line = substr(line, p + n) }
      print out line }' <<<"$1"
}

mask_excerpt() { # 行文本 -> stdout（绝不输出原文）
  load_content_re
  local out m rep grc guard
  out="$1"
  # 规则集为空时无法证明这行安全；正常情况下加载阶段的检查已经拦住这种表。
  [ -n "$CONTENT_RE" ] || { withhold; return 0; }
  # 取"真实匹配文本"必须用与检测同一套的大小写不敏感 grep：规则里 AKIA[0-9A-Z] 与
  # -----BEGIN [A-Z ]*PRIVATE KEY----- 这类写法本身要求大写，把小写化后的行交给 awk
  # match() 根本匹配不上，掩码会悄悄不生效（只剩兜底的整行隐去）。
  guard=0
  if printf '%s\n' "$out" | grep -oiE -- "$CONTENT_RE" > "$MATCH_FILE" 2>/dev/null; then
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      if [ "$guard" -ge 20 ]; then withhold; return 0; fi
      guard=$((guard + 1))
      rep="$(redact_literal "$m")" || { withhold; return 0; }
      out="$(replace_literal "$out" "$m" "$rep")" || { withhold; return 0; }
    done < "$MATCH_FILE"
  else
    grc=$?
    # 1 = 没有匹配；其余（grep 出错、匹配清单写不进去）说明脱敏链路没跑成，整行隐去。
    if [ "$grc" != 1 ]; then withhold; return 0; fi
  fi
  # 兜底：脱敏后若仍能被任何一条规则命中（含上面的迭代上限被撞到的情况），整行隐去。
  if printf '%s\n' "$out" | grep -qiE -- "$CONTENT_RE" 2>/dev/null; then
    withhold
    return 0
  fi
  printf '%s\n' "$out" | awk -v n="$EXCERPT_MAX" '{ if (length($0) > n) print substr($0, 1, n) "..."; else print }' || withhold
}

HITS=0
ROOT="$(sync_repo_root)"
ALLOWLIST="$ROOT/$SYNC_STATE_DIR/allowlist.txt"

# 白名单：本地、不入库、不推送。每行 "rule-id<TAB>仓库相对路径<TAB>原因"，只豁免这一对。
# 匹配必须是"前两个字段都相等"：子串匹配（grep -qF）会让更长的条目顺带豁免它的前缀路径
# （…/a.txt.bak 豁免了 …/a.txt），也会让原因列里抄来的一组键变成授权。原因列可选，
# 故用 awk 按 TAB 精确比对前两个字段。
phys_path() { # 路径 -> 物理路径（用 cd … && pwd -P，不能用 readlink -f）；目录不可达时原样返回
  local p d b
  p="$1"
  case "$p" in
    */) p="${p%/}" ;;
  esac
  [ -n "$p" ] || { printf '%s\n' "$1"; return 0; }
  case "$p" in
    */*) d="${p%/*}"; b="${p##*/}" ;;
    *)   d="."; b="$p" ;;
  esac
  [ -n "$d" ] || d="/"
  [ -d "$d" ] || { printf '%s\n' "$p"; return 0; }
  case "$d" in
    /) printf '/%s\n' "$b" ;;
    *) printf '%s/%s\n' "$(cd "$d" && pwd -P)" "$b" ;;
  esac
}

allow_key() { # 显示路径 -> 仓库相对路径（仓库外原样保留）
  # 先物理化再比：sync_repo_root 给的是 pwd -P 的物理路径，而调用者可能从符号链接前缀传路径
  #（macOS 上 /var 就是 /private/var 的符号链接）。不物理化，同一个文件经由 --paths 与
  # --staged 会算成两个不同的键，白名单就得写两条——那正是这一条要根治的问题。
  local h
  h="$(phys_path "$1")"
  case "$h" in
    "$ROOT"/*) printf '%s\n' "${h#"$ROOT"/}" ;;
    *)         printf '%s\n' "$1" ;;
  esac
}

allowed() { # rule-id path
  [ -f "$ALLOWLIST" ] || return 1
  SYNC_ARID="$1" SYNC_APATH="$(allow_key "$2")" awk -F"$(printf '\t')" '
    NF >= 2 && $1 == ENVIRON["SYNC_ARID"] && $2 == ENVIRON["SYNC_APATH"] { ok = 1 }
    END { exit(ok ? 0 : 1) }' "$ALLOWLIST"
}

report_hit() { # path line rule-id text
  allowed "$3" "$1" && return 0
  printf '%s:%s:%s: %s\n' "$1" "$2" "$3" "$4"
  HITS=$((HITS + 1))
}

# 枚举失败绝不能当成"没有东西可以扫"：非法 rev-range、指向非仓库的 SYNC_REPO_ROOT 都会让
# git 报错却只留下空清单，闸门随即静默判定干净——这是 fail-open，比误报危险得多。
# 故在主壳里跑枚举并逐个检查退出码（放进管道或命令替换的子壳里，那个 exit 影响不到主壳）。
STAT_DEDUP=0
if [ "$MODE" = "range" ]; then
  range_objects > "$UNITS_RAW" \
    || fail_usage "无法枚举该范围引入的对象（范围 ${RANGE}；rev-range 非法、端不可达或对象库读不了）"
  unitize_objects "$UNITS_RAW" > "$UNITS_ALL" \
    || fail_usage "无法解析该范围引入的对象清单（范围 ${RANGE}）"
  dedup_units < "$UNITS_ALL" > "$UNITS" \
    || fail_usage "无法按对象 id 去重（范围 ${RANGE}）"
  # 三个数字必须对得上：rev-list 的行数 = 解析出的条目数（一行进一行出，谁也不许被吞掉）。
  N_OBJ_LINES="$(awk 'END { print NR + 0 }' "$UNITS_RAW")"
  N_ALL="$(awk 'END { print NR + 0 }' "$UNITS_ALL")"
  [ "$N_OBJ_LINES" -eq "$N_ALL" ] \
    || fail_usage "范围 ${RANGE} 枚举出 ${N_OBJ_LINES} 行对象，只解析出 ${N_ALL} 条条目"

  # ---- 全名清单（只有"文件"进得来）------------------------------------------
  # 内容按对象去重（上一段），但"名字"必须看全：pathname 规则与跳过判定都在这里用（理由见
  # range_names / oid_has_scan_name）。清单有两个来源，**每个来源都做类型过滤**：
  #
  #   (i) 对象清单里 git 打印的路径。`rev-list --objects` 会**带路径**打印被改动的树
  #       （`deploy/env` 这种目录），而 pathname 规则问的是"文件名像不像凭据"。目录不是文件：
  #       不剔掉它，任何"改动了 env/、credentials/、*.key/ 之类目录下的文件"的推送都会被一条
  #       `deploy/env::path-secret-file: env` 挡住（review N1 实测的假阳性；`--staged`/`--paths`
  #       从不枚举目录，故这是 range 独有的）。这里用**一次** `cat-file --batch-check` 拿到各
  #       对象的类型（比对每个对象各起一次进程便宜得多），只留 blob 的那些路径。
  #   (ii) 右端 ACMR diff 的名字：那是文件与**子模块指针**，后者在树里是 160000 的条目、对象是
  #        commit（本地常常还读不到），同样不是文件，故也查一次类型。这一层是**纵深防御**：
  #        即使将来有非 blob 路径混进清单，也不会变成一条"凭据文件名"命中。
  #
  # 每个来源的丢弃量都单独计数并互相校核：数到却没处理绝不能读成干净。
  awk '{ print $1 }' "$UNITS" > "$UNIT_OIDS"
  : > "$UNIT_TYPES"
  if [ -s "$UNIT_OIDS" ]; then
    sync_git cat-file --batch-check < "$UNIT_OIDS" > "$UNIT_TYPES" \
      || fail_usage "无法解析该范围引入对象的类型（范围 ${RANGE}；对象库读不了）"
  fi
  NAME_SPLIT="$(awk -v keep="$NAMES_OBJ" '
    FILENAME == ARGV[1] { if ($2 == "blob") b[$1] = 1; next }
    { p = $0; sub(/^[^ ]+ /, "", p); if (p == "") next
      if ($1 in b) { print p > keep; k += 1 } else { d += 1 } }
    END { printf "%d %d\n", k + 0, d + 0 }' "$UNIT_TYPES" "$UNITS_ALL")" \
    || fail_usage "无法按对象类型过滤该范围的名字清单（范围 ${RANGE}）"
  N_OBJ_BLOB_PATHS="${NAME_SPLIT%% *}"
  N_OBJ_NONBLOB_PATHS="${NAME_SPLIT##* }"
  N_OBJ_PATHS_ALL="$(awk 'NF >= 2 { n += 1 } END { print n + 0 }' "$UNITS_ALL")"
  [ "$N_OBJ_PATHS_ALL" -eq $((N_OBJ_BLOB_PATHS + N_OBJ_NONBLOB_PATHS)) ] \
    || fail_usage "对象清单里带路径的行数为 ${N_OBJ_PATHS_ALL}，类型过滤只解释到 $((N_OBJ_BLOB_PATHS + N_OBJ_NONBLOB_PATHS)) 条（范围 ${RANGE}）"

  range_names > "$NAMES_RAW" \
    || fail_usage "无法枚举该范围引入的路径清单（范围 ${RANGE}；rev-range 非法、端不可达或对象库读不了）"
  STAT_NAME_SKIP=0      # diff 名字里落在跳过清单上的条数
  N_DIFF_NAMES=0
  : > "$NAME_SPECS"
  : > "$NAMES_DIFF_NONSKIP"
  while IFS= read -r n || [ -n "$n" ]; do
    [ -n "$n" ] || continue
    N_DIFF_NAMES=$((N_DIFF_NAMES + 1))
    if is_skipped "$n"; then
      STAT_NAME_SKIP=$((STAT_NAME_SKIP + 1))
      continue
    fi
    printf '%s\n' "$n" >> "$NAMES_DIFF_NONSKIP"
    printf '%s:%s\n' "$RANGE_REV" "$n" >> "$NAME_SPECS"
  done < "$NAMES_RAW"
  # 这次 batch-check 同时给出两件事：SCAN_OIDS（"这份字节在范围内还有没有别的、不被跳过的
  # **文件**名字"——内容循环的跳过判定要用它）与"哪些 diff 名字解析出来是 blob"。
  # 解析不出来的名字（范围内被删、或路径不存在）不进 SCAN_OIDS，但它们仍按来源 (i) 的类型
  # 结论参与 pathname 评估；内容一律只来自对象清单，绝不因为一个名字而凭空读出内容。
  : > "$SCAN_OIDS"
  : > "$NAMES_EVAL_DIFF"
  N_DIFF_NONBLOB=0
  if [ -s "$NAME_SPECS" ]; then
    sync_git cat-file --batch-check < "$NAME_SPECS" > "$NAME_OIDS_RAW" \
      || fail_usage "无法解析该范围内的路径对应的对象（范围 ${RANGE}；对象库读不了）"
    N_DIFF_NONBLOB="$(awk -v names="$NAMES_DIFF_NONSKIP" -v keep="$NAMES_EVAL_DIFF" -v oids="$SCAN_OIDS" '
      FILENAME == ARGV[1] { nm[FNR] = $0; next }
      { if ($2 != "blob") { d += 1; next }
        print nm[FNR] > keep
        oid = $1
        if (length(oid) == 40 || length(oid) == 64) { if (oid !~ /[^0-9a-f]/) print oid > oids } }
      END { printf "%d\n", d + 0 }' "$NAMES_DIFF_NONSKIP" "$NAME_OIDS_RAW")" \
      || fail_usage "无法按对象类型过滤该范围的名字清单（范围 ${RANGE}）"
  fi
  N_DIFF_EVAL="$(awk 'END { print NR + 0 }' "$NAMES_EVAL_DIFF")"
  [ "$N_DIFF_NAMES" -eq $((N_DIFF_EVAL + STAT_NAME_SKIP + N_DIFF_NONBLOB)) ] \
    || fail_usage "右端路径清单 ${N_DIFF_NAMES} 条，只处理了 $((N_DIFF_EVAL + STAT_NAME_SKIP + N_DIFF_NONBLOB)) 条（评估 ${N_DIFF_EVAL}、按跳过清单豁免 ${STAT_NAME_SKIP}、非文件 ${N_DIFF_NONBLOB}；范围 ${RANGE}）"

  # 来源 (i) 的 blob 路径：用同一把跳过尺子分成"评估"与"豁免"
  STAT_NAME_OBJ_SKIP=0
  : > "$NAMES_EVAL_OBJ"
  while IFS= read -r n || [ -n "$n" ]; do
    [ -n "$n" ] || continue
    if is_skipped "$n"; then
      STAT_NAME_OBJ_SKIP=$((STAT_NAME_OBJ_SKIP + 1))
      continue
    fi
    printf '%s\n' "$n"
  done < "$NAMES_OBJ" > "$NAMES_EVAL_OBJ"
  N_OBJ_EVAL="$(awk 'END { print NR + 0 }' "$NAMES_EVAL_OBJ")"
  [ "$N_OBJ_BLOB_PATHS" -eq $((N_OBJ_EVAL + STAT_NAME_OBJ_SKIP)) ] \
    || fail_usage "对象清单里 ${N_OBJ_BLOB_PATHS} 个 blob 路径，只处理了 $((N_OBJ_EVAL + STAT_NAME_OBJ_SKIP)) 个（评估 ${N_OBJ_EVAL}、按跳过清单豁免 ${STAT_NAME_OBJ_SKIP}；范围 ${RANGE}）"

  # 汇总成"要按 pathname 规则评估的路径名"：两个来源合并去重（同一个路径既是 blob 路径又在
  # diff 里时只评估一次），排序保证输出确定（这份输出要进 sync_state_hash）。
  {
    cat "$NAMES_EVAL_OBJ"
    cat "$NAMES_EVAL_DIFF"
  } | LC_ALL=C sort -u > "$NAMES" \
    || fail_usage "无法归并该范围的名字清单（范围 ${RANGE}）"
else
  collect_files > "$UNITS" || fail_usage "无法枚举待扫描文件（模式 ${MODE}）"
fi
N_UNIQ="$(awk 'END { print NR + 0 }' "$UNITS")"
if [ "$MODE" = "range" ]; then
  STAT_DEDUP=$((N_ALL - N_UNIQ))
  # F4：范围扫描的成本与范围线性同阶（本仓库实测约 37ms/blob、整段范围约 10s；长期分叉的首次
  # 推送是分钟级）。全程静默会被读成"卡死了"——而那正是 `--no-verify` 的入口。故起止各打一行
  # 进度到 **stderr**：stdout 是命中契约（`<path>:<line>:<rule-id>: …`），一个字都不能多。
  SCAN_T0="$SECONDS"
  printf '范围扫描开始：%s 个待查对象，范围 %s（逐个读 blob，耗时随范围线性增长，可能是数秒到数分钟）。\n' \
    "$N_UNIQ" "$RANGE" >&2
fi

# E：枚举到的条目必须都被真正检查过。读不了的、竞态消失的、grep 报错的不能默默算进
# "命中 0 处"。各计数器合起来必须等于枚举数，对不上 fail closed——这条同时是给后来者的
# 护栏：谁在循环里新加一条 continue 而忘了记账，这里立刻炸。
#
# （4b 起 --range 不再有"该路径在右端修订上不存在"这一类：条目直接来自对象清单，右端有没有
# 这个路径已经不重要——范围内的 blob 一律要扫，包括右端已被删掉或改干净的那一份。原先那个
# ABSENT 计数器随之取消，取代它的是"按对象 id 去重掉了几条"。）
STAT_ENUM=0
STAT_SCANNED=0
STAT_SKIP=0
STAT_NONBLOB=0

# 尾行没有换行符时，裸 read 会把它整条丢掉（一条路径没被检查，却一个计数都不进）——
# `|| [ -n "$entry" ]` 把最后一行也收进循环。枚举器（git/awk/find）都带换行，这是兜底，
# 而兜底正是"静默漏扫"这一类缺陷最该被拦住的地方。
while IFS= read -r entry || [ -n "$entry" ]; do
  STAT_ENUM=$((STAT_ENUM + 1))

  # 解析条目：range 的条目是"<对象 id> <路径>"，其余两种模式一行就是一条路径。
  case "$MODE" in
    range)
      oid="${entry%% *}"
      f="${entry#* }"
      # git 没给出路径时用对象 id 兜底：宁可诊断里出现一个 id，也不要让这条命中无处安放。
      # （路径里的空格不会被剥掉：只剥第一个空格之前的那一段。）
      [ -n "$f" ] || f="$oid"
      ;;
    *)
      oid=""
      f="$entry"
      ;;
  esac

  if is_skipped "$f"; then
    # range：跳过判定必须看**全名清单**（见 range_names 的注释）。git 只给这份字节一个路径，
    # 若那一个路径恰好落在跳过清单上，而同一份字节在范围内还有别的、不在清单上的名字，它照样
    # 会随推送发布——那时跳过就是漏扫。故先问"这个对象有没有不被跳过的名字"。
    if [ "$MODE" = "range" ] && oid_has_scan_name "$oid"; then
      :
    else
      STAT_SKIP=$((STAT_SKIP + 1))
      continue
    fi
  fi

  # 读"将被推上去的那份字节"。输出行用 git 给出的相对路径：诊断里出现本机绝对路径既噪声大，
  # 又正好是 env-abs-home 这类规则要拦的东西。
  # G2：把"解析出对象"和"读得出内容"分成两步。解析失败 = 该路径在这个修订上确实不存在
  #（staged 由 --diff-filter=ACMR 保证它在索引里，故解析不到属异常 → 2）。解析成功却读不出来
  #（对象缺失/损坏/promisor 缺件/IO 错）绝不能退化成"跳过"——那就是一处静默判干净，必须报 2。
  # range 模式下对象 id 由 rev-list 给出（"解析"这一步已经完成），但"解析得出"同样不保证
  # "读得出"：下面的类型与内容两次读取失败一律 2。
  src=""
  case "$MODE" in
    paths)
      src="$f"
      ;;
    staged)
      oid="$(sync_git rev-parse --verify --quiet ":$f")" || oid=""
      [ -n "$oid" ] \
        || fail_usage "索引里解析不到该路径的对象：${f}（该文件未被检查，拒绝判干净）"
      ;;
  esac

  if [ -n "$oid" ]; then
    # G3：gitlink/子模块指针解析出来的是 commit 对象，`git show` 会把提交头（含作者邮箱）
    # 当成"内容"打出来，于是子模块指针凭空命中 id-email。非 blob 一律不扫；它不是文本，
    # 计入"不可扫描"，让对账计数保持诚实。range 模式下列表里还混着提交与树（rev-list 列出
    # 该范围引入的全部对象），这一条同样把它们挡在扫描之外。
    otype="$(sync_git cat-file -t "$oid" 2>/dev/null)" \
      || fail_usage "对象解析到了却读不出类型（缺失/损坏/IO 错误）：${f}（${oid}）"
    if [ "$otype" != "blob" ]; then
      STAT_NONBLOB=$((STAT_NONBLOB + 1))
      continue
    fi
    sync_git cat-file blob "$oid" > "$CONTENT_FILE" 2>/dev/null \
      || fail_usage "对象解析到了却读不出内容（缺失/损坏/IO 错误）：${f}（${oid}）"
    src="$CONTENT_FILE"
  fi

  [ -f "$src" ] || fail_usage "待扫内容不可读：${f}（该文件未被检查，拒绝判干净）"
  STAT_SCANNED=$((STAT_SCANNED + 1))

  # 文件名类规则
  # range 模式**不在**这里评估：对象清单每个 blob 只有一个路径（git 挑的），在这里评估会漏掉
  # 它没挑中的那些路径（"无辜路径 + 凭据路径同字节"就是这么丢的）。range 的 pathname 规则统一
  # 在下面的全名清单里评估；staged/paths 的单位本来就是路径，照旧在这里做。
  if [ "$MODE" != "range" ]; then
    base="$(basename "$f")"
    while IFS="$(printf '\t')" read -r rid kind re desc; do
      [ "$kind" = "pathname" ] || continue
      if printf '%s' "$base" | grep -qE -- "$re"; then
        report_hit "$f" "" "$rid" "$base"
      fi
    done < "$PATTERNS"
  fi

  # 内容类规则
  while IFS="$(printf '\t')" read -r rid kind re desc; do
    [ "$kind" = "content" ] || continue
    grc=0
    grep -inE -- "$re" "$src" > "$HITS_FILE" 2>/dev/null || grc=$?
    case "$grc" in
      0|1) : ;;   # 0 = 命中，1 = 无命中
      *) fail_usage "扫描 ${f} 时 grep 返回 ${grc}（该文件内容未被检查，拒绝判干净）" ;;
    esac
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in
        # 二进制文件命中时 grep 只给出一句 "Binary file … matches"，没有行号也没有文本；
        # 硬拼进 <path>:<line> 契约里会变成一句谎话，故独立成一条"内容命中但片段隐去"。
        "Binary file "*) report_hit "$f" "" "$rid" "[二进制内容命中，片段已隐去]"; continue ;;
      esac
      n="${line%%:*}"
      text="${line#*:}"
      masked="$(mask_excerpt "$text")"
      report_hit "$f" "$n" "$rid" "$masked"
    done < "$HITS_FILE"
  done < "$PATTERNS"
done < "$UNITS"

# ---------------------------------------------------------------------------
# range：pathname 规则在**全名清单**上评估（内容已在上面按对象去重扫过一遍）。
# 为什么不能顺手在对象循环里做：`rev-list --objects` 每个对象只打印一个路径，同一份字节出现在
# 两个路径上时另一个路径不会出现，凭据类文件名就永远没被评估过（I1 的实测回归）。
# 清单里的每一条**都已经在枚举阶段**按对象类型确认是文件（见上半段的两个来源），故这里不必再查
# 类型：目录（树）与子模块指针都进不来（N1 的实测假阳性就是这么修的）。
# 对账：枚举到的名字必须**条条都被评估过**——谁在循环里多加一条 continue 就立刻炸（与内容循环
# 同一条护栏）。分类阶段的丢弃量另有各自的等式，见上面三段 fail_usage。
# 输出顺序是确定的（清单已 LC_ALL=C sort -u），因为这份输出要进 sync_state_hash。
# ---------------------------------------------------------------------------
STAT_NAME_ENUM=0
STAT_NAME_EVAL=0
if [ "$MODE" = "range" ]; then
  while IFS= read -r n || [ -n "$n" ]; do
    [ -n "$n" ] || continue
    STAT_NAME_ENUM=$((STAT_NAME_ENUM + 1))
    STAT_NAME_EVAL=$((STAT_NAME_EVAL + 1))
    nbase="$(basename "$n")"
    while IFS="$(printf '\t')" read -r rid kind re desc; do
      [ "$kind" = "pathname" ] || continue
      # here-string 而不是 `printf … | grep -q`：后者在 set -o pipefail 下会被 SIGPIPE 读成
      # "没有命中"（本项目已修过两次的 fail-open 形状），不给它留口子。
      if grep -qE -- "$re" <<<"$nbase"; then
        report_hit "$n" "" "$rid" "$nbase"
      fi
    done < "$PATTERNS"
  done < "$NAMES"
  [ "$STAT_NAME_ENUM" -eq "$STAT_NAME_EVAL" ] \
    || fail_usage "名字清单 ${STAT_NAME_ENUM} 条，只评估了 ${STAT_NAME_EVAL} 条：枚举与评估脱节"
fi

PROCESSED=$((STAT_SCANNED + STAT_SKIP + STAT_NONBLOB))
if [ "$STAT_ENUM" -ne "$PROCESSED" ]; then
  fail_usage "枚举到 ${STAT_ENUM} 条待查条目，只处理了 ${PROCESSED} 条（实扫 ${STAT_SCANNED}、规则豁免 ${STAT_SKIP}、非文本对象 ${STAT_NONBLOB}）"
fi

# 上面那条管的是"循环里有没有人偷偷 continue"；这条管的是"枚举出来的条目有没有在进入循环
# 之前就被丢掉"（尾行缺换行、清单文件读失败等）。两条合起来才是"枚举与实扫对得上"。
if [ "$MODE" = "range" ]; then
  ENUM_NOTE="（原始 ${N_ALL} 行对象，按对象 id 去重掉 ${STAT_DEDUP} 条）"
else
  ENUM_NOTE=""
fi
if [ "$STAT_ENUM" -ne "$N_UNIQ" ]; then
  fail_usage "枚举出 ${N_UNIQ} 条待查条目${ENUM_NOTE}，实际检查了 ${STAT_ENUM} 条：枚举与实扫脱节"
fi

# 扫完了（含命中）。这一行必须在下面的命中汇总之前打：读的人先看到"扫完了、用了多久"，
# 再看到"命中 N 处"。失败路径（fail_usage）不打完成行——那本来就是异常结束。
if [ "$MODE" = "range" ]; then
  printf '范围扫描完成：用时 %s 秒。\n' "$((SECONDS - SCAN_T0))" >&2
fi

if [ "$HITS" -gt 0 ]; then
  printf '\n扫描命中 %s 处，已阻断。处理方式：改写（首选）、移出仓库，或由本人写入 %s/allowlist.txt（每行 "rule-id<TAB>仓库相对路径<TAB>原因"，只豁免这一对；该文件本地留存，不入库、不推送）。\n' \
    "$HITS" "$SYNC_STATE_DIR" >&2
  exit 1
fi
exit 0
