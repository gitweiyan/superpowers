# upstream-sync 机制实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建成一套可重复执行的机制，使 fork（`origin`）能在人工审批后接取 upstream 更新，并把本地新增技能可靠地推入代码库，全程由敏感信息闸门把守。

**Architecture:** 三个位置一条单向流：`upstream`（只读镜像来源）→ 本地 `main`（纯净镜像 ref，永不 checkout）→ 本地 `local`（永久 checkout 的工作分支，含纯新增）→ `~/.dsh/skills`（指向本仓库 `skills/` 的符号链接）。机制本体是一个自包含技能包 `skills/upstream-sync/`，提供 plan（只读、出报告与 `PLAN_ID`）与 apply（需匹配的 `PLAN_ID` 才落地）两个入口，外加一个本地 pre-push 兜底闸门。

**Tech Stack:** bash 3.2（macOS 自带，无 homebrew bash）、BSD grep/sed/awk、git 2.50（`merge-tree --write-tree`）、`shasum -a 256`、Node（仅用于调用仓库既有自检脚本）。

**Spec:** `docs/local/specs/2026-10-10-superpowers-sync-design.md`

## Global Constraints

以下约束适用于**每一个**任务，不再逐条重复：

1. **bash 3.2 兼容**：不得使用关联数组、`mapfile`/`readarray`、`${var^^}`/`${var,,}`、`read -d ''`、`&>`。数组可用（索引数组）。所有脚本以 `#!/usr/bin/env bash` 开头并 `set -euo pipefail`。
2. **BSD 工具链**：不得使用 GNU-only 参数（如 `grep -P`、`sed -i` 无备份后缀、`cat -A`、`date -d`）。可用：`grep -inE`、`grep -oE`、`sed -E`、`awk`、`shasum -a 256`、`mktemp -d`、`cd … && pwd -P`（**不用** `readlink -f`）。
3. **分支纪律**：除 Task 1 外，所有工作都在 `local` 分支进行；**永不 checkout `main`、永不提交到 `main`、永不 `git push origin main`**。
4. **纯新增**：只创建新文件；不修改 upstream 拥有的任何文件。`git diff --name-status main...local` 必须全为 `A`。
5. **被推送内容的卫生**：任何会被提交的文件里**不得出现**绝对家目录路径（形如 `/Users/<name>/…` 或 `/home/<name>/…`）、真实邮箱地址、内网 IP、`host:port` 形式的本地端点、凭据字面量。路径一律写 `~/…` 或 `<repo>`；身份邮箱只以"全局 git 身份邮箱"指代，**不打印其字面值**。
6. **自净规则**：机制自身的文件（含本计划、spec、测试）必须能通过 `scan-sensitive.sh`。因此扫描规则正则必须写成不自匹配的形式；测试夹具里的假密钥/假邮箱必须在**运行时用片段拼接**构造，不得以完整字面量出现。
7. **退出码契约**（`plan.sh` / `apply.sh` 共用）：`0` 成功；`1` 运行错误；`2` 用法错误或 plan 检出问题（不变量违规 / 敏感信息命中 / 无 `PLAN_ID`）；`3` `PLAN_ID` 不匹配；`4` 工作区不干净；`5` 敏感信息复检命中；`6` 仓库自检失败；`7` 冲突预演非空。
8. **一次性收敛的 M6 步骤（改运行时根）只能由人执行**；实施者必须通过界面弹框把可直接粘贴的命令交给用户，并等待用户反馈结果，不得自行提权执行。
9. **不推送直到 Task 12**：Task 2–11 只在本地产提交；首次 `git push` 在 Task 12 由用户确认后执行。
10. **自检的可用性**：本机**未安装 ShellCheck**，因此 `scripts/lint-shell.sh` 只能作为条件闸门（`command -v shellcheck` 成功且确有 shell 改动时才追加）；`tests/writing-skills/test-render-graphs.sh` 与 `tests/opencode/test-skill-registration.mjs` 依赖 `node`，本机可用，是默认自检。
11. **测试可信度（fix round 2 加入，Task 4 起每个 test 文件照抄）**：每个 `test-*.sh` 在 source 断言库后**必须自检 harness**，缺失即 `exit 2`：
    ```bash
    command -v assert_eq >/dev/null 2>&1 || { printf 'harness missing: lib-assert.sh did not load\n' >&2; exit 2; }
    ```
    否则 harness 加载失败时断言静默变成空操作，"测试通过"是假的。`run-tests.sh` 在**零个测试文件**命中时必须非零退出（不能用空 glob 的偶然行为当成功）；失败一律 `exit 1`，`2` 只留给零测试文件（避免与全局退出码契约相撞）。
    另外，**凡 source 了 `sync-lib.sh` 的测试文件，必须同样自检该库可用**（如 `command -v sync_git >/dev/null 2>&1 || { printf 'sync-lib missing\n' >&2; exit 2; }`）。原因：库加载失败时两侧同时为空，`assert_eq "" "$(sync_non_added_paths)"` 这类断言会**成对为空而恒真** —— 这是 fix round 3 遗留、由 Task 4 起的模板统一关闭的洞。
12. **`set -e` 与 `$()` 的交互（实测，勿"优化"）**：bash 3.2 在**赋值里的命令替换**上下文中**不**执行 `set -e`（实测：直接调用 `f` → rc 1 且中断；`x="$(f)"` → rc 0 且跑完）。因此：
    - 调用 `sync_conflict_preflight` 时**保持** `CONFLICTS="$(sync_conflict_preflight)"` 这一形态；**不要**改写成裸调用、裸管道或重定向形态（那会因 merge-tree 的退出码 1 而中断并丢失全部输出）。
    - 库内部对可能非零退出的 git 调用仍必须保留 `|| true` 一类的保护，以同时兼顾直接调用形态与更新版 bash 的行为。
13. **git 版本下限**：机制依赖 `git merge-tree --write-tree`（≥2.38）与 `--no-messages`；本机为 2.50.1。

### 测试文件标准尾部（Task 3 起强制，Task 2 已落地版本记为一处 deferred minor）

**每个 `test-*.sh` 必须以下面的尾部结束**，不得省略：

```bash
if [ "${TESTS_FAILED:-0}" -gt 0 ]; then
  printf '%s 项断言失败\n' "$TESTS_FAILED"
  exit 1
fi
exit 0
```

原因（**实测的静默失效**）：本计划的 test 文件若以 `assert_eq` 结尾，则**失败时也以 0 退出** —— `assert_eq` 打印后只在失败分支里自增计数，函数始终返回 0；而 `run-tests.sh` 靠子进程退出码判定通过与否，于是失败会被计为通过，`全部测试通过` 成为假话。同时**不要**用 `exit "$TESTS_FAILED"`（失败计数当退出码）：计数 2/3/4/5/6/7 会与全局退出码契约（2=用法/计划问题、3=凭证不匹配、4=工作区脏、5=敏感信息、6=自检失败、7=冲突）相撞，直接调用单个测试文件时会被误读。

Task 2 已落地的 `test-invariants.sh` 结尾是 `exit "$TESTS_FAILED"`：**功能正确**（失败必非零退出），仅退出码语义与契约冲突 —— 记为 deferred minor，交最终整支 review 决定是否统一；Task 3 起一律采用上面的标准尾部。

## Spec 覆盖映射

实施任务相对 spec 的一次性收敛步骤是**交错**的（先建工具，再用工具收口 M4），对应关系如下：

| spec 要求 | 落在哪个任务 |
|---|---|
| M1 补历史 + 接入 upstream + 禁用 push | Task 1 |
| M2 切 `local` | Task 1 |
| M3 净化并迁入自建技能 | Task 9 |
| M4 在 `local` 上提交机制 / 技能 / 文档 | Task 2–11（每任务一提交，Task 11 收口验证） |
| M5 安装兜底闸门 | Task 7 |
| M6 替换运行时根（由人执行） | Task 12 Step 1–2 |
| M7 复核 + 删旧克隆 | Task 12 Step 3–5 |
| I1 镜像不变量 | Task 1 Step 3、Task 11 Step 3 |
| I2 纯新增不变量 | Task 2（`sync_non_added_paths`）、Task 11 Step 4 |
| I3 无敏感信息 | Task 4（扫描器）、Task 5（G1）、Task 6（G2/G3 + 身份报告）、Task 7（兜底） |
| §5 plan/apply 契约与 `PLAN_ID` | Task 3、Task 5、Task 6 |
| §6 白名单与 `.sync/` 排除 | Task 4（白名单）、Task 5（`.git/info/exclude`） |
| §6 提交身份报告 | Task 6（`将推送的提交身份`） |
| §7 硬规则 / §8 回滚手册 | Task 8 |
| §9 验证清单 9 项 | Task 11 Step 1–6、Task 12 Step 3–4 |
| §10 D8–D11 | D8 无需动作；D9 → Task 7；D10 → Task 12 Step 5；D11 → Task 9 |

---

## File Structure

**新建（机制本体，全部属于纯新增）：**

| 路径 | 职责 |
|---|---|
| `skills/upstream-sync/SKILL.md` | 技能入口：何时触发、两个闭环怎么用、硬规则指向 |
| `skills/upstream-sync/scripts/sync-lib.sh` | 共用库：常量、仓库根解析、分支守卫、状态哈希、不变量、冲突预演、游离技能 |
| `skills/upstream-sync/scripts/patterns.tsv` | 敏感信息规则表：`id`、`kind`、正则、说明 |
| `skills/upstream-sync/scripts/scan-sensitive.sh` | 扫描器（G1/G2/G3 共用） |
| `skills/upstream-sync/scripts/plan.sh` | 只读计划：fetch、报告、`PLAN_ID`、`.sync/plan.json` |
| `skills/upstream-sync/scripts/apply.sh` | 落地：审批门、adopt、merge、自检、复检、push |
| `skills/upstream-sync/scripts/install-pre-push.sh` | 安装本地兜底闸门（幂等） |
| `skills/upstream-sync/references/hard-rules.md` | 硬规则全文（spec §7 的可执行摘录） |
| `skills/upstream-sync/references/recovery.md` | 失败与回滚手册（spec §8） |
| `tests/upstream-sync/run-tests.sh` | 测试入口 |
| `tests/upstream-sync/lib-assert.sh` | 断言与临时仓库构造器 |
| `tests/upstream-sync/test-scanner.sh` | 扫描器行为与自净 |
| `tests/upstream-sync/test-invariants.sh` | I1/I2 |
| `tests/upstream-sync/test-plan-id.sh` | `PLAN_ID` 稳定性与敏感性 |
| `tests/upstream-sync/test-apply-gate.sh` | apply 的四条拒绝路径与成功路径 |
| `tests/upstream-sync/test-hook.sh` | 兜底闸门行为 |

**修改（仅在 Task 3 之后、属于"净化"性质，不触碰 upstream 文件）：**

| 路径 | 变更 |
|---|---|
| `docs/local/specs/2026-10-10-superpowers-sync-design.md` | 净化：绝对家目录路径 → `~/…`；删除身份邮箱与本地端点字面值 |
| `~/.dsh/skills/writing-run-retrospectives/` → `skills/writing-run-retrospectives/` | 迁入 + 净化（Task 10） |

**不创建**：任何 `.gitignore` 改动（`.sync/` 走 `.git/info/exclude`）。

---

### Task 1: 仓库收敛到 local 分支（M1 + M2）

**Files:**
- 无文件改动（仅 git 状态）

**Interfaces:**
- Produces: 本地分支 `local`、remote `upstream`（push 已禁用）、完整的非浅历史 —— 后续所有任务的前提。

- [ ] **Step 1: 补全浅克隆历史**

Run:
```bash
cd ~/Documents/code/superpowers
git fetch --unshallow origin
git rev-list --count HEAD
```
Expected: 命令成功；提交数远大于 1（不再是 1）。若 `--unshallow origin` 失败，改用：
```bash
git remote add upstream https://github.com/obra/superpowers.git
git fetch --unshallow upstream
```

- [ ] **Step 2: 接入 upstream 并物理禁用推送**

Run:
```bash
cd ~/Documents/code/superpowers
git remote add upstream https://github.com/obra/superpowers.git
git remote set-url --push upstream DISABLED-no-push
git fetch upstream
```
Expected: `git remote get-url --push upstream` 输出 `DISABLED-no-push`；`git rev-parse upstream/main` 成功。

**不要在这里执行 `git fetch upstream main:main`** —— git **拒绝把 ref 更新到当前已检出的分支**（会报 `refusing to fetch into branch 'refs/heads/main' checked out at ...`）。镜像 ref 的更新必须发生在 Step 4 切到 `local` 之后（见 Step 4b）。

- [ ] **Step 3: 验证 I1（镜像不变量）**

Run:
```bash
cd ~/Documents/code/superpowers
git rev-parse main
git rev-parse upstream/main
```
Expected: 两个 SHA 相同。

（活体交叉校验 —— 需要网络，当前环境可能不通，不通时标注为"跳过"而不是失败：）
```bash
git ls-remote https://github.com/obra/superpowers.git refs/heads/main | awk '{print $1}'
```

- [ ] **Step 4: 建立并切到 local 分支**

Run:
```bash
cd ~/Documents/code/superpowers
git switch -c local
git branch --show-current
```
Expected: 输出 `local`。

- [ ] **Step 4b: 现在才更新镜像 ref（此时 `main` 已不再被检出）**

Run:
```bash
cd ~/Documents/code/superpowers
git fetch upstream main:main
git rev-parse main upstream/main
```
Expected: 两条命令成功；两个 SHA 相同。

**若网络不通**：该命令失败或挂起时不要空等 —— 先确认 `git rev-parse main` 与 `git rev-parse upstream/main` 已相等（相等则本次 fetch 是 no-op），记录"跳过"并继续。镜像 ref 的更新路径会在首次真实同步（`plan.sh`）时被验证。

- [ ] **Step 5: 验证 merge-base 现在可用（浅克隆已修复）**

Run:
```bash
cd ~/Documents/code/superpowers
git merge-base --is-ancestor main HEAD && echo MIRROR_IS_ANCESTOR
```
Expected: 输出 `MIRROR_IS_ANCESTOR`（若仍无共同祖先会失败——说明 unshallow 未成功，回到 Step 1）。

- [ ] **Step 6: 无需提交**（本任务不产生文件改动）

---

### Task 2: 共用库与测试骨架

**Files:**
- Create: `skills/upstream-sync/scripts/sync-lib.sh`
- Create: `tests/upstream-sync/lib-assert.sh`
- Create: `tests/upstream-sync/test-invariants.sh`
- Create: `tests/upstream-sync/run-tests.sh`

**Interfaces:**
- Produces（后续所有任务依赖，签名固定）：
  - 常量 `SYNC_LOCAL_BRANCH` / `SYNC_MIRROR_BRANCH` / `SYNC_UPSTREAM_REMOTE` / `SYNC_ORIGIN_REMOTE` / `SYNC_STATE_DIR`
  - `sync_repo_root` → 仓库根绝对路径（尊重环境变量 `SYNC_REPO_ROOT`）
  - `sync_git <args…>` → 在该仓库执行 git
  - `sync_die <msg>` → 打印 `upstream-sync: <msg>` 到 stderr 并 `exit 1`
  - `sync_branch` → 当前分支名
  - `sync_require_local_branch` → 非 `local` 则 `sync_die`
  - `sync_ref_exists <rev>` → 存在返回 0
  - `sync_untracked_skills` → `skills/` 下未跟踪目录名，每行一个
  - `sync_non_added_paths` → `<status> <path>` 行（I2 违规）
  - `sync_conflict_preflight` → 冲突路径每行一个（空=无冲突）；**只输出路径**，不输出 git 的提示行（靠 `--no-messages`）
  - `tests/upstream-sync/lib-assert.sh` 提供 `assert_eq <want> <got> <desc>`、`assert_exit <want> <desc> -- <cmd…>`、`scratch_setup`、`scratch_teardown`、全局失败计数 `TESTS_FAILED`。`scratch_setup` 必须把 `SCRATCH` 规范化为 `pwd -P` 形式（macOS 上 `/var/…` 与 `/private/var/…` 是同一目录的两个名字，会让路径相等断言假失败，而 `sync_repo_root` 返回的是 `-P` 形式）

- [ ] **Step 1: 写失败测试（I1/I2 在真实仓库成立）**

创建 `tests/upstream-sync/test-invariants.sh`：
```bash
#!/usr/bin/env bash
set -uo pipefail
TESTS_FAILED=0
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib-assert.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export SYNC_REPO_ROOT="$REPO"
. "$REPO/skills/upstream-sync/scripts/sync-lib.sh"

assert_eq "local" "$(sync_branch)" "I1 前提：当前分支为 local"
# 先断言镜像引用**存在**，再比较 —— 否则引用缺失时会退化成"main 与 main 比较"而恒真
assert_eq "yes" "$(sync_ref_exists "$SYNC_UPSTREAM_REMOTE/main" && printf 'yes' || printf 'no')" \
          "I1 前提：upstream/main 引用存在"
assert_eq "$(sync_git rev-parse main)" \
          "$(sync_git rev-parse "$SYNC_UPSTREAM_REMOTE/main")" \
          "I1：main 是 upstream 镜像（无非空回退）"
assert_eq "" "$(sync_non_added_paths)" "I2：相对 main 全部为新增"

exit "$TESTS_FAILED"
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash tests/upstream-sync/test-invariants.sh`
Expected: FAIL —— 报 `. ` 找不到 `skills/upstream-sync/scripts/sync-lib.sh`（文件尚不存在）。

- [ ] **Step 3: 写断言与临时仓库构造器**

创建 `tests/upstream-sync/lib-assert.sh`：
```bash
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
  SCRATCH="$(mktemp -d)"
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
  git clone -q "$SCRATCH_ORIGIN" "$SCRATCH_REPO"   # origin = fork（**不是** upstream）
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
  # 归还环境，避免夹具把 SYNC_* 泄漏给同一文件里的后续断言或子进程
  unset SYNC_SELFTEST_CMD SYNC_REPO_ROOT
  return 0
}
```

- [ ] **Step 4: 写共用库**

创建 `skills/upstream-sync/scripts/sync-lib.sh`：
```bash
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
    sync_die "当前分支为 ${b}，必须在 $SYNC_LOCAL_BRANCH 上操作"
  fi
}

sync_ref_exists() { sync_git rev-parse --verify --quiet "$1" >/dev/null 2>&1; }

sync_untracked_skills() {
  sync_git ls-files --others --exclude-standard --directory -- skills/ 2>/dev/null \
    | sed -n 's|^skills/\([^/]*\)/$|\1|p' | LC_ALL=C sort -u
}

sync_non_added_paths() {
  sync_git diff --name-status "$SYNC_MIRROR_BRANCH...$SYNC_LOCAL_BRANCH" \
    | awk '$1 != "A" { print $1 " " $2 }'
}

sync_conflict_preflight() {
  local out rc
  rc=0
  out="$(sync_git merge-tree --write-tree --name-only --no-messages "$SYNC_MIRROR_BRANCH" "$SYNC_LOCAL_BRANCH" 2>/dev/null)" || rc=$?
  printf '%s\n' "$out" | sed '1d' | sed '/^$/d' | LC_ALL=C sort
}
```

**`--no-messages` 是必需的（实测确认）**：`git merge-tree --write-tree --name-only` 把 `Auto-merging …` 与 `CONFLICT (…)` 两行写到 **stdout**，`2>/dev/null` 压不住 —— 一个冲突会返回 3 行（路径 + 2 行提示），违反"每行一个冲突路径"的契约，并污染 `sync_state_hash`、plan 报告与 apply 的 REFUSED 消息。实测 `1>/dev/null` 时 stderr 为空，证明它们在 stdout；加 `--no-messages` 后正好只剩「tree oid + 冲突路径」。

**不要引入 `SYNC_PREFLIGHT_EXIT`**：调用方一律写 `CONFLICTS="$(sync_conflict_preflight)"`，函数在子 shell 中执行，赋给该变量的值不会传回调用方 —— 它是死代码。需要退出码时由调用方对函数调用本身取 `$?`。
**注意**：`SYNC_SCRIPT_DIR` 必须存在 —— 机制脚本永远位于本仓库的 `skills/upstream-sync/scripts/`，而 `sync_repo_root` 可能是任意被测仓库（测试用临时仓库）。凡是要定位"机制自己的文件"都必须用 `SYNC_SCRIPT_DIR`，不能用 `sync_repo_root`。`sync_state_hash` **不在本任务实现**（Task 3 用失败测试驱动出来）。

- [ ] **Step 5: 运行测试，确认通过**

Run: `bash tests/upstream-sync/test-invariants.sh; echo "exit=$?"`
Expected: 三行 `ok …`；`exit=0`。

- [ ] **Step 6: 写测试入口**

创建 `tests/upstream-sync/run-tests.sh`（**注意退出码**：失败一律 `exit 1`，`2` 只保留给"零个测试文件"，避免与全局退出码契约（2/3/4/5/6/7 各有含义）相撞）：
```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
failed=0
ran=0
for t in "$HERE"/test-*.sh; do
  [ -f "$t" ] || continue
  ran=$((ran + 1))
  printf '\n=== %s ===\n' "$(basename "$t")"
  bash "$t" || failed=$((failed + 1))
done
printf '\n%s\n' "----------------------------------------"
if [ "$ran" -eq 0 ]; then
  printf '没有找到任何测试文件：%s\n' "$HERE" >&2
  exit 2
fi
if [ "$failed" -eq 0 ]; then
  printf '全部测试通过\n'
  exit 0
fi
printf '有 %s 个测试文件失败\n' "$failed"
exit 1
```

- [ ] **Step 7: 运行全部测试**

Run: `bash tests/upstream-sync/run-tests.sh`
Expected: `全部测试通过`，exit 0。

- [ ] **Step 8: 提交**

```bash
cd ~/Documents/code/superpowers
git add skills/upstream-sync/scripts/sync-lib.sh tests/upstream-sync
git commit -m "feat(upstream-sync): 共用库与测试骨架"
```

**补充断言（fix round 1 加入，见 ledger R17）**：状态哈希与 plan 报告都消费 `sync_conflict_preflight`，但原计划的测试没有守住它的"每行一个冲突路径"契约 —— 实测该契约曾被 `merge-tree` 写到 stdout 的提示行破坏。因此在 `test-invariants.sh` 中补一条 scratch 仓库断言：在 `local` 与 `main` 上分别提交**同一路径**的 `skills/<name>/SKILL.md`，断言 `sync_conflict_preflight` 的输出**恰好一行**且等于该路径。

---

### Task 3: 状态哈希（PLAN_ID）

**Files:**
- Modify: `skills/upstream-sync/scripts/sync-lib.sh`（**新增** `sync_state_hash` 函数）
- Create: `tests/upstream-sync/test-plan-id.sh`

**Interfaces:**
- Consumes: Task 2 的 `sync_*` 函数。
- Produces: `sync_state_hash` → 打印 64 位十六进制（单行）。输入 = 分支名 + `main` sha + `local` sha + **游离技能目录内每个文件的内容摘要**（`git hash-object`，见下）+ 游离技能清单 + 冲突预演结果 + `sync_status_porcelain` 的排序输出。**任何一项变化都必须改变哈希。**
- Produces: `sync_status_porcelain` → `sync_git -c core.quotePath=false -c status.showUntrackedFiles=all status --porcelain=v1`。**plan 与 apply 必须都走这个函数**，否则同一仓库在不同 git 配置下会有两种"脏"的定义。
- **为什么哈希必须含未跟踪文件的**内容**摘要（实测缺口）**：只哈希 porcelain 状态时，改动某个未跟踪技能的文件内容、甚至在该目录里新增文件，`PLAN_ID` 都**不变**（实测：两次变更后哈希与初始值相同）—— 而 apply 要 adopt 的正是这些未跟踪技能，等于"你批准的内容"与"apply 采纳的内容"可以是两份不同的东西。审批必须绑定到内容。

- [ ] **Step 1: 写失败测试**

创建 `tests/upstream-sync/test-plan-id.sh`：
```bash
#!/usr/bin/env bash
set -uo pipefail
TESTS_FAILED=0
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib-assert.sh"
MECH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)/skills/upstream-sync/scripts"

scratch_setup
trap scratch_teardown EXIT
. "$MECH/sync-lib.sh"

h1="$(sync_state_hash)"
h2="$(sync_state_hash)"
assert_eq "$h1" "$h2" "同一状态两次哈希相同"
assert_eq "64" "$(printf '%s' "$h1" | wc -c | tr -d ' ')" "哈希长度为 64"

printf 'dirty\n' >> "$SCRATCH_REPO/README.md"
h3="$(sync_state_hash)"
if [ "$h1" = "$h3" ]; then
  assert_eq "变化" "未变化" "工作区内容变化必须改变哈希"
else
  assert_eq "changed" "changed" "工作区内容变化必须改变哈希"
fi
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash tests/upstream-sync/test-plan-id.sh`
Expected: FAIL —— `sync_state_hash: command not found`（该函数尚未实现），因此 `哈希长度为 64` 与后两条断言均失败。

- [ ] **Step 3: 实现真实哈希**

在 `sync-lib.sh` 中**新增** `sync_state_hash` 函数（Task 2 刻意没有实现它；本任务的失败测试就是"函数不存在"）：
```bash
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
    printf 'untracked_files_begin\n'
    sync_git ls-files --others --exclude-standard -- skills/ 2>/dev/null \
      | LC_ALL=C sort \
      | while IFS= read -r f; do
          printf '%s %s\n' "$(sync_git hash-object -- "$f" 2>/dev/null || printf 'unhashable')" "$f"
        done
    printf 'untracked_files_end\n'
    printf 'status_begin\n'
    sync_status_porcelain | LC_ALL=C sort
    printf 'status_end\n'
  } | shasum -a 256 | awk '{ print $1 }'
}
```

（`ls-files --others` **不要**加 `--directory`：加了会把目录折叠成一行，正是内容盲区的来源。`hash-object` 只计算 blob 摘要，不写入索引。`skills/` 之外的文件刻意不参与 —— apply 从不提交它们。）

- [ ] **Step 4: 运行测试，确认通过**

Run: `bash tests/upstream-sync/test-plan-id.sh; echo "exit=$?"`
Expected: 三行 `ok …`；`exit=0`。

- [ ] **Step 5: 提交**

```bash
cd ~/Documents/code/superpowers
git add skills/upstream-sync/scripts/sync-lib.sh tests/upstream-sync/test-plan-id.sh
git commit -m "feat(upstream-sync): 基于仓库状态的内容哈希作为计划凭证"
```

---

### Task 4: 敏感信息规则表与扫描器

**Files:**
- Create: `skills/upstream-sync/scripts/patterns.tsv`
- Create: `skills/upstream-sync/scripts/scan-sensitive.sh`
- Create: `tests/upstream-sync/test-scanner.sh`
- Modify: `skills/upstream-sync/scripts/sync-lib.sh`（把扫描结果纳入 `sync_state_hash`）
- Modify: `tests/upstream-sync/test-plan-id.sh`（补一条：命中敏感信息时哈希改变）

**Interfaces:**
- Produces:
  - `scan-sensitive.sh --staged` / `--range <rev-range>` / `--paths <path…>`
  - 输出行格式：`<path>:<line>:<rule-id>: <脱敏片段>`；文件名类规则输出 `<path>::<rule-id>: <basename>`
  - 退出码：`0` 干净，`1` 命中，`2` 用法错误

**范围语义要求（后续修订，见 ledger R137/R134 —— 首版实现弱于此，是真实缺口）**：
- `--staged` 读**索引**中的 blob（不是工作区）；`--paths` 读文件系统（其契约就是"扫这些文件"）。
- `--range A..B` 必须扫描**该范围内新引入的全部 blob**（`git rev-list --objects A..B`，过滤出 blob、去重后逐个 `cat-file blob` 扫描），而不只是"范围右端的当前内容"。
  理由：`git push` 发布的是范围内**所有提交可达的对象**。只扫右端时，"提交 A 加入密钥 → 提交 B 删除该文件/该行"这种模式会因右端不存在该路径而被判 ABSENT 跳过 —— **密钥未扫到，却随推送永久进入远端历史**。这正是本机制要防的最典型泄漏方式。
  成本：随本次推送规模线性（首次推送一次性的开销与本就要发布的内容同阶），可接受。
- 该语义变更需同步更新固化了旧弱语义的断言（例如 pre-push 钩子测试里"只扫本次推送范围"的相关断言），并在报告里逐条说明改了哪些、为什么。

  - `sync_state_hash` 的输出现在也包含扫描结果摘要

- [ ] **Step 1: 写失败测试**

创建 `tests/upstream-sync/test-scanner.sh`：
```bash
#!/usr/bin/env bash
set -uo pipefail
TESTS_FAILED=0
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib-assert.sh"
MECH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)/skills/upstream-sync/scripts"
SCAN="$MECH/scan-sensitive.sh"

scratch_setup
trap scratch_teardown EXIT
FIX="$SCRATCH/fixtures"
mkdir -p "$FIX"

# 所有敏感字面量在运行时拼接，保证测试文件自身能通过扫描器
aws="$(printf 'AK%s' 'IAIOSFODNN7EXAMPLE')"
gh="$(printf 'gh%s_%s' 'p' '0123456789abcdefghijklmnop')"
mail="$(printf '%s@%s' 'someone' 'example.invalid')"
home="$(printf '/%s/%s/%s' 'Users' 'someone' 'proj')"
endpoint="$(printf '%s:%s' '127.0.0.1' '12345')"   # 端口用假值：不得把被复盘仓库的真实端口带进仓库

printf 'aws_key = %s\n' "$aws" > "$FIX/aws.txt"
assert_exit 1 "AWS 访问密钥命中" -- "$SCAN" --paths "$FIX/aws.txt"

printf 'token = %s\n' "$gh" > "$FIX/gh.txt"
assert_exit 1 "GitHub token 命中" -- "$SCAN" --paths "$FIX/gh.txt"

printf 'contact %s\n' "$mail" > "$FIX/mail.txt"
assert_exit 1 "邮箱命中" -- "$SCAN" --paths "$FIX/mail.txt"

printf 'cloned %s/x\n' "$home" > "$FIX/home.txt"
assert_exit 1 "绝对家目录路径命中" -- "$SCAN" --paths "$FIX/home.txt"

printf 'listening on %s\n' "$endpoint" > "$FIX/endpoint.txt"
assert_exit 1 "本地服务端点命中" -- "$SCAN" --paths "$FIX/endpoint.txt"

printf 'name: safe\ndescription: 正常内容，提到 api_key 但这个值是 the_VALUE_placeholder 以外都正常\n' > "$FIX/clean.txt"
assert_exit 0 "干净文件不误报" -- "$SCAN" --paths "$FIX/clean.txt"

printf 'x\n' > "$FIX/credentials.json"
assert_exit 1 "凭据类文件名命中（仅凭文件名）" -- "$SCAN" --paths "$FIX/credentials.json"

# 白名单：本地文件，只豁免"规则+路径"这一对
mkdir -p "$SCRATCH_REPO/.sync"
printf 'env-abs-home\t%s\tsomeone 的本机路径示例，已确认无风险\n' "$FIX/home.txt" > "$SCRATCH_REPO/.sync/allowlist.txt"
assert_exit 0 "白名单内的命中被豁免" -- "$SCAN" --paths "$FIX/home.txt"
assert_exit 1 "白名单只豁免列出的那一对，其他规则照常拦截" -- "$SCAN" --paths "$FIX/aws.txt"
rm -f "$SCRATCH_REPO/.sync/allowlist.txt"
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash tests/upstream-sync/test-scanner.sh; echo "exit=$?"`
Expected: FAIL —— 全部断言 got `127`（命令不存在，即 `scan-sensitive.sh` 未创建）。

- [ ] **Step 3: 写规则表**

创建 `skills/upstream-sync/scripts/patterns.tsv`（TAB 分隔四列：id、kind、regex、说明）。
**注意**：路径类正则写成不自匹配形式（用 `[[:alnum:]_.-]+` 而不是 `[^/]+`），否则本文件与规则说明文档会被自己的规则命中。
```text
cred-aws-access-key	content	AKIA[0-9A-Z]{16}	AWS 访问密钥 id
cred-openai-style	content	sk-[A-Za-z0-9]{24,}	OpenAI 风格密钥
cred-github-token	content	gh[pousr]_[A-Za-z0-9]{20,}	GitHub 令牌
cred-github-pat	content	github_pat_[A-Za-z0-9_]{20,}	GitHub 细粒度 PAT
cred-slack-token	content	xox[baprs]-[A-Za-z0-9-]{10,}	Slack 令牌
cred-google-api-key	content	AIza[0-9A-Za-z_-]{35}	Google API 密钥
cred-private-key-block	content	-----BEGIN [A-Z ]*PRIVATE KEY-----	私钥块
cred-generic-assign	content	(api[_-]?key|apikey|secret|token|password|passwd|credential)[[:space:]]*[:=][[:space:]]*["'\'']?[A-Za-z0-9/+_-]{12,}	通用凭据赋值
id-cn-mobile	content	(^|[^0-9])1[3-9][0-9]{9}([^0-9]|$)	中国大陆手机号
id-email	content	[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}	邮箱地址
env-abs-home	content	/Users/[[:alnum:]_.-]+/	绝对家目录路径
env-abs-linux-home	content	/home/[[:alnum:]_.-]+/	Linux 绝对家目录路径
env-private-ip	content	(^|[^0-9])(10[.][0-9]{1,3}|192[.]168|172[.](1[6-9]|2[0-9]|3[01]))[.][0-9]{1,3}[.][0-9]{1,3}	内网 IP
env-localhost-port	content	(127[.]0[.]0[.]1|localhost):[0-9]{2,5}	本地服务端点
env-session-id	content	(session|run|trace)[_-]?id[[:space:]]*[:=][[:space:]]*[A-Za-z0-9_-]{8,}	会话/运行标识
path-secret-file	pathname	(^|[.])env([.].*)?$|credentials.*|[.]pem$|[.]key$|[.]p12$|id_rsa.*|[.]netrc$|[.]npmrc$	凭据类文件名
```

- [ ] **Step 4: 实现扫描器**

创建 `skills/upstream-sync/scripts/scan-sensitive.sh`：
```bash
#!/usr/bin/env bash
# 敏感信息扫描器：G1/G2/G3 三道闸门共用。
# 用法：scan-sensitive.sh --staged | --range <rev-range> | --paths <path>...
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$HERE/sync-lib.sh"

PATTERNS="$HERE/patterns.tsv"
MODE=""
RANGE=""
PATHS=""

case "${1:-}" in
  --staged) MODE="staged"; shift ;;
  --range)  MODE="range"; RANGE="${2:-}"; shift 2 ;;
  --paths)  MODE="paths"; shift; PATHS="$*" ;;
  *) printf '用法: scan-sensitive.sh --staged | --range <rev-range> | --paths <path>...\n' >&2; exit 2 ;;
esac

# 本文件的规则定义文件不参与内容扫描（它天然包含规则正则）。
is_skipped() {
  case "$1" in
    */patterns.tsv) return 0 ;;
    *) return 1 ;;
  esac
}

collect_files() {
  case "$MODE" in
    staged) sync_git diff --cached --name-only --diff-filter=ACMR ;;
    range)  sync_git diff --name-only --diff-filter=ACMR "$RANGE" ;;
    paths)  for p in $PATHS; do
              if [ -d "$p" ]; then
                find "$p" -type f | LC_ALL=C sort
              else
                printf '%s\n' "$p"
              fi
            done ;;
  esac
}

HITS=0
ALLOWLIST="$(sync_repo_root)/$SYNC_STATE_DIR/allowlist.txt"

# 白名单：本地、不入库、不推送；每行 "rule-id<TAB>路径<TAB>原因"，禁止记录原文片段。
allowed() { # rule-id path
  [ -f "$ALLOWLIST" ] || return 1
  grep -qF "$(printf '%s\t%s' "$1" "$2")" "$ALLOWLIST"
}

report_hit() { # path line rule-id text
  allowed "$3" "$1" && return 0
  printf '%s:%s:%s: %s\n' "$1" "$2" "$3" "$4"
  HITS=$((HITS + 1))
}

for f in $(collect_files); do
  base="$(basename "$f")"
  # 文件名类规则
  while IFS="$(printf '\t')" read -r rid kind re desc; do
    [ "$kind" = "pathname" ] || continue
    if printf '%s' "$base" | grep -qE "$re"; then
      report_hit "$f" "" "$rid" "$base"
    fi
  done < "$PATTERNS"

  is_skipped "$f" && continue
  [ -f "$f" ] || continue

  while IFS="$(printf '\t')" read -r rid kind re desc; do
    [ "$kind" = "content" ] || continue
    while IFS= read -r line; do
      n="${line%%:*}"
      text="${line#*:}"
      masked="$(printf '%s' "$text" | cut -c1-60)"
      report_hit "$f" "$n" "$rid" "$masked"
    done < <(grep -inE "$re" "$f" 2>/dev/null || true)
  done < "$PATTERNS"
done

if [ "$HITS" -gt 0 ]; then
  printf '\n扫描命中 %s 处，已阻断。处理方式：改写（首选）、移出仓库，或由本人写入 .sync/allowlist.txt。\n' "$HITS" >&2
  exit 1
fi
exit 0
```
**实现注意**：`grep -inE` 输出的行格式是 `<n>:<text>`，`${line%%:*}` / `${line#*:}` 即可拆分；`< <(…)` 进程替换在 bash 3.2 可用。

- [ ] **Step 5: 运行扫描器测试，确认通过**

Run: `bash tests/upstream-sync/test-scanner.sh; echo "exit=$?"`
Expected: 九行 `ok …`；`exit=0`。

- [ ] **Step 6: 把扫描结果纳入状态哈希**

在 `sync-lib.sh` 的 `sync_state_hash` 中，把 `scan_begin/scan_end` 区块加入（放在 `status_end` 之后）。**扫描器路径必须用 `SYNC_SCRIPT_DIR`**（测试用临时仓库里没有机制脚本，用 `sync_repo_root` 会找不到）：
```bash
    printf 'scan_begin\n'
    "$SYNC_SCRIPT_DIR/scan-sensitive.sh" \
      --range "$SYNC_MIRROR_BRANCH...$SYNC_LOCAL_BRANCH" 2>/dev/null || true
    printf 'scan_end\n'
```
并在 `tests/upstream-sync/test-plan-id.sh` 的**标准尾部之前插入**（**不要追加到文件末尾** —— 尾部是 `exit`，写在它之后的断言会被静默排除在失败计数之外，这是 Task 3 实现者实测出的陷阱）：
```bash
# 提交一个命中敏感信息的文件后，哈希必须改变
mkdir -p "$SCRATCH_REPO/skills/tmpsec"
printf 'key = %s\n' "$(printf 'AK%s' 'IAIOSFODNN7EXAMPLE')" > "$SCRATCH_REPO/skills/tmpsec/SKILL.md"
h4="$(sync_state_hash)"
if [ "$h3" = "$h4" ]; then
  assert_eq "变化" "未变化" "新增命中敏感信息的文件后哈希必须改变"
else
  assert_eq "changed" "changed" "新增命中敏感信息的文件后哈希必须改变"
fi
```

- [ ] **Step 7: 运行全部测试**

Run: `bash tests/upstream-sync/run-tests.sh`
Expected: `全部测试通过`，exit 0。

- [ ] **Step 8: 自净验证（机制自身必须干净）**

Run:
```bash
cd ~/Documents/code/superpowers
bash skills/upstream-sync/scripts/scan-sensitive.sh --paths skills/upstream-sync tests/upstream-sync; echo "exit=$?"
```
Expected: `exit=0`（无输出）。若有命中，按 Global Constraint 6 改写为运行时片段拼接。

- [ ] **Step 9: 提交**

```bash
cd ~/Documents/code/superpowers
git add skills/upstream-sync/scripts tests/upstream-sync
git commit -m "feat(upstream-sync): 敏感信息扫描器与规则表，覆盖凭据、身份、个人环境三类"
```

---

### Task 5: plan.sh（只读计划）

**Files:**
- Create: `skills/upstream-sync/scripts/plan.sh`

**Interfaces:**
- Consumes: Task 2–4 的全部 `sync_*` 与 `scan-sensitive.sh`。
- Produces:
  - `plan.sh [--no-fetch]`
  - 输出：人类可读报告；最后一行 `PLAN_ID=<64 hex>`
  - 落盘：`<repo>/.sync/plan.json`
  - 退出码：`0` 正常（含"无更新"）；`2` 不变量违规（I2）或 G1 命中或不在 `local`；`1` 运行错误（fetch 失败、upstream 强推等）

- [ ] **Step 1: 写失败测试**

创建 `tests/upstream-sync/test-plan.sh`：
```bash
#!/usr/bin/env bash
set -uo pipefail
TESTS_FAILED=0
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib-assert.sh"
MECH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)/skills/upstream-sync/scripts"
PLAN="$MECH/plan.sh"

scratch_setup
trap scratch_teardown EXIT

out="$(bash "$PLAN" --no-fetch)"; rc=$?
assert_eq "0" "$rc" "干净状态 plan 退出 0"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '^PLAN_ID=[0-9a-f]\{64\}$')" "报告最后给出 PLAN_ID"

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

# 脏工作区：plan 仍能出计划（审批门的哈希会把脏状态算进去），但必须明确报告
git -C "$SCRATCH_REPO" reset -q --hard HEAD~1
printf 'dirty\n' >> "$SCRATCH_REPO/README.md"
out4="$(bash "$PLAN" --no-fetch 2>&1)"; rc=$?
assert_eq "0" "$rc" "脏工作区时 plan 仍能出计划"
assert_eq "1" "$(printf '%s\n' "$out4" | grep -c '工作区         : 不干净')" "plan 报告工作区不干净"
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash tests/upstream-sync/test-plan.sh; echo "exit=$?"`
Expected: FAIL —— 首个断言 got `127`（`plan.sh` 不存在）。

- [ ] **Step 3: 实现 plan.sh**

创建 `skills/upstream-sync/scripts/plan.sh`：
```bash
#!/usr/bin/env bash
# 只读计划：拉取镜像、体检、预演冲突、扫描、出报告与 PLAN_ID。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$HERE/sync-lib.sh"

FETCH=1
[ "${1:-}" = "--no-fetch" ] && FETCH=0

ROOT="$(sync_repo_root)"
SCAN="$HERE/scan-sensitive.sh"
sync_require_local_branch

if [ "$FETCH" = "1" ]; then
  # 有界拉取：网络不可达时必须"失败退出"，绝不允许无限期挂住。
  # 实测本环境到 github.com 的 TCP 连接会直接挂住（DNS 正常），早期一个实现者曾因此空等 71 分钟；
  # 因此这里同时关掉交互式凭据提示，并给 http 传输设低速阈值与超时。
  ( export GIT_TERMINAL_PROMPT=0
    sync_git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
      fetch "$SYNC_UPSTREAM_REMOTE" "$SYNC_MIRROR_BRANCH:$SYNC_MIRROR_BRANCH" ) \
    || sync_die "拉取 upstream 失败：网络不可达，或 upstream 强推过历史需要人工处置（已设有界超时，不会无限等待）"
fi

# 镜像引用缺失时给出可读错误（不要让它退化成后续步骤的晦涩失败）
sync_ref_exists "$SYNC_MIRROR_BRANCH" || sync_die "缺少本地镜像分支 ${SYNC_MIRROR_BRANCH}：先按一次性收敛步骤建立它"

NEW_COMMITS="$(sync_git log --oneline "$SYNC_LOCAL_BRANCH..$SYNC_MIRROR_BRANCH" 2>/dev/null | wc -l | tr -d ' ')"
CHANGED_SKILLS="$(sync_git diff --name-only "$SYNC_LOCAL_BRANCH...$SYNC_MIRROR_BRANCH" -- skills/ 2>/dev/null \
  | awk -F/ 'NF>1 { print $2 }' | LC_ALL=C sort -u | tr '\n' ' ')"
VERSION="$(sync_git show "$SYNC_MIRROR_BRANCH:package.json" 2>/dev/null | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -1)"
UNTRACKED="$(sync_untracked_skills)"
CONFLICTS="$(sync_conflict_preflight)"
VIOLATIONS="$(sync_non_added_paths)"

SCAN_OUT=""
SCAN_RC=0
SCAN_OUT="$("$SCAN" --range "$SYNC_MIRROR_BRANCH...$SYNC_LOCAL_BRANCH" 2>&1)" || SCAN_RC=$?

printf '=== upstream-sync 计划 ===\n'
printf '分支           : %s\n' "$(sync_branch)"
printf '镜像 main      : %s\n' "$(sync_git rev-parse "$SYNC_MIRROR_BRANCH")"
printf '工作 local     : %s\n' "$(sync_git rev-parse "$SYNC_LOCAL_BRANCH")"
printf '上游版本       : %s\n' "${VERSION:-未知}"
printf '待合入提交数   : %s\n' "$NEW_COMMITS"
printf '受影响技能     : %s\n' "${CHANGED_SKILLS:-（无）}"
printf '游离技能       : %s\n' "$(printf '%s' "$UNTRACKED" | tr '\n' ' ')"
printf '冲突预演       : %s\n' "${CONFLICTS:-无冲突}"
printf 'I2 违规        : %s\n' "${VIOLATIONS:-无}"
printf '敏感信息扫描   : %s\n' "$([ "$SCAN_RC" = "0" ] && printf '通过' || printf '命中，已阻断')"
if [ -n "$(sync_status_porcelain)" ]; then
  printf '工作区         : 不干净\n'
else
  printf '工作区         : 干净\n'
fi

mkdir -p "$ROOT/$SYNC_STATE_DIR"
# .sync/ 是本地状态目录：通过 .git/info/exclude 排除（不改 .gitignore —— 那会破坏 I2）
EXCLUDE="$ROOT/.git/info/exclude"
if ! grep -qxF "$SYNC_STATE_DIR/" "$EXCLUDE" 2>/dev/null; then
  printf '%s/\n' "$SYNC_STATE_DIR" >> "$EXCLUDE"
fi
{
  printf '{\n'
  printf '  "plan_id": "%s",\n' "$(sync_state_hash)"
  printf '  "created_at": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '  "branch": "%s",\n' "$(sync_branch)"
  printf '  "mirror_sha": "%s",\n' "$(sync_git rev-parse "$SYNC_MIRROR_BRANCH")"
  printf '  "local_sha": "%s",\n' "$(sync_git rev-parse "$SYNC_LOCAL_BRANCH")"
  printf '  "upstream_new_commits": %s,\n' "$NEW_COMMITS"
  printf '  "upstream_version": "%s",\n' "${VERSION:-unknown}"
  printf '  "conflicts": "%s",\n' "${CONFLICTS:-}"
  printf '  "untracked_skills": "%s",\n' "$(printf '%s' "$UNTRACKED" | tr '\n' ',')"
  printf '  "invariants_ok": %s\n' "$([ -z "$VIOLATIONS" ] && printf 'true' || printf 'false')"
  printf '}\n'
} > "$ROOT/$SYNC_STATE_DIR/plan.json"

if [ -n "$VIOLATIONS" ]; then
  printf '\nREFUSED：以下路径不是纯新增，需人工决策：\n%s\n' "$VIOLATIONS" >&2
  exit 2
fi
if [ "$SCAN_RC" != "0" ]; then
  printf '\n%s\n' "$SCAN_OUT" >&2
  exit 2
fi

printf '\nPLAN_ID=%s\n' "$(sync_state_hash)"
```
**约定**：`PLAN_ID` 出现在**最后一行**；出现 `REFUSED` 时**不输出** `PLAN_ID`，即无可审批的计划。

- [ ] **Step 4: 运行测试，确认通过**

Run: `bash tests/upstream-sync/test-plan.sh; echo "exit=$?"`
Expected: 九行 `ok …`（含 I2、G1 两条拒绝路径与脏工作区报告）；`exit=0`。

- [ ] **Step 5: 在真实仓库试跑（只读）**

Run:
```bash
cd ~/Documents/code/superpowers
bash skills/upstream-sync/scripts/plan.sh
```
Expected: 报告显示 `待合入提交数 : 0`、`I2 违规 : 无`、`敏感信息扫描 : 通过`，最后一行 `PLAN_ID=…`。（此刻 spec 尚未净化，故扫描**可能**报命中——若报命中，记录命中的文件与规则号，Task 10 处理；不要为了让 plan 通过而放宽规则。）

- [ ] **Step 6: 提交**

```bash
cd ~/Documents/code/superpowers
git add skills/upstream-sync/scripts/plan.sh tests/upstream-sync/test-plan.sh
git commit -m "feat(upstream-sync): plan 只读计划与审批凭证"
```

---

### Task 6: apply.sh（审批门 + 落地）

**Files:**
- Create: `skills/upstream-sync/scripts/apply.sh`
- Create: `tests/upstream-sync/test-apply-gate.sh`

**Interfaces:**
- Consumes: Task 2–5。
- Produces: `apply.sh --plan-id <hash> [--adopt] [--no-push]`
  - 阶段顺序：审批门（哈希比对）→ 冲突预演 → 工作区干净检查 → adopt（可选）→ merge → 仓库自检 → G2/G3 复检 → commit → push（除 `--no-push`）
  - 环境变量 `SYNC_SELFTEST_CMD`（默认 = 仓库两条自检命令）便于测试替换
  - 退出码遵循 Global Constraint 7

- [ ] **Step 1: 写失败测试**

创建 `tests/upstream-sync/test-apply-gate.sh`：
```bash
#!/usr/bin/env bash
set -uo pipefail
TESTS_FAILED=0
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib-assert.sh"
MECH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)/skills/upstream-sync/scripts"
PLAN="$MECH/plan.sh"
APPLY="$MECH/apply.sh"

scratch_setup
trap scratch_teardown EXIT

# 1) PLAN_ID 不匹配 → 3
assert_exit 3 "过期的 PLAN_ID 被拒绝" -- bash "$APPLY" --plan-id "0000000000000000000000000000000000000000000000000000000000000000"

# 2) 工作区有非技能脏文件 → 4
# 注意顺序：审批门在干净检查之前，所以必须先弄脏、再取 PLAN_ID，否则会先撞 exit 3
printf 'dirty\n' >> "$SCRATCH_REPO/README.md"
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_exit 4 "工作区不干净被拒绝" -- bash "$APPLY" --plan-id "$ID"
git -C "$SCRATCH_REPO" checkout -- README.md
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_eq "1" "$(printf '%s' "$ID" | grep -c '^[0-9a-f]\{64\}$')" "恢复干净后可以重新取得计划"

# 3) upstream 新增同名技能 → 冲突预演 → 7
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
git clone -q "$SCRATCH_UPSTREAM" "$SCRATCH_SEED2"
git -C "$SCRATCH_SEED2" config user.name "$SCRATCH_USER"
git -C "$SCRATCH_SEED2" config user.email "$SCRATCH_USER@$SCRATCH_DOMAIN"
mkdir -p "$SCRATCH_SEED2/skills/mine"
printf -- '---\nname: mine\ndescription: 上游同名\n---\n\n# mine\n' > "$SCRATCH_SEED2/skills/mine/SKILL.md"
git -C "$SCRATCH_SEED2" add -A
git -C "$SCRATCH_SEED2" commit -qm mine
git -C "$SCRATCH_SEED2" push -q origin main
mkdir -p "$SCRATCH_REPO/skills/mine"
printf -- '---\nname: mine\ndescription: 我的同名\n---\n\n# mine\n' > "$SCRATCH_REPO/skills/mine/SKILL.md"
git -C "$SCRATCH_REPO" add skills/mine
git -C "$SCRATCH_REPO" commit -qm "add mine"
ID="$(bash "$PLAN" | sed -n 's/^PLAN_ID=//p')"
assert_exit 7 "同名技能冲突被拒绝" -- bash "$APPLY" --plan-id "$ID" --no-push

# 4) adopt + 合入：游离技能被采纳，upstream 新提交被 merge，提交后工作区干净
git -C "$SCRATCH_REPO" mv skills/mine skills/mine-local
git -C "$SCRATCH_REPO" commit -qm rename
mkdir -p "$SCRATCH_REPO/skills/fresh"
printf -- '---\nname: fresh\ndescription: 新技能\n---\n\n# fresh\n' > "$SCRATCH_REPO/skills/fresh/SKILL.md"
ID="$(bash "$PLAN" | sed -n 's/^PLAN_ID=//p')"
assert_exit 0 "adopt 与合入成功（--adopt --no-push）" -- bash "$APPLY" --plan-id "$ID" --adopt --no-push
assert_eq "" "$(git -C "$SCRATCH_REPO" status --porcelain=v1)" "落地后工作区干净"
assert_eq "1" "$(git -C "$SCRATCH_REPO" log --oneline --merges main..local | wc -l | tr -d ' ')" "合入产生了 merge 提交"

# 5) 幂等：无新提交、无游离技能时 apply 报"无需变更"并退出 0
ID="$(bash "$PLAN" --no-fetch | sed -n 's/^PLAN_ID=//p')"
assert_exit 0 "无变更时 apply 退出 0" -- bash "$APPLY" --plan-id "$ID" --adopt --no-push
```

**注意**：第 4 步里 `--adopt` 会**写**工作区（`git add` 游离技能），而审批门的第一步是比较哈希，因此取 `PLAN_ID` 必须在创建游离技能**之后**（脚本已如此）；同理第 2 步必须先弄脏再取 `PLAN_ID`，否则会先撞上 exit 3 而不是 4。

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash tests/upstream-sync/test-apply-gate.sh; echo "exit=$?"`
Expected: FAIL —— 首个断言 got `127`（`apply.sh` 不存在）。

- [ ] **Step 3: 实现 apply.sh**

创建 `skills/upstream-sync/scripts/apply.sh`：
```bash
#!/usr/bin/env bash
# 落地：审批门 → 冲突预演 → 干净检查 → merge → adopt → 自检 → 复检 → 身份报告 → commit → push
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$HERE/sync-lib.sh"

PLAN_ID=""
ADOPT=0
PUSH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --plan-id) PLAN_ID="${2:-}"; shift 2 ;;
    --adopt)   ADOPT=1; shift ;;
    --no-push) PUSH=0; shift ;;
    *) printf '用法: apply.sh --plan-id <hash> [--adopt] [--no-push]\n' >&2; exit 2 ;;
  esac
done
[ -n "$PLAN_ID" ] || { printf '缺少 --plan-id\n' >&2; exit 2; }

ROOT="$(sync_repo_root)"
SCAN="$HERE/scan-sensitive.sh"
SELFTEST="${SYNC_SELFTEST_CMD:-node tests/opencode/test-skill-registration.mjs .opencode/plugins/superpowers.js}"
sync_require_local_branch

# graphviz 依赖测试按环境条件纳入：本机未安装 dot，该测试**必然** exit 1，
# 若无条件纳入会让 apply 永远以 exit 6 拒绝推送。跳过时必须响亮提示，绝不静默（R3）。
if [ -z "${SYNC_SELFTEST_CMD:-}" ]; then
  if command -v dot >/dev/null 2>&1; then
    SELFTEST="bash tests/writing-skills/test-render-graphs.sh && $SELFTEST"
  else
    printf '注意：未检测到 graphviz(dot)，跳过 tests/writing-skills/test-render-graphs.sh（该测试在本机必然失败，属环境缺失而非代码缺陷）。\n'
  fi
fi

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

DIRTY="$(sync_status_porcelain | grep -v '^?? skills/' || true)"
if [ -n "$DIRTY" ]; then
  printf 'REFUSED：工作区不干净（不 stash、不覆盖你的改动）：\n%s\n' "$DIRTY" >&2
  exit 4
fi

CHANGED=0

# 先 merge 再 adopt：避免"暂存内容 + 合并"这一组合，语义更清晰
if [ "$(sync_git rev-list --count "$SYNC_LOCAL_BRANCH..$SYNC_MIRROR_BRANCH")" != "0" ]; then
  sync_git merge --no-ff "$SYNC_MIRROR_BRANCH" -m "merge: 合入 upstream $SYNC_MIRROR_BRANCH ($(sync_git rev-parse --short "$SYNC_MIRROR_BRANCH"))"
  printf 'merge: 已合入 %s\n' "$(sync_git rev-parse --short "$SYNC_MIRROR_BRANCH")"
  CHANGED=1
fi

if [ "$ADOPT" = "1" ]; then
  for name in $(sync_untracked_skills); do
    dir="skills/$name"
    [ -f "$dir/SKILL.md" ] || sync_die "游离技能 $name 缺少 SKILL.md"
    fm_name="$(sed -n 's/^name: *//p' "$dir/SKILL.md" | head -1)"
    fm_desc="$(sed -n 's/^description: *//p' "$dir/SKILL.md" | head -1)"
    [ "$fm_name" = "$name" ] || sync_die "游离技能 $name 的 frontmatter name 为 '${fm_name}'，必须与目录同名"
    [ -n "$fm_desc" ] || sync_die "游离技能 $name 缺少 description"
    if find "$dir" -mindepth 2 -name SKILL.md | grep -q .; then
      sync_die "游离技能 $name 含嵌套 SKILL.md（DSH 不支持嵌套发现）"
    fi
    sync_git add "$dir"
    printf 'adopt: %s\n' "$dir"
    CHANGED=1
  done
fi

if [ "$CHANGED" = "0" ]; then
  printf '无需变更：upstream 无新提交，且没有待 adopt 的游离技能。\n'
  exit 0
fi

# 可选闸门：仅在 ShellCheck 可用且本次确有 shell 改动时才追加（本机未安装 ShellCheck）
if [ -z "${SYNC_SELFTEST_CMD:-}" ] && command -v shellcheck >/dev/null 2>&1 \
   && sync_git diff --name-only "$SYNC_MIRROR_BRANCH...$SYNC_LOCAL_BRANCH" | grep -q '[.]sh$'; then
  SELFTEST="$SELFTEST && bash scripts/lint-shell.sh"
  printf '自检：追加 scripts/lint-shell.sh（检测到 shell 改动且 ShellCheck 可用）\n'
fi

( cd "$ROOT" && eval "$SELFTEST" ) || { printf 'REFUSED：仓库自检失败，未推送。\n注意：因运行时是符号链接，新内容此刻已在运行时可见。\n' >&2; exit 6; }

STAGED="$("$SCAN" --staged 2>&1)" || { printf '%s\n' "$STAGED" >&2; printf 'REFUSED：暂存内容敏感信息复检命中。\n' >&2; exit 5; }

if [ -n "$(sync_git diff --cached --name-only)" ]; then
  sync_git commit -m "sync: 采纳本地新增技能"
fi

OUTGOING="$(sync_git log --oneline "$SYNC_LOCAL_BRANCH" --not --remotes="$SYNC_ORIGIN_REMOTE" 2>/dev/null | wc -l | tr -d ' ')"
PUSH_RANGE=""
if [ "$OUTGOING" != "0" ]; then
  if sync_ref_exists "refs/remotes/$SYNC_ORIGIN_REMOTE/$SYNC_LOCAL_BRANCH"; then
    PUSH_RANGE="$SYNC_ORIGIN_REMOTE/$SYNC_LOCAL_BRANCH..$SYNC_LOCAL_BRANCH"
  else
    PUSH_RANGE="$SYNC_MIRROR_BRANCH..$SYNC_LOCAL_BRANCH"
  fi

  # 提交身份是元数据，内容扫描器抓不到 —— 必须在此显式报告
  printf '将推送的提交身份：\n'
  sync_git log --format='  %h  %an <%ae>' "$PUSH_RANGE"
  printf '预期身份：取自全局 git 配置；若上面出现非预期身份，请停止并检查。\n'

  PUSH_SCAN="$("$SCAN" --range "$PUSH_RANGE" 2>&1)" || { printf '%s\n' "$PUSH_SCAN" >&2; printf 'REFUSED：推送范围敏感信息复检命中。\n' >&2; exit 5; }

  # 本地状态目录永不入库、永不推送（白名单就在里面；扫描器的内容规则抓不到它）
  if sync_git diff --cached --name-only | grep -q '^[.]sync/'; then
    printf 'REFUSED：.sync/ 下有暂存内容（本地状态目录不得入库）。\n' >&2
    exit 5
  fi
  if sync_git log --format= --name-only "$PUSH_RANGE" | grep -q '^[.]sync/'; then
    printf 'REFUSED：推送范围内含 .sync/ 路径（本地状态目录不得推送）。\n' >&2
    exit 5
  fi
fi

if [ "$PUSH" = "1" ]; then
  sync_git push "$SYNC_ORIGIN_REMOTE" "$SYNC_LOCAL_BRANCH"
  printf 'push: 已推送到 %s/%s\n' "$SYNC_ORIGIN_REMOTE" "$SYNC_LOCAL_BRANCH"
else
  printf '已落地（未推送，--no-push）。\n'
fi
exit 0
```
**说明**：`--adopt` 只处理 `skills/` 下的游离技能；`docs/local/` 的新文档属于"已跟踪目录里的新文件"，由正常 `git add docs/local` 处理（见 Task 11）。

- [ ] **Step 4: 运行测试，确认通过**

Run: `bash tests/upstream-sync/test-apply-gate.sh; echo "exit=$?"`
Expected: 八条断言全部 `ok`；`exit=0`。

- [ ] **Step 5: 运行全部测试**

Run: `bash tests/upstream-sync/run-tests.sh`
Expected: `全部测试通过`。

- [ ] **Step 6: 提交**

```bash
cd ~/Documents/code/superpowers
git add skills/upstream-sync/scripts/apply.sh tests/upstream-sync/test-apply-gate.sh
git commit -m "feat(upstream-sync): apply 审批门与落地流程"
```

---

### Task 7: 兜底闸门（pre-push 钩子，M5）

**Files:**
- Create: `skills/upstream-sync/scripts/install-pre-push.sh`
- Create: `tests/upstream-sync/test-hook.sh`

**Interfaces:**
- Consumes: `scan-sensitive.sh`（Task 4）。
- Produces:
  - `install-pre-push.sh` → 在 `<repo>/.git/hooks/pre-push` 写入带 `# upstream-sync managed` 标记的钩子；幂等；遇到已存在的**非本机制**钩子时拒绝并 `exit 4`
  - 钩子从 stdin 读取 `<local ref> <local sha> <remote ref> <remote sha>`，对每个 `remote_sha..local_sha` 范围扫描（`remote_sha` 全 0 时用 `main..local_sha`），命中即 `exit 1` 阻断 push

- [ ] **Step 1: 写失败测试**

创建 `tests/upstream-sync/test-hook.sh`：
```bash
#!/usr/bin/env bash
set -uo pipefail
TESTS_FAILED=0
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib-assert.sh"
MECH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)/skills/upstream-sync/scripts"
INSTALL="$MECH/install-pre-push.sh"

scratch_setup
trap scratch_teardown EXIT

assert_exit 0 "安装兜底闸门成功" -- bash "$INSTALL"
assert_exit 0 "重复安装幂等" -- bash "$INSTALL"
HOOK="$SCRATCH_REPO/.git/hooks/pre-push"
[ -f "$HOOK" ] && assert_eq "ok" "ok" "钩子文件存在" || assert_eq "存在" "缺失" "钩子文件存在"

# 干净内容 push 必须放行（退出 0）
sha="$(git -C "$SCRATCH_REPO" rev-parse local)"
printf 'refs/heads/local %s refs/heads/local %s\n' "$sha" "$sha" | bash "$HOOK" >/dev/null 2>&1
assert_eq "0" "$?" "干净内容放行"

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

# 非本机制的既有钩子不得被覆盖
rm -f "$HOOK"
printf '#!/bin/sh\nexit 0\n' > "$HOOK"
chmod +x "$HOOK"
assert_exit 4 "既有非托管钩子时拒绝安装" -- bash "$INSTALL"
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash tests/upstream-sync/test-hook.sh; echo "exit=$?"`
Expected: FAIL —— 首个断言 got `127`（安装脚本不存在）。

- [ ] **Step 3: 实现安装器**

创建 `skills/upstream-sync/scripts/install-pre-push.sh`：
```bash
#!/usr/bin/env bash
# 安装本地兜底闸门（不入库、不推送）。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$HERE/sync-lib.sh"

ROOT="$(sync_repo_root)"
HOOK="$ROOT/.git/hooks/pre-push"
MARKER="# upstream-sync managed"

if [ -f "$HOOK" ] && ! grep -qF "$MARKER" "$HOOK"; then
  printf 'REFUSED：%s 已存在且非本机制管理，拒绝覆盖。请人工处理。\n' "$HOOK" >&2
  exit 4
fi

cat > "$HOOK" <<EOF
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
  if ! "\$SCAN" --range "\$range"; then
    printf 'upstream-sync: 推送被兜底闸门阻断（范围 %s）\\n' "\$range" >&2
    rc=1
  fi
done
exit \$rc
EOF
chmod +x "$HOOK"
printf '已安装兜底闸门：%s\n' "$HOOK"
```
**注意**：heredoc 用 `<<EOF`（**不引号**）以便展开 `$HERE`，因此脚本内所有本应延迟展开的变量都写成 `\$var`。

- [ ] **Step 4: 运行测试，确认通过**

Run: `bash tests/upstream-sync/test-hook.sh; echo "exit=$?"`
Expected: 六条断言全 `ok`；`exit=0`。

- [ ] **Step 5: 在真实仓库安装**

Run:
```bash
cd ~/Documents/code/superpowers
bash skills/upstream-sync/scripts/install-pre-push.sh
head -3 .git/hooks/pre-push
```
Expected: 打印已安装路径；`head` 显示 shebang 与 `# upstream-sync managed`。

- [ ] **Step 6: 提交**

```bash
cd ~/Documents/code/superpowers
git add skills/upstream-sync/scripts/install-pre-push.sh tests/upstream-sync/test-hook.sh
git commit -m "feat(upstream-sync): 本地 pre-push 兜底闸门"
```

---

### Task 8: SKILL.md 与参考文档

**Files:**
- Create: `skills/upstream-sync/SKILL.md`
- Create: `skills/upstream-sync/references/hard-rules.md`
- Create: `skills/upstream-sync/references/recovery.md`

**Interfaces:**
- Consumes: Task 5–7 的 `plan.sh` / `apply.sh` / `install-pre-push.sh`。
- Produces: DSH 可发现的技能 `upstream-sync`（frontmatter `name` 必须等于目录名 `upstream-sync`）。

- [ ] **Step 1: 写技能入口**

创建 `skills/upstream-sync/SKILL.md`：
```markdown
---
name: upstream-sync
description: Use when the user asks to 同步 superpowers 上游更新 / 接取 upstream 更新 / 把本地新增技能同步进代码库 / 更新 fork / 发布我的技能到仓库 (sync upstream, pull superpowers updates, push local skills to the fork)。提供 plan（只读出报告与审批凭证）与 apply（需匹配凭证才落地）两个入口，并在推送前强制通过敏感信息闸门。
---

# Upstream Sync

## Overview

本仓库（fork）的 `main` 是 upstream 的**纯净镜像**，永不 checkout；你的内容全部在 `local` 分支上，且**只做纯新增**。运行时 `~/.dsh/skills` 是指向本仓库 `skills/` 的符号链接，因此"运行时里的新增"与"仓库里的文件"是同一份字节 —— 同步到代码库就是 `git add` + commit + push。

## Workflow

1. **出计划（只读）**：`bash skills/upstream-sync/scripts/plan.sh`
   把报告念给用户，并明确给出 `PLAN_ID`。若输出 `REFUSED`，则没有可审批的计划，先处理它列出的问题。
2. **等同意**：用户明确说同意/apply 之后才继续。不要替用户假定同意。
3. **落地**：`bash skills/upstream-sync/scripts/apply.sh --plan-id <PLAN_ID>`；有游离技能要采纳时加 `--adopt`。
   若 apply 打印 `REFUSED`，按其退出码对应处置（见 Global Constraints 的退出码契约）：
   `3` 计划过期 → 重新 plan；`4` 工作区脏 → 让用户决定；`5` 敏感信息 → 定点改写；`6` 自检失败 → 修自检；`7` 冲突 → 给技能改名。
4. **汇报**：报出 merge 的提交、adopt 的技能、push 结果，以及"运行时已即时生效"这一点。

## 本地新增技能

在 `~/.dsh/skills/<name>/` 里创建技能后，它在本仓库工作区里就是 `skills/<name>/`（未跟踪）。`plan.sh` 会把它列为"游离技能"，`apply.sh --adopt` 会校验 frontmatter 并提交。

校验项：`name` 为 kebab-case 且等于目录名；有 `description`；包内**不得**有嵌套 `**/SKILL.md`（DSH 不支持嵌套发现）。

## 红旗

| 想法 | 事实 |
|---|---|
| "报告看起来没问题，我直接 apply 吧" | 审批门是给人的。"我读过了"不是同意。 |
| "这个命中大概是误报" | 闸门是硬失败。改写或由本人写白名单，没有第三条路。 |
| "先把 main 更新一下" | 永不 checkout `main`；它只由 `git fetch upstream main:main` 更新。 |
| "顺手改一下上游那个文件" | 纯新增是唯一约定；一改就破坏 I2，plan 会拦。 |
| "先 push 上去再修" | 推送不可回收。修完再推。 |
| "删掉那个冲突来源的技能就行" | 你的技能是你的资产；冲突处理是**改名**，不是删除。 |

## 参考

- `references/hard-rules.md` —— 硬规则全文
- `references/recovery.md` —— 失败与回滚手册
```

- [ ] **Step 2: 写硬规则与恢复手册**

创建 `skills/upstream-sync/references/hard-rules.md`：把 spec §7 的八条硬规则逐条抄入，并补一句"`upstream` 的 push URL 已被置为不可用值，误推在物理上不可能"。

创建 `skills/upstream-sync/references/recovery.md`：把 spec §8 的失败/回滚表逐条抄入，并给出命令：
```bash
# merge 后未 push 前回退
git reset --hard ORIG_HEAD
# 运行时彻底回退（由人执行）
mv ~/.dsh/skills ~/.dsh/skills.broken && mv ~/.dsh/skills.bak-* ~/.dsh/skills
```

- [ ] **Step 3: 校验技能合规**

Run:
```bash
cd ~/Documents/code/superpowers
grep -n '^name:' skills/upstream-sync/SKILL.md
find skills/upstream-sync -mindepth 2 -name SKILL.md
```
Expected: `name: upstream-sync`；`find` 无输出（无嵌套）。

- [ ] **Step 4: 自净复检**

Run:
```bash
cd ~/Documents/code/superpowers
bash skills/upstream-sync/scripts/scan-sensitive.sh --paths skills/upstream-sync; echo "exit=$?"
```
Expected: `exit=0`。

- [ ] **Step 5: 提交**

```bash
cd ~/Documents/code/superpowers
git add skills/upstream-sync/SKILL.md skills/upstream-sync/references
git commit -m "feat(upstream-sync): 技能入口与硬规则、恢复手册"
```

---

### Task 9: 净化并迁入自建技能（M3）

**Files:**
- Create: `skills/writing-run-retrospectives/**`（从运行时目录复制后净化）
- 源（保持不动，去重交给 M6）：`~/.dsh/skills/writing-run-retrospectives/`

**Interfaces:**
- Consumes: Task 4 的扫描器（净化是否达标由它裁定）。
- Produces: 仓库内的 `skills/writing-run-retrospectives/`，可通过 `scan-sensitive.sh`。

- [ ] **Step 1: 复制进仓库**

Run:
```bash
cd ~/Documents/code/superpowers
mkdir -p skills/writing-run-retrospectives
cp -R ~/.dsh/skills/writing-run-retrospectives/. skills/writing-run-retrospectives/
find skills/writing-run-retrospectives -type f | wc -l
```
Expected: 文件数与源目录一致（此前实测为 15）。

- [ ] **Step 2: 定位所有需净化的位置**

Run:
```bash
cd ~/Documents/code/superpowers
grep -rnE '/Users/[[:alnum:]_.-]+/|(127[.]0[.]0[.]1|localhost):[0-9]{2,5}' skills/writing-run-retrospectives || echo "无命中"
```
Expected: 命中三处（`CREATION-LOG.md` 一处绝对路径；`assets/report-example.html` 一处绝对路径 + 一处本地端点）。

- [ ] **Step 3: 净化内容**

逐处改写（保持语义，去掉个人环境）：
- 绝对家目录路径 → `~/Documents/code/<被复盘仓库名>`，或直接写"<被复盘仓库> 的绝对路径"。
- 本地服务端点 → "本地调试端口"，或写成一个显然通用的示例值。
- 会话/运行标识 → 通用示例值。

- [ ] **Step 4: 用扫描器复核（净化不许靠肉眼）**

Run:
```bash
cd ~/Documents/code/superpowers
bash skills/upstream-sync/scripts/scan-sensitive.sh --paths skills/writing-run-retrospectives; echo "exit=$?"
```
Expected: `exit=0`。若仍有命中，回到 Step 3；**不得**为此放宽规则或写白名单。

- [ ] **Step 5: frontmatter 与结构合规检查**

Run:
```bash
cd ~/Documents/code/superpowers
sed -n '1,5p' skills/writing-run-retrospectives/SKILL.md
find skills/writing-run-retrospectives -mindepth 2 -name SKILL.md || true
```
Expected: frontmatter 的 `name` 为 `writing-run-retrospectives`，有 `description`；无嵌套 `SKILL.md`。

- [ ] **Step 6: 按 writing-skills 口径审查技能内容**

调用 `skill(writing-skills)` 并按其检查表核对：description 的触发条件是否具体、正文是否可执行、有无未定义引用、有无与仓库其他技能重复的描述。发现问题直接修在这个仓库副本里（源目录保持不动）。

- [ ] **Step 7: 提交**

```bash
cd ~/Documents/code/superpowers
git add skills/writing-run-retrospectives
git commit -m "feat(skills): 迁入本地新增技能 writing-run-retrospectives（已脱敏）"
```

---

### Task 10: 净化 spec 与本计划自身

**Files:**
- Modify: `docs/local/specs/2026-10-10-superpowers-sync-design.md`
- Modify: `docs/local/plans/2026-10-10-upstream-sync-mechanism.md`（本文件）

**Interfaces:**
- Consumes: 扫描器。
- Produces: `docs/local/**` 全部通过扫描（否则 Task 11 的首次提交会被自己的闸门拦住）。

- [ ] **Step 1: 定位**

Run:
```bash
cd ~/Documents/code/superpowers
grep -rnE '/Users/[[:alnum:]_.-]+/|(127[.]0[.]0[.]1|localhost):[0-9]{2,5}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}' docs/local || echo "无命中"
```
Expected: spec 中有命中（绝对家目录路径若干、本地端点一处、身份邮箱若干）；本计划应无命中。

- [ ] **Step 2: 改写**

原 spec 中：
- 绝对家目录仓库路径 → `~/Documents/code/superpowers`（家目录相对写法）。
- 被复盘仓库的绝对路径字面值 → 「被复盘仓库的绝对路径」（不出现具体路径）。
- 本地服务端点字面值 → 「一处本地服务端点」。
- 身份邮箱字面值 → 「全局 git 身份邮箱」（**不打印字面值**）。
- M6 命令里的绝对路径 → `~/Documents/code/superpowers/skills`。

- [ ] **Step 3: 复检**

Run:
```bash
cd ~/Documents/code/superpowers
bash skills/upstream-sync/scripts/scan-sensitive.sh --paths docs/local skills tests/upstream-sync; echo "exit=$?"
```
Expected: `exit=0`。

- [ ] **Step 4: 提交**

```bash
cd ~/Documents/code/superpowers
git add docs/local
git commit -m "docs(local): 收敛设计与计划文档，去除个人环境信息"
```

---

### Task 11: 跑齐仓库自检与全部验证项（M4 收口）

**Files:**
- 无新文件

**Interfaces:**
- Consumes: 前面全部任务。
- Produces: 一次性收敛的首次完整提交历史（但**尚未推送**）。

- [ ] **Step 1: 跑机制自身的全部测试**

Run:
```bash
cd ~/Documents/code/superpowers
bash tests/upstream-sync/run-tests.sh
```
Expected: `全部测试通过`。

- [ ] **Step 2: 跑仓库既有自检**

Run:
```bash
cd ~/Documents/code/superpowers
bash tests/writing-skills/test-render-graphs.sh
node tests/opencode/test-skill-registration.mjs .opencode/plugins/superpowers.js
```
Expected: 两条都通过。第二条会**按目录动态推导**期望的技能集合，因此新增的自定义技能不会让它失败；若失败，说明自建技能的 `SKILL.md` 结构不对，回到 Task 9。

- [ ] **Step 3: 验证 I1**

Run:
```bash
cd ~/Documents/code/superpowers
git rev-parse main
git ls-remote https://github.com/obra/superpowers.git refs/heads/main | awk '{print $1}'
```
Expected: 两个 SHA 相同。

- [ ] **Step 4: 验证 I2（全 A）**

Run:
```bash
cd ~/Documents/code/superpowers
git diff --name-status main...local | awk '$1 != "A"' | head
echo "非新增行数: $(git diff --name-status main...local | awk '$1 != "A"' | wc -l | tr -d ' ')"
```
Expected: 无输出；`非新增行数: 0`。

- [ ] **Step 5: 验证 plan 在真实仓库可出计划**

Run:
```bash
cd ~/Documents/code/superpowers
bash skills/upstream-sync/scripts/plan.sh | tail -3
```
Expected: `敏感信息扫描 : 通过`，最后一行是合法的 `PLAN_ID=<64 hex>`。

- [ ] **Step 6: 验证 apply 的过期凭证拒绝在真实仓库成立**

Run:
```bash
cd ~/Documents/code/superpowers
bash skills/upstream-sync/scripts/apply.sh --plan-id 0000000000000000000000000000000000000000000000000000000000000000; echo "exit=$?"
```
Expected: 打印 `REFUSED：计划已过期`；`exit=3`。

- [ ] **Step 7: 确认工作区与分支状态**

Run:
```bash
cd ~/Documents/code/superpowers
git status --short
git branch --show-current
git log --oneline -6
```
Expected: 工作区干净；分支 `local`；最近 6 条提交都是本次实现产生的。

---

### Task 12: M6 交接、首次推送与 M7 收尾

**Files:**
- 无新文件

**Interfaces:**
- Consumes: Task 11 全部通过。
- Produces: 运行时根指向仓库的符号链接、`origin/local` 分支、旧克隆清理。

- [ ] **Step 1: 请用户执行运行时根替换（M6）**

用界面弹框向用户提出请求，给出**可直接粘贴**的命令（含绝对路径 —— 这条只出现在对话里，不写进仓库文件）：
```bash
mv ~/.dsh/skills ~/.dsh/skills.bak-v6.3.0-$(date +%Y%m%d)
ln -s <仓库绝对路径>/skills ~/.dsh/skills
ls -l ~/.dsh/skills && ls ~/.dsh/skills | head
```
等待用户反馈执行结果。**在收到反馈前不得继续。**

- [ ] **Step 2: 根据反馈判定**

- 成功（`ls -l` 显示链接指向仓库 `skills`）→ 进入 Step 3。
- 失败 → 让用户执行 `rm ~/.dsh/skills && mv ~/.dsh/skills.bak-*  ~/.dsh/skills` 恢复，然后停止并向用户报告，不要把失败当成功。

- [ ] **Step 3: 验证运行时发现（新会话）**

请用户新开一个会话，确认技能目录里出现 `upstream-sync` 与 `writing-run-retrospectives`，并确认 upstream 技能内容是 v7.0.0（例如 `brainstorming` 含"Three Paths"一节）。
Expected: 用户确认两项都在。

- [ ] **Step 4: 首次推送（需用户确认，**走 apply.sh** 而不是手工 push）**

先向用户展示将推送的内容：`git log --oneline main..local` 与 `git diff --stat main...local`，并明确"这会推到 `origin/local`，不会碰 `main`，也不会碰 upstream"。得到同意后，用机制自己的推送那一程推送 —— 此时既没有 merge 也没有待采纳的游离技能，故 `apply` 走的正是"没有事要做、但有东西要推"那一支（早退条件是 `CHANGED=0` **且** `OUTGOING=0`，两条都满足才会什么都不推送）：

```bash
cd ~/Documents/code/superpowers
bash skills/upstream-sync/scripts/plan.sh --no-fetch   # 取 PLAN_ID；报告整份念给用户
bash skills/upstream-sync/scripts/apply.sh --plan-id <PLAN_ID>
git ls-remote origin
```
Expected: `apply` 的推送前序列完整跑过（"开始扫描推送范围 …"/"推送范围扫描完成：用时 N 秒"、`将推送的提交身份`、G3 复检、`.sync/` 推送守卫、推送目的地守卫），最后打印 `push: 已推送到 origin/local`；`refs/heads/local` 出现在 origin；`refs/heads/main` 仍是 `bb92a77`。

**不要手工 `git push -u origin local`。** 那是一次绕过审批门的推送，同时丢掉三样只有 `apply` 才有的检查：**推送目的地校验**（origin 是否指向 upstream、是否配了多个 pushurl）、**`.sync/` 推送范围守卫**（白名单所在的状态目录曾经入库时，那段历史仍会随推送发出去）、以及**推送前的提交身份报告**（`%h %an <%ae>` 是元数据，内容扫描器抓不到它）。手工 push 时只剩本地 pre-push 兜底闸门在管，而它**按设计不检查推送目的地**（只扫本次推送范围的内容）。只有在 `apply` 根本跑不起来（例如机制脚本自身损坏、`.sync/plan.json` 之外的状态无法读）时才手工推送，并且要明确说清这一轮绕过了上面哪几道闸门。

`apply` 不会设分支跟踪（它推的是 `origin local`，不带 `-u`）—— 机制不需要它（判据是本克隆的 `refs/remotes/origin/*`）。确实想要的话，在推送成功之后由人自己执行一次纯本地的 `git branch --set-upstream-to=origin/local local`。

- [ ] **Step 5: 清理旧克隆（M7）**

经用户确认后删除 v6.3.0 旧克隆（该路径在工作区外，由用户执行或在弹框中授权）：
```bash
rm -rf ~/.dsh/superpowers-src
```
Expected: 目录不再存在。

- [ ] **Step 6: 记录一次完整闭环的验证结果**

把 Task 11 与 Task 12 的实际输出（I1/I2 结果、测试通过情况、plan 报告、push 结果、用户对运行时发现的确认）汇总成一段汇报给用户，标明哪些是实测输出、哪些是用户确认；**不得**在未看到输出的情况下声称某项通过。

---

## 实施与计划的差异

上面是**历史记录**，一个字都不改写（**唯一的例外是 Task 12 Step 4**：那是一步尚未执行的交接指令，而它原来的"手工 `git push`"会绕过审批门，见下面第 9 条——指令写错的部分在此就地改正）。以下是收尾（Task 11）时补记的差异清单：实际落地的代码经过多轮评审，在这些点上与正文的代码草案不同。只读正文的人应当知道每一处的最终形状。

1. **扫描器 `--range` 的语义改为按对象寻址。** 正文 Task 4 的 `collect_files` 在 `range` 一档用的是 `git diff --name-only --diff-filter=ACMR "$RANGE"`（右端修订的路径清单）。最终实现扫的是该范围**新引入的全部 blob**（`git rev-list --objects B --not A`），按对象 id 去重、每个 blob 只读一次 —— 提交 A 加进密钥、提交 B 把文件删掉或改干净时，右端什么都看不到，那份字节却照样会随推送永久留在远端历史里。又因为对象清单每个 blob 只给**一个**路径，pathname 规则与"该不该跳过"另在范围的**全名清单**（右端 ACMR 名字 ∪ 对象清单打印的路径）上评估。单个修订（无 `..`）被拒绝（exit 2）。
2. **测试夹具里的端口是合成值。** `tests/upstream-sync/test-scanner.sh` 里的本地端点（`127.0.0.1` 加端口）是净化时换上的假值，不对应任何真实服务；邮箱、密钥类字面量同样在运行时拼接。
3. **`.sync/` 守卫的最终形状。** 正文 Task 4 的 `is_skipped` 只跳过 `patterns.tsv`。最终实现里扫描器**还**跳过 `.sync/` 下的路径（白名单按定义含"规则 + 路径 + 原因"，不排除会自我指涉地卡住）；`apply.sh` 另加两道守卫：任何变更**之前**查已跟踪集（命中即 exit 5，此时本地零痕迹、不必重新 plan），推送前再查**推送范围的历史路径**（`.sync/` 先提交后删除的仍会随推送发出，命中即 exit 5）。**豁免的粒度在收口时又收窄了一次**：旧实现写的是 `*/patterns.tsv` 与 `*/"$SYNC_STATE_DIR"/*`（任意目录、任意层级），而两道守卫都是**根锚定**的（pathspec `.sync/`、行首 `.sync/`）—— 两者之间的缝（`skills/<x>/patterns.tsv`、嵌套的 `skills/<x>/.sync/**`）会让一份凭据既不扫也不拦地推上远端。现在跳过集只剩一项且精确到位：**仓库根**的 `.sync/*`（机制自己的那一个规则表文件当时还在豁免里，收尾时被整条删除——见下面第 12 条）。
4. **`apply.sh` 的早退条件收紧了。** 正文 Task 6 是 `if [ "$CHANGED" = "0" ]` 就报"无需变更"退出 0。最终实现要求"**没有事要做**（`CHANGED`=0）**且**没有东西要推（本克隆跟踪引用里没有待推送提交）"两条都满足才早退；否则照走到 push 那一程（含它的全部闸门）。早退处那次计数只是判定用快照，推送范围与推送前闸门在采纳提交**之后**重算。
5. **两条仓库自检按工具可用性条件纳入。** graphviz(`dot`) 与 ShellCheck 缺失时，`tests/writing-skills/test-render-graphs.sh` 与 `scripts/lint-shell.sh` 在本机**必然**失败；`apply.sh` 因此按 `command -v` 条件纳入这两条，跳过时在 stderr 响亮提示，且提示不得早于审批门打印。那是环境缺失，不是代码缺陷。
6. **机制自己的规则表不是 `PLAN_ID` 的输入。** 正文把"扫描结果进哈希"与规则表写在同一段里。事实是：进状态哈希的**只有扫描器的 stdout**，所以把 `patterns.tsv` 改空、改成不可读，或新增一条不会命中任何东西的规则，都**不**让旧凭证失效 —— 规则表坏掉的防线是扫描器以 exit 2 变成"不可用"、再由 apply 的复检处以 5 拦下，不是哈希。
7. **`plan.json` 的作废语义。** 正文 Task 5 在运行末尾写它。最终实现在第一个可能 exit 的守卫（分支守卫、拉取、镜像检查）**之前**先把它改写成 `plan_id` 为空、`refused` 为 true，免得失败的那一次在盘上留下上一次那份"看起来已被批准"的凭证。
8. **运行时可见性按事实说明。** 正文 Task 6/Task 8 草案无条件宣称"运行时是符号链接、新内容即时可见"。最终实现判定到底（是符号链接**且**解析后等于本仓库 `skills/`），否则打印"只在工作区与本地提交里，运行时尚未生效" —— 一次性收敛 M6 尚未执行时，前者是假话。
9. **Task 12 Step 4 的首次推送改走 `apply.sh`（正文已就地改正）。** 正文让人手工 `git push -u origin local`，那是一次绕过审批门的推送：它同时丢掉三样只有 `apply` 才有的检查 —— 推送**目的地**校验（origin 是否指向 upstream、是否配了多个 pushurl）、`.sync/` **推送范围**守卫、以及推送前的**提交身份报告**；手工 push 时只剩本地 pre-push 兜底闸门，而它按设计**不**校验推送目的地（只扫本次推送范围的内容）。因为早退条件已收紧成 `CHANGED=0` **且** `OUTGOING=0`（第 4 条），第一次推送这种"没有 merge/采纳、只有待推送提交"的形状完全可以由 `apply` 自己走完并推送，故正确路径是 **plan → 把报告念给用户 → apply（它自己推）**。手工 push 只保留给"apply 根本跑不起来"这一种情形，且必须说清绕过了哪些闸门。
10. **实现刻意不 `git fetch origin`。** 设计正文 §5 第 1 步把 `git fetch origin` 与 `git fetch upstream main:main` 并列。最终实现只 fetch `upstream`（`plan.sh` 里那一行），**从不** fetch `origin`：判"哪些东西已经发布过了"用的是本克隆已有的 `refs/remotes/origin/*`。代价必须说清 —— 这份跟踪引用偏旧时（例如 `local` 是在另一个克隆里推上去的），`apply` 会照旧视图把早已发布过的提交再走一遍全部闸门：方向保守（可能多做一遍检查后成功，也可能以 5/6 这样的码拒绝），但那不是"远端真有新东西"。加了 `git fetch origin` 就会把一次网络往返塞进审批门之前的路径（并且 `fetch` 失败要定义成什么：拒绝还是继续），这是本轮刻意不做的取舍。
11. **扫描器逐 blob 读取的批量优化：已知、**未开工**。** `--range` 对每个 blob 各起一次 `cat-file`（外加一次判类型的 `cat-file -t`），实测约 **37ms/blob**、本仓库整段范围约 **9.6 秒**，成本与范围线性同阶（首次推送长期分叉的 fork 到分钟级）。批量读取（`cat-file --batch`）本可显著降低成本，但本轮**刻意没有做**：这套机制已经两次因为改动扫描器的枚举/读取路径引入回归（先是一处 pathname 规则盲点，后是一处目录假阳性），收口阶段不做第三次。作为替代，只补了可见性 —— 扫描器在范围扫描的起止各打一行进度到 stderr（对象数、用时），`apply.sh`/`plan.sh` 因需捕获扫描输出而各打自己的起止行；`sync_state_hash` 内部那次扫描仍静默（它只把 stdout 计入哈希），`plan.sh` 在进入它之前另打一行。
12. **规则表的豁免被整条删除（跳过集现在只剩一项）。** 第 3 条记的收窄只把豁免缩到"机制自己的那一个规则表文件"，而**那一条豁免没有任何守卫兜底**：`apply.sh` 的两道守卫都只锚定 `.sync/`，所以写进规则表的凭据会被三道闸门全部跳过、守卫也不拦。豁免的理由是"表正文里写着全部正则与示例，将来某条规则可能匹配到规则表文本"；实测这条理由不成立（把出厂表逐字节复制到非豁免路径上扫，exit 0、零输出），故豁免只是"精确的保险"。最终实现把 `is_skipped` 里那两条 arm（仓库相对写法与绝对路径写法）连同只为它们服务的 `PATTERNS_REL` 一起删除，只保留仓库根的 `.sync/*` —— 跳过集与守卫集从此**逐点相等**。两处副作用值得只读正文的人知道：(a) `--paths skills/upstream-sync` 这条**自净检查**从此真的扫规则表本身（此前每次都被整份跳过，"被跳过"与"干净"不可区分）；(b) 由此出现一条**有意**的新性质 —— 若将来有人的规则正则匹配到它自己那一行定义文本，自净检查会立刻响亮失败（改写方式见 `references/recovery.md`）。回归锚点：`tests/upstream-sync/test-scanner.sh` §12（出厂表干净 × 写入真凭据后 `--paths` 两种写法/`--staged`/`--range` 都必须命中 × 根 `.sync/` 的豁免保留）。
13. **迁移技能包里的第三方被测应用名一并泛化。** 正文 Task 10 只要求"迁入 + 净化"，净化的判据写的是凭据与个人环境（绝对路径、端口、会话标识）。收尾时把**被测对象的名字**也算了进去：它是"我在复盘哪个应用的哪个功能"，属于工作上下文，与本分支"不发布个人身份/工作上下文"的承诺同类（用户裁定：推送前泛化）。最终形状是 `knowledge/INDEX.md` 里那一处改为占位符 `<target-app>`，与该技能包既有的占位符词表（`<analyzed-repo>`、`<app-package>`、`<device-model>` 等）一致；README 式的"迁移 + 净化"描述因此可以照读，但要知道净化范围**包含**第三方被测应用名，而 fork 拥有者本人的公开 handle 与通用内部 API 名**不在**泛化范围内（前者是设计决定 D8 已接受的公开身份，后者是通用词）。
14. **发布前把 `local` 压平为一个提交，逐提交历史另存本地分支 `local-history`。** 收尾时发现一个只净化"右端修订"解决不了的问题：被泛化的旧标识（内部项目名、被测应用名、设备型号）虽然已从**当前**文件里清除，但它们仍存在于**历史里的若干提交树**中（技能包在 `main` 上不存在，整个 bundle 由本分支引入，故这些字节会随首次推送一并发布；而它们不匹配规则表里任何一条，闸门不会拦 —— 这与第 3 条"加完再删"是同一类形状，只是这次没有任何规则能看见它们）。**能修复这一点的只有改写历史**：`git filter-repo` 未安装、`git filter-branch` 可用但会让从第一个受影响提交起的所有 SHA 全部改变，从而让本文件、spec 与 `docs/local/decisions/` 里引用的每一个 SHA 都指向不存在的对象。
   最终采用的方式（用户裁定）：把当前 34 个提交原样另存为**本地分支 `local-history`**（永不推送、只能本地查阅），然后把 `local` 指针 `reset --soft main` 并重新提交为**一个干净提交**，再走 plan → apply 推送。由此得到：(a) 推送出去的历史里不含任何旧标识；(b) **不丢失任何东西** —— 逐提交历史与其中引用的全部 SHA 都仍在本地 `local-history` 上可查，本文档与裁定记录里的 SHA 因此仍然可解析（只是在 fork 上不存在）；(c) 首次推送只需扫一个提交，扫描耗时显著下降（第 11 条的成本随范围线性，这条等于把范围压到最小）；(d) 后续 upstream 更新照常在 `local` 上以合并提交继续，不受影响。
15. **`origin` 的传输方式由 HTTPS 改为 SSH（首次推送时发现）。** 设计正文 §1 基线表只记了 fork 是 `gitweiyan/superpowers`，**并未记录传输方式**；原先 `origin` 两个 URL 都是 HTTPS 写法的这个事实，留档在 `docs/local/decisions/2026-10-10-execution-rulings.md` 的 Ruling R106 里（当时是作为目的地校验"不会误伤真实工作流"的真实前提被记下的）。首次推送时用 HTTPS 认证失败（GitHub 早已不接受账户口令，密码认证必然失败；本机此刻对 HTTPS 到 GitHub 的传输又被限速到超时，这也是收尾阶段多次 `ls-remote` 报 `Operation too slow` 的原因），改用本机 SSH 密钥后立即成功。最终实现：用 `git remote set-url origin` 把 fetch/push 两个 URL 都替换为 SSH 写法的地址，其形状是「用户段 `git` + `@` + 主机 `github.com` + 冒号 + 仓库路径 `gitweiyan/superpowers.git`」。
   **本条正文刻意不写那个字面地址**，这是本条唯一由机制本身逼出来的写法：SSH 地址的「用户段@主机段」形状恰好命中本机制自己的身份规则 `id-email`（正则 `[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}`，本意是抓邮箱），于是第一版文档写完即被三道闸门中的 `plan.sh` 与 `--paths` 拒绝（实测两行命中、exit 1）。处理方式选了闸门首推的**改写**而非加白名单：文档里不需要字面地址也能说清这次变更，而白名单会为本该触发规则的一类串开一个长期口子。**这条也是规则表已知边界的一个实例**：`id-email` 会连带命中任何 scp 风格的 `user@host` 串（SSH 远程地址、`ssh` 配置示例等），库里出现这类串时的正确反应是改写（例如拆开写「用户段 + `@` + 主机段」），不是放宽规则。
   对机制无影响：闸门比较的是 remote **名称**与其 URL 集合，`origin`（SSH 写法）与 `upstream`（HTTPS 写法）本就是两个不同仓库，故目的地校验照常通过；唯一需要知道的是：凡引用 `origin` 传输方式之处（实际只有裁定记录 R106 那一处），现在应读作 SSH 写法 —— 本文档正文与 spec 正文都没有记过 `origin` 的传输方式，因此无需回改。`upstream` 仍保持 HTTPS（公开仓库只读拉取）；若将来 HTTPS 再次被限速导致 `plan.sh` 拉取失败，可同样把 `upstream` 的 URL 换成同一 SSH 写法（换掉所有者与仓库名即可），`upstream` 的 push URL 保持禁用标记不变。
16. **首次推送后发现：这个克隆的 `origin` fetch refspec 是窄的，设计里"推送后范围收敛"与"无事可做则早退"两条在本克隆**永久**失效（已本地修正）。** 第 10 条已预告过一个代价："这份跟踪引用偏旧时，`apply` 会照旧视图把早已发布过的提交再走一遍全部闸门"。首次推送后实测发现实情比"偏旧"更硬：**该引用根本不会出现**。根因是这个 fork 克隆当年是 `--single-branch` 浅克隆（后经 M1 `fetch --unshallow` 补全历史），留下的 refspec 只有一条 `+refs/heads/main:refs/remotes/origin/main`；`git push origin local:local` **不会**建立 `refs/remotes/origin/local`，连 `git fetch origin` 也不会（实测：fetch 后该引用仍不存在，因为它不在 refspec 的映射范围内）。两处后果都在同一个视图上：
    - **G3 扫描范围不收敛**：`apply.sh:362` 附近的判断是"`refs/remotes/<origin>/<branch>` 存在就用 `origin/local..local`，否则用 `main..local`"，于是每次 apply 都按更大的 `main..local` 重扫（首次实测 53 个对象、2 秒）。**方向保守，无正确性影响**，只是设计里"范围随发布次数收敛"这条不成立。
    - **`OUTGOING` 早退判定失效**：`count_outgoing()` 是 `git log local --not --remotes=origin`。推送成功后实测计数仍为 **1**（应为 0），因此 `CHANGED=0` 时早退条件 `CHANGED=0 AND OUTGOING=0` 不成立 —— 会把"确实无事可做"报成"有 1 个提交要发"，跑完全部闸门（含 472 条断言的自测）再加一次 no-op 推送。不危险，但与设计意图相反。
    - **修正方式（一次性、只改克隆的本地 config，不入库不推送）**：`git config --add remote.origin.fetch '+refs/heads/local:refs/remotes/origin/local'` 然后 `git fetch origin`。实测修正后 `refs/remotes/origin/local` = `46dbd19` = `local`，`count_outgoing` 归 **0**，第 187 行 G3 那条"之后为 `origin/local..local`"从此真正生效。
    - **为什么不改脚本**：机制刻意不 fetch `origin`（第 10 条，那是一次已裁定的取舍：不让网络往返与它的失败语义进入审批门之前的路径）。把 refspec 修好是把同样效果做在配置层 —— 零脚本改动、零新增网络调用（`plan.sh` 仍只 fetch upstream），代价是"换一台机器重新克隆时必须重做这一步"。**新机器上重建本机制的清单因此多一项**：克隆后检查 `git config --get-all remote.origin.fetch`，缺 `local` 那一条就补上。
