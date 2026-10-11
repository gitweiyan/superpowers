#!/usr/bin/env bash
# 断言 + 临时三处仓库（upstream/origin/工作仓库）构造器。
# 注意：本文件的内容卫生——所有邮箱、密钥类字面量一律运行时拼接。

TESTS_FAILED="${TESTS_FAILED:-0}"

assert_eq() { # want got desc
  if [ "$1" = "$2" ]; then
    printf 'ok   %s\n' "$3"
  else
    printf 'FAIL %s\n     want: %s\n     got : %s\n' "$3" "$1" "$2"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_exit() { # want desc -- cmd...
  local want="$1" desc="$2"
  shift 3
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  assert_eq "$want" "$rc" "$desc"
}

scratch_setup() {
  # pwd -P 归一化：mktemp -d 给出 /var/…（逻辑路径），而 sync_repo_root 用
  # cd … && pwd -P 给出 /private/var/…（物理路径）；不归一化会让后续任务里
  # 任何路径相等断言都假失败。所有 SCRATCH_* 都从归一化后的值派生。
  SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
  SCRATCH_SEED="$SCRATCH/seed"
  SCRATCH_UPSTREAM="$SCRATCH/upstream.git"
  SCRATCH_ORIGIN="$SCRATCH/origin.git"
  SCRATCH_REPO="$SCRATCH/repo"
  # 片段拼接：测试文件自身必须能通过扫描器，故不出现完整邮箱字面量
  SCRATCH_USER="tester"
  SCRATCH_DOMAIN="example.invalid"
  export SCRATCH_USER SCRATCH_DOMAIN
  local user="$SCRATCH_USER"
  local domain="$SCRATCH_DOMAIN"

  git init -q -b main "$SCRATCH_SEED"
  git -C "$SCRATCH_SEED" config user.name "$user"
  git -C "$SCRATCH_SEED" config user.email "$user@$domain"
  mkdir -p "$SCRATCH_SEED/skills/alpha"
  {
    printf -- '---\n'
    printf 'name: alpha\n'
    printf 'description: 测试用技能\n'
    printf -- '---\n\n# alpha\n'
  } > "$SCRATCH_SEED/skills/alpha/SKILL.md"
  printf 'base\n' > "$SCRATCH_SEED/README.md"
  git -C "$SCRATCH_SEED" add -A
  git -C "$SCRATCH_SEED" commit -qm seed

  git clone -q --bare "$SCRATCH_SEED" "$SCRATCH_UPSTREAM"
  git clone -q --bare "$SCRATCH_SEED" "$SCRATCH_ORIGIN"
  # 拓扑契约（A）：工作仓库从 fork 克隆，故 origin = 用户的 fork；upstream = 上游本尊。
  # 二者必须是不同的仓库，否则"fork 与 upstream 不同"的场景无法构造。
  git clone -q "$SCRATCH_ORIGIN" "$SCRATCH_REPO"
  git -C "$SCRATCH_REPO" config user.name "$user"
  git -C "$SCRATCH_REPO" config user.email "$user@$domain"
  git -C "$SCRATCH_REPO" remote add upstream "$SCRATCH_UPSTREAM"
  git -C "$SCRATCH_REPO" remote set-url --push upstream DISABLED-no-push
  git -C "$SCRATCH_REPO" switch -qc local

  SYNC_REPO_ROOT="$SCRATCH_REPO"
  export SYNC_REPO_ROOT
  SYNC_SELFTEST_CMD="true"
  export SYNC_SELFTEST_CMD
}

scratch_teardown() {
  [ -n "${SCRATCH:-}" ] && rm -rf "$SCRATCH"
  # D：不要把 fixture 的环境泄漏到后续断言或同文件里的子进程。
  unset SYNC_SELFTEST_CMD SYNC_REPO_ROOT
  return 0
}
