#!/usr/bin/env bash
set -uo pipefail
TESTS_FAILED=0
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib-assert.sh"
MECH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)/skills/upstream-sync/scripts"
INSTALL="$MECH/install-pre-push.sh"

# G1：harness 自检。lib-assert.sh 没加载成功时断言会退化成空操作，
# 整个套件会"没有任何失败"地退出 0——那比失败更危险，故此处立即大声失败。
for _fn in assert_eq assert_exit scratch_setup scratch_teardown; do
  command -v "$_fn" >/dev/null 2>&1 \
    || { printf 'harness missing: lib-assert.sh did not load (%s)\n' "$_fn" >&2; exit 2; }
done

scratch_setup
trap scratch_teardown EXIT

assert_exit 0 "安装兜底闸门成功" -- bash "$INSTALL"
assert_exit 0 "重复安装幂等" -- bash "$INSTALL"
HOOK="$SCRATCH_REPO/.git/hooks/pre-push"
[ -f "$HOOK" ] && assert_eq "ok" "ok" "钩子文件存在" || assert_eq "存在" "缺失" "钩子文件存在"

# E4：本文件只允许在 $SCRATCH 里动手。HOOK 之所以指向临时仓库，唯一原因是 scratch_setup
# 导出了 SYNC_REPO_ROOT；一旦那个导出被改名或删除，安装器会落到**真实**仓库的 .git/hooks，
# 而本文件仍然全绿——那是最坏的一种"测试通过"（在开发者机器上改他的钩子还报 ok）。
# 故此处大声设卡：任何要安装或改写的钩子路径都必须落在 $SCRATCH 内，否则以 2 退出，
# 绝不空转通过。下面每一处新钩子路径都过这道卡。
require_in_scratch() {
  case "$1" in
    "$SCRATCH"/*) : ;;
    *) printf 'REFUSED: hook path outside scratch: %s\n' "$1" >&2; exit 2 ;;
  esac
}
require_in_scratch "$HOOK"

# E5b：幂等不能只看"退出 0 + 文件还在"。若两次安装产出的内容不同（例如仓库路径被写成
# 两种形式），旧断言照样全绿。这里比对两次安装后生成物的 sha256，必须逐字节相同。
IDEM_A="$(shasum -a 256 "$HOOK" | awk '{ print $1 }')"
assert_exit 0 "E5b 前置：再装一次仍成功" -- bash "$INSTALL"
IDEM_B="$(shasum -a 256 "$HOOK" | awk '{ print $1 }')"
assert_eq "$IDEM_A" "$IDEM_B" "E5b：重复安装产出的钩子逐字节相同（真幂等，不只是退出 0）"

# E2（可观测部分）：安装器用"同目录临时文件 + mv"原子落位，不得在 hooks 目录里留下
# 半成品/临时垃圾——残留的 pre-push.XXXXXX 既可能是没写完的钩子，也会误导后来者。
# 注意排除 git init 自带的 pre-push.sample，否则这条断言会指着样例文件假失败。
E2_LEFT="no"
for _t in "$SCRATCH_REPO/.git/hooks"/pre-push.*; do
  [ -e "$_t" ] || continue
  case "$_t" in *.sample) continue ;; esac
  E2_LEFT="yes"
done
assert_eq "no" "$E2_LEFT" "E2：hooks 目录里没有遗留的临时文件"
# E2：落位后的**权限模式**必须恰是 755。只断言"属主可执行"是抓不住它声称锁定的事的：
# 711（mktemp 建 600 再 `chmod +x` 的产物）与 700（umask 077 下 `cat >` + `chmod +x`）
# 都能通过 `-x`——而 711 正是本轮顺手修掉的那次权限回归。故这里比模式本身：将来谁把
# `chmod 755` 改回 `chmod +x`，这条必然失败。
assert_eq "755" "$(stat -f '%Lp' "$HOOK")" \
          "E2：落位后的权限模式恰为 755（不随 umask 漂移、不退化成 711）"

# F1：回归锁定"安装时固化仓库路径"。生成的钩子必须带本机制标记（安装器据它判定
# "这是本机制的钩子"，也是幂等与拒绝覆盖的分界），且必须把 SYNC_REPO_ROOT 写死进去。
# 少了后者，钩子在别的仓库里会退回 sync-lib 的 SYNC_SCRIPT_DIR 兜底路径，
# 于是扫的是另一个仓库、真仓库里的敏感内容照样推得出去——闸门形同虚设。
F1_MARK="no"
grep -qF '# upstream-sync managed' "$HOOK" 2>/dev/null && F1_MARK="yes"
assert_eq "yes" "$F1_MARK" "F1：钩子带 managed 标记（安装器识别依据）"
F1_PIN="no"
grep -qF "export SYNC_REPO_ROOT=\"$SCRATCH_REPO\"" "$HOOK" 2>/dev/null && F1_PIN="yes"
assert_eq "yes" "$F1_PIN" "F1：钩子在生成时固化了 SYNC_REPO_ROOT（不得退回脚本目录兜底）"

# 干净内容 push 必须放行（退出 0）
sha="$(git -C "$SCRATCH_REPO" rev-parse local)"
printf 'refs/heads/local %s refs/heads/local %s\n' "$sha" "$sha" | bash "$HOOK" >/dev/null 2>&1
assert_eq "0" "$?" "干净内容放行"

# F1b：F1 的行为侧。人工 `git push` 时钩子由 git 启动，调用者环境里没有 SYNC_REPO_ROOT，
# 而 scratch_setup 把 SYNC_REPO_ROOT 导出给了整个子进程环境——它会**掩盖**"钩子没固化
# 仓库路径"这一缺陷（实测：删掉生成物里的 export 行后，上面那条"干净内容放行"照样 rc=0，
# 因为变量是从测试 shell 继承来的）。这里显式清掉它，让"钩子靠自己固化下来的路径找对仓库"
# 成为一条真会被测到的断言。
printf 'refs/heads/local %s refs/heads/local %s\n' "$sha" "$sha" | env -u SYNC_REPO_ROOT bash "$HOOK" >/dev/null 2>&1
assert_eq "0" "$?" "F1b：无 SYNC_REPO_ROOT 的手工 push 环境下仍扫对仓库并放行"

# 含敏感内容的提交必须被阻断（退出 1）
aws="$(printf 'AK%s' 'IAIOSFODNN7EXAMPLE')"
mkdir -p "$SCRATCH_REPO/skills/leaky"
printf -- '---\nname: leaky\ndescription: 泄漏演示\n---\n\nkey = %s\n' "$aws" > "$SCRATCH_REPO/skills/leaky/SKILL.md"
git -C "$SCRATCH_REPO" add skills/leaky
git -C "$SCRATCH_REPO" commit -qm leaky
sha2="$(git -C "$SCRATCH_REPO" rev-parse local)"
zeros="$(printf '%040d' 0)"
printf 'refs/heads/local %s refs/heads/local %s\n' "$sha2" "$zeros" | bash "$HOOK" >/dev/null 2>&1
assert_eq "1" "$?" "含敏感内容的提交被阻断"

# F4：阻断要说人话，且不得回显命中的原文。扫描器的命中行只给"路径:行号:规则:掩码片段"，
# 闸门自己也只补一条 upstream-sync: 前缀的说明——任何一处把匹配原文打出来，密钥就进了
# 终端与 CI 日志，闸门反而成了泄漏通道。故此处同时锁定"有说明"和"无原文"。
F4_OUT="$SCRATCH/hook-out.txt"
printf 'refs/heads/local %s refs/heads/local %s\n' "$sha2" "$zeros" | bash "$HOOK" >"$F4_OUT" 2>&1
F4_SAID="no"
grep -qF 'upstream-sync: 推送被兜底闸门阻断' "$F4_OUT" 2>/dev/null && F4_SAID="yes"
assert_eq "yes" "$F4_SAID" "F4a：阻断时带 upstream-sync: 前缀的说明（非静默失败）"
# F4b 前置：夹具里**确实**写着原文。少了这条，下面的"输出里没有原文"会退化成同义反复
# （夹具里本来就没有的话，它永远通过，掩码回归也就再也测不出来）。
assert_eq "1" "$(grep -cF "$aws" "$SCRATCH_REPO/skills/leaky/SKILL.md")" \
          "F4b 前置：被扫文件里确实含原文（掩码对照不是同义反复）"
F4_LEAK="no"
grep -qF "$aws" "$F4_OUT" 2>/dev/null && F4_LEAK="yes"
assert_eq "no" "$F4_LEAK" "F4b：阻断输出不回显命中的原文（掩码契约）"

# F2：钩子扫的是"本次要推的范围"，而不是整条历史。已经落在远端一侧的泄漏提交
# 不得让后续干净提交被误伤。这条同时是"必须传真正的 rev-range"的回归锚点：
# 左端（远端已有、本次不会再发布）可达的对象不进入本次扫描，而单个修订（裸 sha）
# 会让扫描器以 2 拒绝=阻断。
# 注意 F2 与 F6 划的是同一把尺子的两端：左端之外的既有泄漏不报（F2），范围内新引入
# 的泄漏必须报（F6，包括右端已经看不到的那份 blob）。
mkdir -p "$SCRATCH_REPO/skills/clean"
printf -- '---\nname: clean\ndescription: 干净的技能\n---\n' > "$SCRATCH_REPO/skills/clean/SKILL.md"
git -C "$SCRATCH_REPO" add skills/clean
git -C "$SCRATCH_REPO" commit -qm clean
sha3="$(git -C "$SCRATCH_REPO" rev-parse local)"
printf 'refs/heads/local %s refs/heads/local %s\n' "$sha3" "$sha2" | bash "$HOOK" >/dev/null 2>&1
assert_eq "0" "$?" "F2：范围之外的既有命中不阻断（只扫本次推送范围引入的对象）"

# E6a：远端 sha 在本地不存在（推送目标的提交还没 fetch 下来）时，`remote..local` 这个范围
# 根本不成立 → 扫描器以 2 拒绝 → 钩子必须**阻断**（1），绝不能把"我扫不出来"当成"干净"。
# 这是现实中最常见的误拦，也最容易被"顺手 || true"毁掉，故单独立一条。
ffff="$(printf '%040d' 0 | tr '0' 'f')"
printf 'refs/heads/local %s refs/heads/local %s\n' "$sha3" "$ffff" | bash "$HOOK" >/dev/null 2>&1
assert_eq "1" "$?" "E6a：远端 sha 不可解析时失败关闭（阻断）"

# E6b：F1b 只锁了"放行"侧。这里补"阻断"侧，并且要断得**有理由**：输出必须出现真实命中
# 规则 cred-aws-access-key，而不是"范围解析不了"造成的另一种阻断——两者退出码都是 1，
# 只有看输出才能区分"闸门在钉住的仓库里真的扫到了"和"它其实扫错了地方/扫不动"。
E6B_OUT="$SCRATCH/hook-env-u.txt"
printf 'refs/heads/local %s refs/heads/local %s\n' "$sha2" "$zeros" | env -u SYNC_REPO_ROOT bash "$HOOK" >"$E6B_OUT" 2>&1
assert_eq "1" "$?" "E6b：无 SYNC_REPO_ROOT 的手工 push 环境下同样阻断泄漏"
E6B_HIT="no"
grep -qF 'cred-aws-access-key' "$E6B_OUT" 2>/dev/null && E6B_HIT="yes"
assert_eq "yes" "$E6B_HIT" "E6b：阻断理由是真实命中，不是范围解析失败"

# 非本机制的既有钩子不得被覆盖
rm -f "$HOOK"
printf '#!/bin/sh\nexit 0\n' > "$HOOK"
chmod +x "$HOOK"
# F3 前置：记下被保护文件的 sha256 与字节数，供拒绝之后逐字节比对。
F3_BEFORE="$(shasum -a 256 "$HOOK" | awk '{ print $1 }')"
F3_BYTES="$(wc -c < "$HOOK" | tr -d ' ')"
assert_exit 4 "既有非托管钩子时拒绝安装" -- bash "$INSTALL"
# F3：拒绝不只是"退出 4"——既有钩子必须**一个字节都没被改写**。只比对 head -1 是不够的：
# "先截断/写一半，再报 4"的实现照样能让首行还在而内容已毁，它骗得过旧断言。
assert_eq "$F3_BEFORE" "$(shasum -a 256 "$HOOK" | awk '{ print $1 }')" \
          "F3：拒绝覆盖后既有非托管钩子逐字节未变（sha256）"
assert_eq "$F3_BYTES" "$(wc -c < "$HOOK" | tr -d ' ')" \
          "F3：拒绝覆盖后既有钩子长度未变"
assert_eq "#!/bin/sh" "$(head -1 "$HOOK")" "F3：首行仍是原样"

# E1：钩子目录必须**问 git**，不能写死 .git/hooks。core.hooksPath 一旦被设置（仓库级或
# 全局级），git 只会在那个目录里找钩子；写死路径的安装器会一边打印"已安装"、一边装出
# 一个 git 永不执行的钩子——那是关于"兜底闸门到底存不存在"的假保证，比不装更糟。
# 下面用真实配置 + `git hook run`（git 自己的解析与执行路径；不涉及网络，也不做 push）
# 验证两件事：装到了 git 会看的地方，以及 git 真的会执行它。
git -C "$SCRATCH_REPO" config core.hooksPath .githooks
mkdir -p "$SCRATCH_REPO/.githooks"
E1_HOOK="$SCRATCH_REPO/.githooks/pre-push"
require_in_scratch "$E1_HOOK"
assert_exit 0 "E1：core.hooksPath 指向仓库内目录时安装成功" -- bash "$INSTALL"
E1_MARK="no"
grep -qF '# upstream-sync managed' "$E1_HOOK" 2>/dev/null && E1_MARK="yes"
assert_eq "yes" "$E1_MARK" "E1：钩子装到了 git 解析出的目录（.githooks/）"

# git 解析出来的钩子文件必须就是安装器写下的那一个（两侧都物理化再比，避免 /var 与
# /private/var 这类符号链接前缀造成假不等）。先锁"夹具成立"：git 确实把 hooks 重定向到了
# .githooks/，否则下面几条断言测的就不是 core.hooksPath 场景。
E1_RES_RAW="$(git -C "$SCRATCH_REPO" rev-parse --git-path hooks/pre-push)"
case "$E1_RES_RAW" in
  /*) E1_RES="$E1_RES_RAW" ;;
  *)  E1_RES="$SCRATCH_REPO/$E1_RES_RAW" ;;
esac
E1_WROTE="$(cd "$(dirname "$E1_HOOK")" && pwd -P)/$(basename "$E1_HOOK")"
E1_RES_P="$(cd "$(dirname "$E1_RES")" && pwd -P)/$(basename "$E1_RES")"
assert_eq "$E1_WROTE" "$E1_RES_P" "E1 前置：git 确实把 hooks 解析到 .githooks/（夹具成立）"

# 关键是"git 会执行的那个文件带本机制标记"——这条才会被"安装器写死 .git/hooks"击穿。
E1_TARGET_MARK="no"
[ -f "$E1_RES_P" ] && grep -qF '# upstream-sync managed' "$E1_RES_P" 2>/dev/null && E1_TARGET_MARK="yes"
assert_eq "yes" "$E1_TARGET_MARK" "E1：git 会执行的那个文件就是本机制的钩子"

# 写死路径的旧行为会顺手改写 .git/hooks/pre-push（上面 F3 留的外来钩子）。装对了地方
# 才说明安装器真的按 git 的解析走，而不是"正好 .git/hooks 就是解析结果"。
assert_eq "$F3_BEFORE" "$(shasum -a 256 "$HOOK" | awk '{ print $1 }')" \
          "E1：装到 .githooks/ 时没有顺手改写 .git/hooks/pre-push"

# 让 git 亲自跑一遍：喂进含泄漏的范围，期望它执行我们装的钩子并以 1 阻断。这条必须同时
# 看**退出码**和**输出**：钩子不存在时 `git hook run` 也返回 1（它自己报错），只看退出码
# 会把"git 找不到钩子"误当成"闸门拦住了"。故再断言阻断文案来自本机制。
#
# 注意 `git hook run` **不会**把 stdin 转给钩子（实测：不传 --to-stdin 时我们的钩子读到
# 立即 EOF、直接 rc=0 放行），必须用 --to-stdin 把 ref 清单喂进去。该选项在旧版 git 上
# 不存在（退出码 129）：那种环境下这一节无法验证，故**响亮报失败**而不是静默跳过——
# 静默跳过正是"断言弱于它自己的注释"的那种病。
E1_REFS="$SCRATCH/hook-refs.txt"
printf 'refs/heads/local %s refs/heads/local %s\n' "$sha3" "$zeros" > "$E1_REFS"
git -C "$SCRATCH_REPO" hook run --to-stdin="$E1_REFS" pre-push </dev/null >/dev/null 2>&1
E1_PROBE_RC=$?
E1_UNSUP="yes"
[ "$E1_PROBE_RC" = "129" ] || E1_UNSUP="no"
assert_eq "no" "$E1_UNSUP" \
          "E1 前置：本机 git 支持 hook run --to-stdin（129=不支持；套件本已要求 git ≥2.38）"
E1_RUN_OUT="$SCRATCH/hook-run-out.txt"
git -C "$SCRATCH_REPO" hook run --to-stdin="$E1_REFS" pre-push </dev/null >"$E1_RUN_OUT" 2>&1
assert_eq "1" "$?" "E1：git hook run 执行钩子后以 1 阻断"
E1_RAN="no"
grep -qF 'upstream-sync: 推送被兜底闸门阻断' "$E1_RUN_OUT" 2>/dev/null && E1_RAN="yes"
assert_eq "yes" "$E1_RAN" "E1：阻断文案来自本机制的钩子（不是 git 找不到钩子的报错）"

# 反向：hooksPath 指向仓库**外**（常见于全局共享 hooks 目录）时必须响亮拒绝，而不是
# 装作成功。本钩子把仓库路径与扫描器路径固化在生成物里，装进共享目录会让别的仓库的
# push 也执行它、而且扫的是本仓库——"闸门在、但管错对象"，正是固化那条修复的反面。
# 拒绝是安全侧：闸门没装，但用户立刻知道。
git -C "$SCRATCH_REPO" config core.hooksPath "$SCRATCH/global-hooks"
mkdir -p "$SCRATCH/global-hooks"
require_in_scratch "$SCRATCH/global-hooks/pre-push"
E1_OUT="$(bash "$INSTALL" 2>&1)"; E1_RC=$?
assert_eq "1" "$E1_RC" "E1：hooksPath 指向仓库外目录时响亮拒绝（非零）"
# 光看退出码不知道是哪条分支给的 1；点出理由才算真的测到"仓库外"这条。
E1_WHY="no"
case "$E1_OUT" in *"不在本仓库内"*) E1_WHY="yes" ;; esac
assert_eq "yes" "$E1_WHY" "E1：拒绝理由点名“不在本仓库内”（确实走的是仓库外那条分支）"
# F5a：提示必须**可执行**。仓库外 hooks 目录多半来自全局配置，只说"仓库级 --unset"会让人
# 白跑一趟；文案要同时给出"先查来源"和"全局怎么撤"。
E1_ORIGIN_HINT="no"
case "$E1_OUT" in *"--show-origin"*) E1_ORIGIN_HINT="yes" ;; esac
assert_eq "yes" "$E1_ORIGIN_HINT" "F5a：拒绝文案给出 --show-origin 以查清配置来源"
E1_GLOBAL_HINT="no"
case "$E1_OUT" in *"--global --unset"*) E1_GLOBAL_HINT="yes" ;; esac
assert_eq "yes" "$E1_GLOBAL_HINT" "F5a：拒绝文案给出全局配置的撤销写法（不只仓库级）"
# G1：这条消息**只在 git 把钩子解析到别处时**才可能打印出来。在这种前提下推荐"不动配置、
# 手工把钩子装到 <repo>/.git/hooks/pre-push"是自相矛盾的：core.hooksPath 还指着别处时，
# git 压根不看 .git/hooks——照做的人会得到一个"装了却永远不会跑"的钩子，正是 E1/F1 要
# 消灭的那个状态，却由我们自己的输出推荐出来。故文案必须给出正确顺序（先撤销冲突配置），
# 并明确在此之前手工安装不生效；同时不得再出现那句指引。
E1_ORDER="no"
case "$E1_OUT" in *"撤销之后"*) E1_ORDER="yes" ;; esac
assert_eq "yes" "$E1_ORDER" "G1：文案写明手工安装须在冲突配置撤销之后（顺序前提）"
E1_EFFECTIVE="no"
case "$E1_OUT" in *"才会生效"*) E1_EFFECTIVE="yes" ;; esac
assert_eq "yes" "$E1_EFFECTIVE" "G1：文案明说手工安装在此之前不会生效"
E1_NO_LIE="yes"
case "$E1_OUT" in *"不动配置"*) E1_NO_LIE="no" ;; esac
assert_eq "yes" "$E1_NO_LIE" "G1：不再出现以“不动配置”为前提的手工安装指引（该前提下它无效）"
E1_ABSENT="yes"
[ -e "$SCRATCH/global-hooks/pre-push" ] && E1_ABSENT="no"
assert_eq "yes" "$E1_ABSENT" "E1：拒绝时没有在仓库外目录留下钩子"

# 解析出的目录不存在那条分支必须被**真正执行到**：夹具用仓库内的相对 hooksPath
# （`.githooks-missing` → 解析后落在 $SCRATCH_REPO 内）。旧夹具放的是**仓库外**路径，而
# 仓库外的拒绝排在它之前，于是退出码 1 来自另一条分支、`-d` 这条从未跑过——断言名在说
# 一件没被验证的事，那正是本项目反复要治的病。故这里同时锁"夹具在仓库内""目录确实不存在"
# 与"拒绝理由正是目录不存在"。
git -C "$SCRATCH_REPO" config core.hooksPath .githooks-missing
E1_MISS_RES="$(git -C "$SCRATCH_REPO" rev-parse --git-path hooks/pre-push)"
case "$E1_MISS_RES" in
  /*) E1_MISS_ABS="$E1_MISS_RES" ;;
  *)  E1_MISS_ABS="$SCRATCH_REPO/$E1_MISS_RES" ;;
esac
E1_MISS_IN="no"
case "$E1_MISS_ABS" in
  "$SCRATCH_REPO"/*) E1_MISS_IN="yes" ;;
esac
assert_eq "yes" "$E1_MISS_IN" "E1 前置：不存在的目录夹具解析后仍在仓库内（否则测不到那条分支）"
E1_MISS_ABSENT="no"
[ -d "$E1_MISS_ABS" ] || E1_MISS_ABSENT="yes"
assert_eq "yes" "$E1_MISS_ABSENT" "E1 前置：夹具目录确实不存在"
E1_MISS_OUT="$(bash "$INSTALL" 2>&1)"; E1_MISS_RC=$?
assert_eq "1" "$E1_MISS_RC" "E1：hooksPath 指向不存在的目录时响亮拒绝"
E1_MISS_WHY="no"
case "$E1_MISS_OUT" in *"钩子目录不存在"*) E1_MISS_WHY="yes" ;; esac
assert_eq "yes" "$E1_MISS_WHY" "E1：拒绝理由点名“钩子目录不存在”（确实走的是 -d 那条分支）"
# 收尾：把配置还原，避免夹具把 core.hooksPath 泄漏给后续（本文件内的任何 git 调用）。
git -C "$SCRATCH_REPO" config --unset core.hooksPath
assert_eq "no" "$(git -C "$SCRATCH_REPO" config --get core.hooksPath 2>/dev/null || printf 'no')" \
          "E1：夹具已还原 core.hooksPath（不泄漏给后续断言）"

# F1（E1 同类问题的第二个入口）：解析出的钩子路径**已存在但不是普通文件**（这里是目录）时
# 必须拒绝。`mv tmp "$HOOK"` 在这种情形下会**成功**——临时文件被塞进那个目录（实测
# `<hooks>/pre-push/pre-push.XXXXXX`），脚本照样打印"已安装"，而 git 在钩子路径上看到的
# 仍是目录、什么都不执行。修复前的 `cat >` 在这种情形下会响亮失败，不能让它变哑。
rm -rf "$HOOK"
mkdir -p "$HOOK"
require_in_scratch "$HOOK"
F1_OUT="$(bash "$INSTALL" 2>&1)"; F1_RC=$?
assert_eq "1" "$F1_RC" "F1：钩子路径上是目录时响亮拒绝（非零）"
F1_SAID_SUCCESS="no"
case "$F1_OUT" in *"已安装兜底闸门"*) F1_SAID_SUCCESS="yes" ;; esac
assert_eq "no" "$F1_SAID_SUCCESS" "F1：拒绝时绝不打印成功行（这条就是假保证的判定点）"
F1_WHY="no"
case "$F1_OUT" in *"目录"*) F1_WHY="yes" ;; esac
assert_eq "yes" "$F1_WHY" "F1：拒绝说明点出发现的是目录"
F1_STILL_DIR="no"
[ -d "$HOOK" ] && F1_STILL_DIR="yes"
assert_eq "yes" "$F1_STILL_DIR" "F1：拒绝后该路径仍是目录（没有被 mv 掉、没有半写）"
F1_EMPTY="yes"
for _t in "$HOOK"/*; do
  [ -e "$_t" ] && F1_EMPTY="no"
done
assert_eq "yes" "$F1_EMPTY" "F1：没有把临时文件塞进那个目录（mv 的假成功路径未被走到）"
# G2：F1 自己也要检查**钩子目录**里的临时残留。上面那条只看向"钩子路径"（目录）内部，而
# 先在本目录 mktemp、再去拒绝的实现会在这里留下 pre-push.XXXXXX：它照样退出 1、也不打印
# 成功行，前面五条断言全过。故把"拒绝发生在建临时文件之前"这件事在 F1 的现场独立断言
# （早先那条 E2 残留检查跑在 F1 夹具之前，覆盖不到这条路径）。
F1_RESIDUE="no"
for _t in "$SCRATCH_REPO/.git/hooks"/pre-push.*; do
  [ -e "$_t" ] || continue
  case "$_t" in *.sample) continue ;; esac
  F1_RESIDUE="yes"
done
assert_eq "no" "$F1_RESIDUE" "F1：拒绝发生在建临时文件之前（hooks 目录里没有 pre-push.* 残留）"

# F5b：写入之后"再问一次 git"若**问不出来**（rev-parse 失败），文案必须说"复核失败"，而不是
# 把空值拼成一个看着像路径的东西（旧文案会打出自相矛盾的"git 现在解析出的钩子路径是 <repo>/"）。
# 用 PATH 前置的 git 垫片让第二次 rev-parse 失败（第一次照常成功），从而真实走到该分支——
# 不这样做就只能靠"读代码相信它"，而这条分支恰恰是假保证的最后一道闸。
rm -rf "$HOOK"
F5_SHIM="$SCRATCH/shim"
mkdir -p "$F5_SHIM"
F5_COUNT="$SCRATCH/shim-count.txt"
F5_REAL_GIT="$(command -v git)"
cat > "$F5_SHIM/git" <<SHIM
#!/bin/sh
case "\$*" in
  *"rev-parse --git-path hooks/pre-push"*)
    n=0
    [ -f "$F5_COUNT" ] && n="\$(cat "$F5_COUNT")"
    n=\$((n + 1))
    printf '%s' "\$n" > "$F5_COUNT"
    [ "\$n" -ge 2 ] && exit 128
    ;;
esac
exec "$F5_REAL_GIT" "\$@"
SHIM
chmod 755 "$F5_SHIM/git"
F5_OUT="$(PATH="$F5_SHIM:$PATH" bash "$INSTALL" 2>&1)"; F5_RC=$?
assert_eq "1" "$F5_RC" "F5b：复核问不出 git 的解析结果时以 1 拒绝（不报告成功）"
F5_SAID_SUCCESS="no"
case "$F5_OUT" in *"已安装兜底闸门"*) F5_SAID_SUCCESS="yes" ;; esac
assert_eq "no" "$F5_SAID_SUCCESS" "F5b：复核失败时不打印成功行"
F5_WHY="no"
case "$F5_OUT" in *"复核"*) F5_WHY="yes" ;; esac
assert_eq "yes" "$F5_WHY" "F5b：文案说明是复核失败，而不是给出一个空/荒谬的路径"
F5_SANE="yes"
case "$F5_OUT" in *"现在解析出的钩子路径是"*) F5_SANE="no" ;; esac
assert_eq "yes" "$F5_SANE" "F5b：复核失败时不再渲染那个自相矛盾的钩子路径句子"

# ---------------------------------------------------------------------------
# F6：修复后的范围语义（Task 4b）。钩子交给扫描器的是 `remote..local` 这个范围，而推送会发布
# 该范围内**所有提交可达的对象**：提交 A 加入密钥、提交 B 把文件整个删掉时，右端什么都看不到，
# 密钥却照样会永久进入远端历史。旧扫描器只读右端的内容，在这一形状上静默放行——而"提交、
# 发现、清理、推送"正是人最容易踩的那种泄漏次序，也是 F2 那句"只扫本次推送范围"的反面：
# 范围之**内**先加后删的密钥必须被扫到。
# 为此换一个全新的夹具仓库：本文件上面那个仓库里已经躺着一个泄漏提交，任何范围都会命中，
# 断言会因此失去判别力（它只在"范围内唯一的泄漏就是那份被删掉的 blob"时才有意义）。
# ---------------------------------------------------------------------------
scratch_teardown
scratch_setup
assert_exit 0 "F6 前置：在新夹具仓库里安装兜底闸门" -- bash "$INSTALL"
F6_HOOK="$SCRATCH_REPO/.git/hooks/pre-push"
require_in_scratch "$F6_HOOK"
f6_aws="$(printf 'AK%s' 'IAIOSFODNN7EXAMPLE')"
printf 'key = %s\n' "$f6_aws" > "$SCRATCH_REPO/leak-then-drop.txt"
git -C "$SCRATCH_REPO" add leak-then-drop.txt
git -C "$SCRATCH_REPO" commit -qm "local: 加入密钥"
F6_MID="$(git -C "$SCRATCH_REPO" rev-parse local)"
git -C "$SCRATCH_REPO" rm -q leak-then-drop.txt
git -C "$SCRATCH_REPO" commit -qm "local: 删除该文件"
F6_TIP="$(git -C "$SCRATCH_REPO" rev-parse local)"
# 前置：判别力必须被证明——右端没有这个路径，而中间那次提交里确实有原文（否则下面那条
# 断言会退化成同义反复：即便扫描器什么都没扫，它也会"通过"）。
assert_eq "" "$(git -C "$SCRATCH_REPO" ls-tree -r --name-only "$F6_TIP" -- leak-then-drop.txt)" \
  "F6 前置：右端提交里该文件确实不存在"
F6_MID_RAW="no"
git -C "$SCRATCH_REPO" grep -qF "$f6_aws" "$F6_MID" -- leak-then-drop.txt 2>/dev/null && F6_MID_RAW="yes"
assert_eq "yes" "$F6_MID_RAW" "F6 前置：密钥确实在推送范围里（中间提交的 blob 里有原文）"
F6_OUT="$SCRATCH/hook-range-out.txt"
printf 'refs/heads/local %s refs/heads/local %s\n' "$F6_TIP" "$zeros" | bash "$F6_HOOK" >"$F6_OUT" 2>&1
assert_eq "1" "$?" "F6：范围内加入后又删除的密钥被阻断（修复前放行）"
F6_HIT="no"
grep -qF 'cred-aws-access-key' "$F6_OUT" 2>/dev/null && F6_HIT="yes"
assert_eq "yes" "$F6_HIT" "F6：阻断理由是真实命中，不是范围解析失败"
F6_LEAK="no"
grep -qF "$f6_aws" "$F6_OUT" 2>/dev/null && F6_LEAK="yes"
assert_eq "no" "$F6_LEAK" "F6：阻断输出不回显命中的原文（掩码契约）"

if [ "${TESTS_FAILED:-0}" -gt 0 ]; then
  printf '%s 项断言失败\n' "$TESTS_FAILED"
  exit 1
fi
exit 0
