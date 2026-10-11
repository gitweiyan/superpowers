#!/usr/bin/env bash
# 安装本地兜底闸门（不入库、不推送）。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$HERE/sync-lib.sh"

ROOT="$(sync_repo_root)"
MARKER="# upstream-sync managed"

# 物理化：/var 与 /private/var 这类符号链接前缀不能被当成两个不同的目录，否则下面"是否在
# 仓库内"的判断会假失败。目录不存在时按原样返回（调用方据此判定"这个目录不存在"）。
phys_dir() { # path -> 所在目录的物理绝对路径
  local d
  d="$(dirname "$1")"
  case "$d" in
    /*) : ;;
    *)  d="$ROOT/$d" ;;
  esac
  if [ -d "$d" ]; then ( cd "$d" && pwd -P ); else printf '%s\n' "$d"; fi
}
phys() { printf '%s/%s\n' "$(phys_dir "$1")" "$(basename "$1")"; }

# E1：钩子目录必须**问 git**，不能写死 "$ROOT/.git/hooks"。core.hooksPath 一旦被设置
#（仓库级或全局级），git 只会在那个目录里找钩子；写死路径的安装器会一边打印"已安装"、
# 一边装出一个 git 永不执行的钩子——那是关于"兜底闸门到底存不存在"的假保证，比明说
# "没装"更糟。
#
# 直接要"git 会执行的钩子文件"的路径，而不是先要目录再自己拼：后者在 core.hooksPath 写成
# 尾随斜杠或 "./" 时会出现 `.githooks//pre-push` 这类形式，字符串拼接很容易拼出另一个
# 目录；dirname/basename + 物理化能吃下所有这些写法。
if ! HOOK_RESOLVED="$(git -C "$ROOT" rev-parse --git-path hooks/pre-push 2>/dev/null)"; then
  printf 'REFUSED：%s 不是可用的 git 仓库，无法解析钩子路径。\n' "$ROOT" >&2
  exit 1
fi
HOOKDIR="$(phys_dir "$HOOK_RESOLVED")"
HOOK="$HOOKDIR/$(basename "$HOOK_RESOLVED")"

# 本机制的钩子把"仓库根"与"扫描器路径"固化在生成物里，因此它只属于这一个仓库。装进
# 仓库外的共享 hooks 目录（常见的全局 core.hooksPath）会让别的仓库的 push 也执行它，
# 而且扫的是本仓库——那是"闸门在、但管错对象"，正是固化那条修复的反面。
# 拒绝是安全侧：闸门没装，但用户立刻知道，而不是以为装上了。
case "$HOOKDIR" in
  "$ROOT"/*) : ;;
  *)
    printf 'REFUSED：git 解析出的钩子目录不在本仓库内：%s\n' "$HOOKDIR" >&2
    printf '  本钩子固化了仓库路径与扫描器路径，装到共享目录会替别的仓库执行并扫错仓库。\n' >&2
    printf '  先查清它从哪来：git -C %s config --show-origin core.hooksPath\n' "$ROOT" >&2
    printf '  若来自本仓库：git -C %s config --unset core.hooksPath\n' "$ROOT" >&2
    printf '  若来自全局配置（共享 hooks 目录多半如此）：git config --global --unset core.hooksPath\n' >&2
    # G1：不能说"不动配置、手工装到 <repo>/.git/hooks/pre-push"。这条消息**只可能**在 git
    # 把钩子解析到别处时打印，因此在冲突配置被撤销之前，装到 .git/hooks 的钩子 git 根本不会
    # 执行——照做的人会得到一个"装了却永远不会跑"的钩子，正是本机制要消灭的状态。手工那条路
    # 必须写明顺序前提，否则它就是 F5a 同一类的"看着可行的错误指引"。
    printf '  只有在上面那条冲突配置被撤销之后，手工把钩子放到 %s/.git/hooks/pre-push 才会生效；\n' "$ROOT" >&2
    printf '  在此之前那样装是没用的：git 不会去 .git/hooks 找钩子。\n' >&2
    exit 1 ;;
esac

if [ ! -d "$HOOKDIR" ]; then
  printf 'REFUSED：git 解析出的钩子目录不存在：%s（git 在那里找不到任何钩子，装进去等于没装）。\n' "$HOOKDIR" >&2
  exit 1
fi

# F1：解析出的钩子路径若**已存在但不是普通文件**（典型：同名目录），必须拒绝。
# `mv tmp "$HOOK"` 在 $HOOK 是目录时**会成功**——临时文件被塞进那个目录，脚本照样打印
# "已安装"，而 git 在钩子路径上看到的仍是目录、什么都不执行。这是 E1 的第二个入口，
# 同一类"自称装了、其实没装"的假保证（修复前的 `cat >` 在这种情形下会响亮失败，不能让它变哑）。
if { [ -e "$HOOK" ] || [ -L "$HOOK" ]; } && [ ! -f "$HOOK" ]; then
  KIND="既不是普通文件也不是目录"
  if [ -d "$HOOK" ]; then KIND="目录"; fi
  if [ -L "$HOOK" ]; then KIND="符号链接（且不指向普通文件）"; fi
  if [ -p "$HOOK" ]; then KIND="命名管道"; fi
  printf 'REFUSED：git 解析出的钩子路径 %s 已存在，但它是%s（不是普通文件）。\n' "$HOOK" "$KIND" >&2
  printf '  git 会在那个路径上找钩子，目录或这类特殊文件不会被执行——拒绝在此报告成功。\n' >&2
  printf '  请先人工清理该路径（常见成因：被误建的目录，或漏了 /pre-push 的路径被当成钩子文件）。\n' >&2
  exit 1
fi

if [ -f "$HOOK" ] && ! grep -qF "$MARKER" "$HOOK"; then
  printf 'REFUSED：%s 已存在且非本机制管理，拒绝覆盖。请人工处理。\n' "$HOOK" >&2
  exit 4
fi

# E2：先在同目录写临时文件、chmod、再 mv 到位。直接 `cat > "$HOOK"` 是"先截断、再填"：
# 若此刻被打断（磁盘满、进程被杀、Ctrl-C），留下的钩子可能连扫描循环都没有、rc 仍是 0——
# 一个静默放行的空壳，而且看上去"装过了"。同目录 mv 是原子的：读者要么看到旧内容、要么
# 看到新内容，不存在"半个钩子"。
TMP_HOOK="$(mktemp "$HOOKDIR/pre-push.XXXXXX")" || {
  printf 'REFUSED：无法在 %s 建临时文件，拒绝安装（既有钩子未改动）。\n' "$HOOKDIR" >&2
  exit 1
}
trap 'rm -f "$TMP_HOOK"' EXIT INT TERM

# 注意：heredoc 用 <<EOF（**不引号**）以便展开 $HERE，因此脚本内所有本应延迟展开的变量
# 都写成 \$var。
#
# E3：扫描器调用显式 `</dev/null`。钩子的 stdin 是 git 交上来的"待推送 ref 清单"（多行，
# 一行一个 ref）；若扫描器将来（或它调用的 git 包装/钩子链）去读裸 stdin，就会把剩下的
# ref 行吃掉，多 ref 的 push 只扫第一行——静默的部分扫描，比不扫更危险。
cat > "$TMP_HOOK" <<EOF
#!/usr/bin/env bash
$MARKER
set -uo pipefail
export SYNC_REPO_ROOT="$ROOT"
SCAN="$HERE/scan-sensitive.sh"
rc=0
while read -r local_ref local_sha remote_ref remote_sha; do
  [ -n "\${local_sha:-}" ] || continue
  case "\$local_sha" in *[!0]*) : ;; *) continue ;; esac
  case "\$remote_sha" in
    0000000000000000000000000000000000000000|"") range="main..\$local_sha" ;;
    *) range="\$remote_sha..\$local_sha" ;;
  esac
  if ! "\$SCAN" --range "\$range" </dev/null; then
    printf 'upstream-sync: 推送被兜底闸门阻断（范围 %s）\\n' "\$range" >&2
    rc=1
  fi
done
exit \$rc
EOF
# chmod 755 而不是 +x：mktemp 建出来的文件是 600，`chmod +x` 只会得到 711，而且它随 umask
# 漂移。写死 755 让落位后的权限与 umask 无关，也与 `git init` 放进 .git/hooks 的样例钩子
# 一致。（钩子若不可执行，git 会直接跳过它——那正是 E1/E2 要防的"装了个不会跑的钩子"。）
chmod 755 "$TMP_HOOK"
mv "$TMP_HOOK" "$HOOK"
trap - EXIT INT TERM

# E1（后半）：写完之后**再问一次 git**——"git 会执行的那个文件"必须就是我刚写下的这一个。
# 中途被人改了 core.hooksPath 这类竞态宁可报错，也不留下"到底装没装"的模糊状态。
# F5b：复核**问不出来**（rev-parse 失败）与"问出来了但不是同一个路径"是两件事，必须分开说。
# 旧写法把两种情况混在一条消息里，失败时会把空值拼成一个看着像路径的东西——旧文案会打出
# 自相矛盾的"git 现在解析出的钩子路径是 <仓库根>/"，读者只会更糊涂。
RECHECK_RAW="$(git -C "$ROOT" rev-parse --git-path hooks/pre-push 2>/dev/null)" || RECHECK_RAW=""
if [ -z "$RECHECK_RAW" ]; then
  printf 'REFUSED：已写入 %s，但复核失败——无法从 git 解析出钩子路径（rev-parse 未成功），拒绝报告成功。\n' \
    "$(phys "$HOOK")" >&2
  exit 1
fi
if [ "$(phys "$HOOK")" != "$(phys "$RECHECK_RAW")" ]; then
  printf 'REFUSED：已写入 %s，但 git 现在解析出的钩子路径是 %s（两者不一致，拒绝报告成功）。\n' \
    "$(phys "$HOOK")" "$(phys "$RECHECK_RAW")" >&2
  exit 1
fi

printf '已安装兜底闸门：%s\n' "$HOOK"
