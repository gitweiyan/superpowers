#!/usr/bin/env bash
# upstream-sync 共用库。只 source，不直接执行。目标：bash 3.2 兼容。

SYNC_LOCAL_BRANCH="local"
SYNC_MIRROR_BRANCH="main"
SYNC_UPSTREAM_REMOTE="upstream"
SYNC_ORIGIN_REMOTE="origin"
SYNC_STATE_DIR=".sync"
SYNC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

sync_repo_root() {
  if [ -n "${SYNC_REPO_ROOT:-}" ]; then
    ( cd "$SYNC_REPO_ROOT" && pwd -P )
  else
    ( cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P )
  fi
}

sync_git() { git -C "$(sync_repo_root)" "$@"; }

sync_die() { printf 'upstream-sync: %s\n' "$*" >&2; exit 1; }

sync_branch() { sync_git rev-parse --abbrev-ref HEAD; }

sync_require_local_branch() {
  local b
  b="$(sync_branch)"
  if [ "$b" != "$SYNC_LOCAL_BRANCH" ]; then
    # 注意：bash 3.2 在 UTF-8 locale 下不会在多字节字符前结束变量名，
    # 裸变量紧跟全角逗号会被解析成另一个变量名，故此处必须写成 ${b}。
    sync_die "当前分支为 ${b}，必须在 $SYNC_LOCAL_BRANCH 上操作"
  fi
}

sync_ref_exists() { sync_git rev-parse --verify --quiet "$1" >/dev/null 2>&1; }

sync_untracked_skills() {
  # -c core.quotePath=false 是功能必需，不只是可移植性：默认 quotePath=true 时 git 把
  # 非 ASCII 名字输出成 "skills/\346…/" 的 C 转义形式，下面的 sed 过滤一条也匹配不到，
  # 清单直接为空。而这份清单正是 plan 报告"游离技能"、apply --adopt 迭代采纳的来源，
  # 于是非 ASCII 命名的技能目录在本机会被静默漏掉。
  sync_git -c core.quotePath=false ls-files --others --exclude-standard --directory -- skills/ 2>/dev/null \
    | sed -n 's|^skills/\([^/]*\)/$|\1|p' | LC_ALL=C sort -u
}

sync_non_added_paths() {
  # 同上：路径要按字节输出，否则非 ASCII 路径在这里变成引号转义形式，I2 诊断不可读。
  sync_git -c core.quotePath=false diff --name-status "$SYNC_MIRROR_BRANCH...$SYNC_LOCAL_BRANCH" \
    | awk '$1 != "A" { print $1 " " $2 }'
}

sync_conflict_preflight() {
  # --no-messages：否则 git 的 "Auto-merging …"/"CONFLICT …" 提示会混进 stdout
  #（它们是 stdout 流，2>/dev/null 挡不住），破坏"每行一个冲突路径"的契约。
  # || true：有冲突时 merge-tree 退出码为 1，调用方带 set -e，不能让它中断本函数。
  # -c core.quotePath=false：本函数的输出是 conflicts= 这一项哈希输入，非 ASCII 冲突
  # 路径若被转义，同一状态会因配置不同而哈希不同。
  local out
  out="$(sync_git -c core.quotePath=false merge-tree --write-tree --name-only --no-messages "$SYNC_MIRROR_BRANCH" "$SYNC_LOCAL_BRANCH" 2>/dev/null)" || true
  printf '%s\n' "$out" | sed '1d' | sed '/^$/d' | LC_ALL=C sort
}

sync_status_porcelain() {
  # -c 覆盖调用者的 git 配置：全局 status.showUntrackedFiles=no 会让 porcelain 丢掉
  # 全部未跟踪项、core.quotePath=true 会改写非 ASCII 路径，两者都会让同一仓库在
  # 另一台机器上哈希不同（前者甚至看不见 apply 的目标）。plan 与 apply 必须共用
  # 这个"什么叫脏"的唯一定义，故 Task 5/6 也走这里。
  sync_git -c core.quotePath=false -c status.showUntrackedFiles=all status --porcelain=v1
}

sync_state_hash() {
  local mirror local_sha untracked conflicts
  mirror="$(sync_git rev-parse "$SYNC_MIRROR_BRANCH" 2>/dev/null || printf 'none')"
  local_sha="$(sync_git rev-parse "$SYNC_LOCAL_BRANCH" 2>/dev/null || printf 'none')"
  untracked="$(sync_untracked_skills | tr '\n' ',')"
  conflicts="$(sync_conflict_preflight | tr '\n' ',')"
  {
    printf 'branch=%s\n' "$(sync_branch)"
    printf 'mirror=%s\n' "$mirror"
    printf 'local=%s\n' "$local_sha"
    printf 'untracked_skills=%s\n' "$untracked"
    printf 'conflicts=%s\n' "$conflicts"
    # 上行的 untracked_skills= 只是目录集合；apply 采纳的是目录里的内容，故这里再对
    # 每个未跟踪文件算一次 blob 摘要。ls-files --others 不能带 --directory（--directory
    # 会把目录折叠成一行，这正是此前"改内容哈希不变"的根因）；hash-object 只算摘要，
    # 不写对象库、不动索引。--no-filters：只给路径时 hash-object 会走 attributes/convert
    # 链，core.autocrlf=true（或 .gitattributes）会把 CRLF 改写成 LF，于是同一份字节在
    # 两台机器上摘要不同；批准凭证必须绑定文件字节，而不是检查这台机器配置了什么。
    # 这里的 ls-files 同样带 -c core.quotePath=false：否则非 ASCII 文件名会被输出成
    # 带转义的引号形式，hash-object 取不到该路径而退化成 unhashable，内容变化即不可见。
    printf 'untracked_files_begin\n'
    sync_git -c core.quotePath=false ls-files --others --exclude-standard -- skills/ 2>/dev/null \
      | LC_ALL=C sort \
      | while IFS= read -r f; do
          printf '%s %s\n' "$(sync_git hash-object --no-filters -- "$f" 2>/dev/null || printf 'unhashable')" "$f"
        done
    printf 'untracked_files_end\n'
    printf 'status_begin\n'
    sync_status_porcelain | LC_ALL=C sort
    printf 'status_end\n'
    # 敏感信息扫描结果同样是"被批准的状态"的一部分：审查者批准的是"推送这批内容"，
    # 而计划凭证必须绑定到"这批内容扫过一遍、结果是这些"，光靠 local= 的提交 sha 看不出来。
    #
    # 但要准确：进哈希的**只有扫描器的 stdout**（下面那行把 stderr 丢掉、失败也被 `|| true` 吞掉），
    # 因此**规则表不是哈希输入**——把规则表改空、改成不可读，或新增一条"这次不会命中任何东西"的
    # 规则，哈希都不变（后果是扫描器变成"不可用"，由 apply 的复检处以 5 拦下，而不是靠哈希）。
    # 反过来，只要扫描结果本身变了（新命中出现在 stdout 上），凭证就失效。
    # 不要以为"改了规则表所以凭证一定失效"——这条区分是安全模型的一部分。
    #
    # 扫描器路径用 SYNC_SCRIPT_DIR：测试在临时仓库里跑本库，机制脚本不在那个仓库里，
    # 用 sync_repo_root 会指向不存在的路径，扫描块就静默变成空输出。
    printf 'scan_begin\n'
    "$SYNC_SCRIPT_DIR/scan-sensitive.sh" \
      --range "$SYNC_MIRROR_BRANCH...$SYNC_LOCAL_BRANCH" 2>/dev/null || true
    printf 'scan_end\n'
  } | shasum -a 256 | awk '{ print $1 }'
}
