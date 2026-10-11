# Superpowers 本地迭代机制设计（upstream ↔ fork ↔ 运行时）

- 日期：2026-10-10
- 状态：待人工评审
- 适用范围：`~/Documents/code/superpowers`（fork `gitweiyan/superpowers`）、`~/.dsh/skills`（DSH 运行时技能根）、upstream `obra/superpowers`

> 本文件位于 `docs/local/`，即 fork 私有路径。upstream 不拥有 `docs/local/`，因此它不会与任何 upstream 更新冲突，也不会被误当作可贡献内容。
> 本文件在一次性收敛的首次提交（M4）之前保持未跟踪状态，并随 M4 一起进入 `local` 分支的第一次提交。

## 0. 目标与非目标

### 目标

1. **经同意后接取 upstream 更新**：能把 `obra/superpowers` 的新提交合入你的工作分支，且合入前你能看到一份可审阅的影响报告；未获同意则不改动任何状态。
2. **本地新增同步进代码库**：你在运行时目录里新增的技能，能可靠地进入 fork 的 `local` 分支并推送，且**不存在两份拷贝、不存在漂移**。
3. **持续迭代**：整个流程可重复执行，每次都由同一套规程与同一道审批门把关，不依赖某一次会话的临场发挥。
4. **零敏感信息外泄**：任何推送到远端的内容先过敏感信息闸门；命中即硬失败。

### 非目标

- 不向 `obra/superpowers` 提交 PR（AGENTS.md 明确：fork 定制 PR、领域专用技能、无真实会话证据的改动都会被关闭）。你的 fork 即私有发行版。
- 不修改 upstream 拥有的任何文件内容（只做纯新增）。
- 不自动跟随 upstream 发版节奏（不做无人值守的自动 merge / 自动 push）。
- 不处理其他 harness（Claude Code / opencode / Codex 等）的插件安装状态；本设计只负责仓库内容与 DSH 运行时的一致性。**注意**：因为共享同一份 `skills/` 目录，自建技能会被这些 harness 插件一并发现 —— 这是预期结果（仓库自带的 opencode 注册测试是按目录动态推导期望值的，不会因此失败），本设计不做额外隔离。

## 1. 现状基线（已核实事实）

| 位置 | 内容 | 版本 / 状态 | Git |
|---|---|---|---|
| `~/.dsh/skills/` | DSH 运行时技能根（user 级，发现 rank 400） | superpowers **v6.3.0** 内容 + 1 个自建技能 | **不是** git 仓库 |
| `~/.dsh/superpowers-src/` | `obra/superpowers` 的克隆（当年的安装来源） | v6.3.0，工作区干净，跟踪 `origin/main` | 是 |
| `~/Documents/code/superpowers` | fork 克隆 `gitweiyan/superpowers` | v7.0.0 = `bb92a77`，与 upstream main **同一提交**；**浅克隆 depth=1**；无 `upstream` remote | 是 |

补充事实：

- fork 上只有 `main` 一个分支；`main` = `upstream/main` = 本地 HEAD = `bb92a77`。
- 自建技能为 `writing-run-retrospectives`，只存在于 `~/.dsh/skills/`，未被任何仓库跟踪。
- 除该技能外，`~/.dsh/skills/` 与 `~/.dsh/superpowers-src/skills/`（v6.3.0）**逐文件一致**；与仓库 v7.0.0 的差异全部来自 upstream 自身的版本演进。
- 本环境 git 2.50.1，支持 `git merge-tree --write-tree`（可在不触碰工作区的前提下预演冲突）。
- 本环境到 GitHub 的网络可达；`pre-commit` 未安装，且 `.pre-commit-config.yaml` 的钩子只作用于 `evals/*.py`，对本机制的提交无影响。
- 当前 git 身份：`user.name=gitweiyan`，`user.email` = **全局 git 身份邮箱**（取自全局 `~/.gitconfig`；本文件不复写其原文）。
- 当前会话沙箱为 workspace-write，**写入 `~/.dsh/skills/` 被拒绝**（`Operation not permitted`），因此涉及该目录的改造必须由人执行或单独提权。
- DSH 技能发现支持符号链接：provider 的 `followSymlinks` 默认真，根为链接时先 realpath；技能包格式为单层 `<name>/SKILL.md`，**不支持嵌套 `**/SKILL.md`**。
- 自建技能中已存在个人环境信息：`CREATION-LOG.md:10` 与 `assets/report-example.html:74` 含被复盘仓库的绝对路径，`assets/report-example.html:124` 含一处本地服务端点。

## 2. 决策记录

| # | 决策 | 结论 |
|---|---|---|
| D1 | 真源与角色 | fork 的 `main` 永远等于 upstream `main`（纯净镜像）；自定义内容全部落在独立工作分支 |
| D2 | 工作分支 | 命名 `local`；主工作区**永久** checkout `local`，`main` 永不 checkout |
| D3 | 运行时安装方式 | `~/.dsh/skills` 改为指向 `<repo>/skills` 的符号链接 |
| D4 | 审批机制 | plan / apply 双阶段：plan 只读出报告，apply 需携带与当前状态匹配的 `PLAN_ID` 才执行 |
| D5 | 自定义边界 | 只做纯新增：自定义技能一律放 `skills/<新目录>/`，不修改 upstream 拥有的文件 |
| D6 | 推送原则 | **绝不向远端推送 API key 等凭据、以及个人身份 / 个人环境信息**；命中即硬失败 |
| D7 | 打包方式 | 机制自包含于 `skills/upstream-sync/`（`SKILL.md` + `scripts/`），技能即入口 |
| D8 | 提交身份 | **保持现状**：`gitweiyan` / 全局 git 身份邮箱，不加仓库级覆盖。G3 仍报告提交身份，身份与预期不符时才拦截 |
| D9 | 兜底闸门 | 启用本地 `.git/hooks/pre-push`（不入库、不推送） |
| D10 | 旧克隆处置 | M7 复核通过后删除 `~/.dsh/superpowers-src`（v6.3.0） |
| D11 | `CREATION-LOG.md` | 脱敏后保留在仓库内 |

## 3. 拓扑与不变量

```
obra/superpowers ──(fetch, 只读)──> remote: upstream ──> ref: main (纯净镜像, 永不 checkout)
                                                              │
                                                              │  merge（经审批）
                                                              ▼
gitweiyan/superpowers <──(push)── branch: local (永久 checkout, 含纯新增) ──> 工作区 skills/
                                                                                  │
                                                                                  │ symlink
                                                                                  ▼
                                                                            ~/.dsh/skills
```

**不变量（全部可机械校验，plan 每次检查）**

- **I1 镜像**：`git rev-parse main` == `git rev-parse upstream/main`；`main` 上不存在任何仅属于本地的提交。
- **I2 纯新增**：`git diff --name-status main...local` 的每一行状态都是 `A`；出现 `M` / `D` / `R` 立即报警并要求人工决策。
- **I3 无敏感信息**：`local` 相对 upstream 的**全部新增内容**通过敏感信息扫描；任何未列入本地白名单的命中都阻断推送。

## 4. 一次性收敛（M1–M7）

| 步骤 | 动作 | 执行者 |
|---|---|---|
| M1 | 补全历史并接入 upstream：`git fetch --unshallow origin`；`git remote add upstream https://github.com/obra/superpowers.git`；把 `upstream` 的 push URL 设为不可用值；`git fetch upstream main` | 我 |
| M2 | `git switch -c local`（自 `main` 切出；此后 `main` 永不再 checkout） | 我 |
| M3 | 净化 + 迁入自建技能：把 `writing-run-retrospectives/` 复制进 `skills/`，并做敏感信息与 frontmatter 净化（见 §6）。**不删除** `~/.dsh/skills/` 下的原目录 —— 去重由 M6 的符号链接替换完成 | 我 |
| M4 | 在 `local` 上提交：`skills/upstream-sync/`（机制本体）、净化后的自建技能、`docs/local/specs/` 本设计文档 | 我 |
| M5 | 安装本地兜底闸门：`.git/hooks/pre-push`（不入库、不推送） | 我 |
| M6 | 替换运行时根：备份 `~/.dsh/skills`，建立指向 `<repo>/skills` 的符号链接 | **你（我弹框给出可直接粘贴的命令，你执行后反馈结果）** |
| M7 | 收尾：新开会话复核 catalog 完整性；确认后删除 `~/.dsh/superpowers-src` 旧克隆 | 你 + 我 |

### M1 细节

浅克隆必须补全历史：depth=1 时 `merge-base` 不可靠，直接 merge upstream 会退化成"两棵无共同祖先的树合并"，产生大量假冲突。补全后 `merge-base main upstream/main` 才有意义。

`upstream` 的 push URL 置为不可用值（例如 `DISABLED-no-push`），使误推 upstream 在物理上不可能，而不是依赖纪律。

### M3 细节

自建技能当前含个人环境信息，**必须先净化再提交**：

- 把被复盘仓库的绝对路径替换为占位符（如 `<analyzed-repo>`）。
- 示例报告里的本地端点、会话标识、机器相关取值做脱敏或改为通用示例值。
- `CREATION-LOG.md`：**脱敏后保留**（已定，见 §10）—— 它记录该技能的设计取舍，有长期价值；但需逐条清理个人环境痕迹。
- frontmatter 校验：`name` 为 kebab-case 且与目录名一致、`description` 存在且可触发、包内无嵌套 `**/SKILL.md`（DSH 明确不支持嵌套发现）。

技能内容本身按 `writing-skills` 的口径审查一遍（它是仓库自带技能，可直接调用）。

### M6 交接协议

这是本机制里风险最高的一次性操作（动的是运行时技能根），因此由你亲手执行：

1. 我通过界面弹框给出**完整、可直接粘贴**的命令（备份 + 建链接 + 校验三步）。
2. 你执行，然后把输出（成功或报错）反馈给我。
3. 我据此判断是否进入 M6；若失败，恢复备份后重新设计这一步。

命令形态（执行时以弹框中的实际文本为准）：

```
mv ~/.dsh/skills ~/.dsh/skills.bak-v6.3.0-20261010
ln -s ~/Documents/code/superpowers/skills ~/.dsh/skills
ls -l ~/.dsh/skills && ls ~/.dsh/skills | head
```

备份目录**保留到 M7 复核通过之后**再决定删除（届时它同时是 M6 失败时的回退手段）。

## 5. 日常闭环

### 闭环 A：接取 upstream 更新

**plan（只读，零副作用）**

1. `git fetch upstream main:main`（ref-only、只允许快进）与 `git fetch origin`。
2. 计算：upstream 新增提交数与概要、涉及哪些技能、上游版本号变化（`package.json`、`.claude-plugin/plugin.json` 等）。
3. 冲突预演：`git merge-tree --write-tree main local`，**不触碰工作区**即可得到冲突文件清单。
4. 卫生检查：工作区是否干净、当前是否在 `local`、`~/.dsh/skills` 是否仍是指向本仓库的链接、`skills/` 下是否存在未跟踪的目录（游离技能）、`docs/local/` 是否被误改。
5. 不变量检查：I1、I2，以及新增内容的敏感信息扫描（§6）。
6. 输出：人类可读报告 + **`PLAN_ID`**，并落盘 `.sync/plan.json`（本地、不入库）。

`PLAN_ID` 的定义（必须精确，否则审批凭证无意义）：对以下输入做规范化拼接后取 SHA-256 ——
`upstream/main` 提交号、`main` 提交号、`local` 提交号、工作区脏文件清单及其 blob 哈希、未跟踪技能目录清单、冲突预演结果、敏感信息扫描结果摘要。**任何一项变化都会改变 `PLAN_ID`**，从而使旧的同意失效。

`.sync/` 通过 `.git/info/exclude`（本地文件，不随仓库推送）排除，**不修改 `.gitignore`** —— 后者属 upstream 拥有的文件，改它就破坏了 I2。

**审阅**：报告在会话中呈现给你；你说"同意"。

**apply --plan-id `<hash>`**

1. **重算当前状态哈希并与 `PLAN_ID` 比对；不一致直接拒绝执行**（远端又有新提交 / 工作区变化 / 计划过期），要求重新审阅。这是"同意"的凭证，防止用过期评审结果落地。
2. 前置条件检查：工作区必须干净，**唯一允许的例外**是本次即将 `--adopt` 的游离技能目录；否则拒跑（绝不 stash、绝不覆盖你的未提交改动）。
3. `git merge --no-ff main`（预期无冲突；若 merge-tree 已报冲突，则 apply 拒跑，改由人工决策）。
4. 运行仓库自检：`tests/writing-skills/test-render-graphs.sh`、`tests/opencode/test-skill-registration.mjs`；有 shell 改动时追加 `scripts/lint-shell.sh`。
5. 敏感信息扫描（对将推送的提交范围，见 §6）。
6. 全部通过后 `git push origin local`。

任一环节失败即停止，不 push。

### 闭环 B：把本地新增同步进代码库

关键性质：因为 `~/.dsh/skills` 是指向本仓库工作区的符号链接，"运行时里的新增"与"仓库里的文件"**是同一份字节**。因此"同步进代码库"退化为 `git add` + commit + push，不需要任何双向拷贝，也不可能产生漂移。

- plan 会把 `skills/` 下未跟踪的目录识别为游离技能，做 frontmatter 校验与敏感信息扫描后列进报告。
- `apply --adopt`：`git add` 这些技能并提交，随后走闭环 A 的**同一道** push 门。
- 删除技能：`git rm -r` + 提交 + push；运行时即时生效（软链接）。
- 自定义内容落位规则：技能一律 `skills/<新目录>/`；说明性文档一律 `docs/local/`。

### plan / apply 的边界

- plan 永不写入仓库（除 gitignored 的 `.sync/`）。
- apply 永不修改 `main`、永不 checkout `main`、永不动 `upstream`。
- 两者都不碰运行时目录本身（软链接带来的"即时生效"是副产物，不需要也不允许额外写入）。

## 6. 敏感信息与推送原则

### 原则

**任何推送到远端的内容，都不得包含 API key、访问令牌、口令等凭据，也不得包含个人身份信息与个人环境信息。** 命中即硬失败，不做"看起来不像真的所以放过"的判断。

### 三道闸门（同一套规则，作用于不同范围）

| 闸门 | 时机 | 范围 |
|---|---|---|
| G1 | plan 阶段 | `main...local` 的全部新增内容 + 未跟踪的游离技能 |
| G2 | commit 前 | staged 内容 |
| G3 | push 前 | 即将推送的提交范围（首次推送为 `main..local`，之后为 `origin/local..local`） |

三道闸门都由 apply 脚本执行；G3 是最后一道，也是唯一一道在"内容已经成型"之后仍能阻断外泄的闸门。

### 检测类别

- **凭据形态**：主流的云厂商与服务令牌前缀，以及通用的 `api_key / secret / token / password / credential` 赋值形态，以及 PEM/OPENSSH 私钥块。
- **凭据文件**：`.env`、`*.env.*`、`credentials*`、`*.pem`、`*.key`、`*.p12`、`id_rsa*`、`.netrc`、`.npmrc`、`*_history`。
- **个人身份**：真实姓名、非 GitHub 账号的邮箱、手机号。
- **个人环境**：绝对家目录路径（`~/...`）、机器名、内网域名与内网 IP、本地端口与服务标识。
- **本仓库特定**：`docs/local/` 之外出现的本机绝对仓库路径（如 `~/Documents/code/superpowers`）；任何形如会话 ID / 运行 ID 的内部标识。

命中的处理：apply 终止并输出"文件:行 + 类别 + 脱敏片段"，由你选择 —— 改写（首选）、移出仓库、或写入白名单并说明理由。白名单文件 `.sync/allowlist.txt` **本地、不入库、不推送**，且只允许记录"类别 + 路径 + 原因"，**禁止**记录原文片段。

### 已知会命中的存量内容

自建技能中被复盘仓库的绝对路径（2 处）与一处本地服务端点（1 处）会在 M3 净化阶段处理；净化完成前不得执行 M4 提交。

### 提交身份也是外泄面

每个推送到 GitHub 的提交都带作者与提交者身份，**这是元数据，G1–G3 的内容扫描器抓不到**。因此 G3 除扫描内容外，还必须报告即将推送范围内每个提交的 `author` / `committer` 姓名与邮箱，与预期不符时要求你确认。

机制事实：`git config` 只影响**之后**产生的提交。一旦 M4 提交并推送，该邮箱就进入 fork 历史；此后改配置不会追改历史，只能靠 `git filter-repo` 一类手段重写并强推。因此本项配置必须在 **M4 首次提交之前**决定。

当前状态（已核实）：身份来自**全局** `~/.gitconfig`（`gitweiyan` / 全局 git 身份邮箱），本仓库无仓库级覆盖；fork 现有提交的作者是 upstream 的 Jesse Vincent，**尚无任何属于你的提交**；公开 GitHub 资料的 `email` 字段为 `null`，即该邮箱目前并未公开。所以 M4 会是第一个把该邮箱带进公开历史的提交。

若决定改用 noreply（仓库级覆盖，不影响其他仓库）：

```
git -C ~/Documents/code/superpowers config user.email "<github-numeric-id>+<github-user>@users.noreply.github.com"
```

若你不在意该邮箱公开，则本项无需动作 —— 保持现状即为决定结果。

**已定（D8）：保持现状，不加任何覆盖。** M4 起的提交作者为 `gitweiyan <全局 git 身份邮箱>`，该邮箱会进入 fork 的公开历史 —— 这是明确接受的结果，G3 不再就此项告警（仅当出现与预期不符的其它身份时才拦截）。若将来改变主意，代价是一次历史重写 + 强推（`local` 为独占分支，操作安全）。

### 软链接不构成额外外泄面

符号链接只暴露 `<repo>/skills` 这一个目录；`~/.dsh/` 下的 `.credentials.yaml`、`sessions/`、`storages/` 等都不在链接目标内，不可能被 `git add` 到。同时，apply 的 `git add` 作用域被限制在 `skills/` 与 `docs/local/`，不做 `git add -A`。

### 兜底闸门（已定 D9）

在 `.git/hooks/pre-push` 放置一份与 G3 同源的本地上钩（不入库、不推送），作为"绕过 apply 脚本手工 push"场景的兜底。由 M5 安装。

## 7. 硬规则

1. `upstream` 的 push URL 不可用 → 误推 upstream 不可能发生。
2. 永不 `git push origin main`；永不 checkout `main`；永不在 `main` 上提交。
3. 永不运行 `scripts/bump-version.sh`，版本号一律跟随 upstream（否则每次 upstream 发版必然冲突）。
4. 永不修改 upstream 拥有的文件；由 I2 的"全 `A`"校验兜底。
5. 不向 `obra/superpowers` 开 PR、不提 issue。
6. 自定义内容只落在 `skills/<新目录>/` 与 `docs/local/`。
7. 未获明确同意，不执行 merge、不执行 push。
8. 未经敏感信息扫描通过，不执行 push；白名单只能由你本人添加条目。

## 8. 失败与回滚

| 失败 | 行为 |
|---|---|
| fetch / 网络失败 | plan 报错退出，零副作用；不产生 `PLAN_ID` |
| 冲突预演失败 | apply 拒跑，列出冲突文件；因 D5 纯新增，冲突只可能来自 upstream 也新增了同名技能 → 处理方式是给你的技能改名，而不是去解冲突 |
| `PLAN_ID` 不匹配 | apply 拒绝执行，要求重新审阅 |
| 敏感信息命中 | apply 拒绝执行并列出命中位置，等待你决策 |
| 仓库自检失败 | 不 push；改动留在工作区与本地提交中。**注意此时运行时已经能看到新内容**（软链接的必然结果），脚本必须明确提示这一点 |
| merge 后需回退 | `git reset --hard ORIG_HEAD`（未 push 前有效） |
| push 失败 | 本地提交保留，重试即可 |
| 运行时需彻底回退 | 恢复 `~/.dsh/skills.bak-*` 备份，删除符号链接并改回目录 |

## 9. 验证清单

以下每项都必须**实际运行并看到输出**，不接受"看起来对"：

1. `git rev-parse main` == `git rev-parse upstream/main`（I1）。
2. `git diff --name-status main...local` 输出全部为 `A`（I2）。
3. 用临时分支模拟一次"upstream 新增同名技能"：plan 必须报出冲突，apply 必须拒跑。
4. 用临时文件模拟一次凭据与个人路径命中：G1/G2/G3 三道闸门都必须阻断。
5. 篡改 `PLAN_ID`：apply 必须拒绝。
6. 在 `~/.dsh/skills/`（即被链接的工作区）下新建一个测试技能：plan 必须识别为游离技能，`apply --adopt` 后 `git status` 干净。
7. 新开 DSH 会话：catalog 中 upstream 全部技能 + `writing-run-retrospectives` 齐全，且能成功 `skill()` 载入自建技能（证明软链发现有效）。
8. 仓库自检脚本全绿：`tests/writing-skills/test-render-graphs.sh`、`tests/opencode/test-skill-registration.mjs`。
9. 推送到 fork 后：`git ls-remote origin` 显示 `refs/heads/local`，且 `main` 仍等于 upstream main。

## 10. 决策收尾（原 P1–P4，均已定）

| 项 | 问题 | 决定 | 生效点 |
|---|---|---|---|
| P1 | 提交邮箱是否改 noreply | **不改**，沿用 `gitweiyan <全局 git 身份邮箱>`（D8） | M4 起 |
| P2 | `~/.dsh/superpowers-src` 旧克隆 | M7 复核通过后**删除** | M7 |
| P3 | `.git/hooks/pre-push` 兜底闸门 | **启用**（D9） | M5 |
| P4 | `CREATION-LOG.md` | **脱敏后保留**（D11） | M3 |

未决问题：无。若将来改变 D8 的判断，须在产生更多提交之前处理，处理方式为历史重写 + 强推。
