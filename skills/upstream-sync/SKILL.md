---
name: upstream-sync
description: Use when 需要同步 superpowers 上游更新 / 接取 upstream 更新 / 把 upstream 新提交合入你的分支 / 把本地新增技能同步进 fork / 更新你的 fork / 发布技能到远端仓库 / 想知道这批要推的内容里有没有密钥、凭据等敏感信息、推送安全吗（推上去安不安全）、推之前先扫一下 / 要在本仓库装 pre-push 兜底闸门，or when a session must sync upstream commits into the local branch, adopt locally written skills into the fork, publish to the fork, scan for secrets or credentials, check whether a push is safe, or install the fallback pre-push hook (sync upstream, pull upstream updates, merge upstream, adopt local skills, push to fork, safe to push, upstream-sync)。
---

# Upstream Sync

## Overview

本仓库是 superpowers 的 fork，内容单向流动：

```
remote: upstream（只读）  →  main（upstream 的纯净镜像 ref，永不 checkout）
                          →  local（永久 checkout 的工作分支，只做纯新增）
                          →  运行时技能根 ~/.dsh/skills（一次性收敛 M6 之后，见下面"本地新增技能"的前提检查）
```

- 你的全部内容都在 `local` 上，且**只做纯新增**：`main...local` 的每一行状态都必须是 `A`。
- 机制本体就是这个技能包：四个入口脚本（`scripts/plan.sh`、`scripts/apply.sh`、`scripts/scan-sensitive.sh`、`scripts/install-pre-push.sh`），外加共用的 `scripts/sync-lib.sh` 与规则表 `scripts/patterns.tsv`。本文件是入口，深度细节在 `references/`。
- **推送原则**：任何推送到远端的内容都不得包含 API key、凭据、个人身份或个人环境信息 —— 命中即硬失败。这是这套机制存在的理由，全文见 `references/hard-rules.md`。

## 快速参考

| 目的 | 命令 |
|---|---|
| 出计划（不碰工作区与索引；镜像 ref `main` 只由 fetch 更新，永不 checkout） | `bash skills/upstream-sync/scripts/plan.sh [--no-fetch]` |
| 落地（有东西要推就推） | `bash skills/upstream-sync/scripts/apply.sh --plan-id <hash> [--adopt] [--no-push]` |
| 单独扫一批文件或目录 | `bash skills/upstream-sync/scripts/scan-sensitive.sh --paths <path…>` |
| 装本地兜底闸门（不入库、不推送） | `bash skills/upstream-sync/scripts/install-pre-push.sh` |

以上命令假定当前目录是仓库根。四个入口脚本按**自身路径**定位仓库，与 cwd 无关（从别处调用就把 `skills/…` 前缀换成指向本仓库该文件的路径）；唯一的例外是 `scan-sensitive.sh --paths`，它的路径参数是相对 cwd 解析的。

## Workflow

1. **出计划（不碰你的工作区）**：`bash skills/upstream-sync/scripts/plan.sh`（不想拉取时加 `--no-fetch`）。

   它不是"零副作用"：除了读，它还会拉取镜像 ref（`git fetch upstream main:main`，`--no-fetch` 可跳过），跑一次 `git merge-tree --write-tree` 冲突预演（它会在 `.git/objects` 下留下这次预演合并出来的松散对象 —— 不写 ref、不动索引与工作区，但对象库确实变大了），并写两个本地产物 —— `.sync/plan.json`（计划记录）与 `.git/info/exclude` 里的一行 `.sync/`（后者是让本地状态目录不出现在 `git status` 里的必需品）。它**不**触碰工作区、索引与分支。

   范围扫描有成本（本仓库实测约 37ms/blob、整段范围约 10s，首次推送长分叉可达分钟级），故 `plan.sh` 在扫描起止各打一行进度到 stderr（"开始扫描范围 …"／"范围扫描完成：用时 N 秒"），并在进入状态哈希那一步之前再打一行 —— 慢不等于卡死，但你要能看见它在动。

   把整份报告念给人类伙伴，并把**最后一行** `PLAN_ID=<64 位十六进制>` 原样交给他 —— 那就是审批凭证。

   判据是**退出码与"有没有 `PLAN_ID` 行"**，不要只搜 `REFUSED` 这个词：`plan.sh` 的敏感信息拒绝打印的是"扫描命中 … 已阻断"，并没有 `REFUSED` 字样。**没有 `PLAN_ID` 行，就没有可审批的计划**，先处理报告列出的问题。

   工作区应当在 plan 之前就是干净的。`plan.sh` 容忍脏工作区并照常出计划，但那份计划的凭证绑定的是脏状态，而 `apply.sh` 会以 exit 4 拒跑 —— 唯一的例外是 `?? skills/…` 这类未跟踪路径（脚本按这个字面前缀放行，比"待采纳的目录"更宽，例如 `skills/` 下随手放的未跟踪文件也算）。

   报告里"冲突预演"非空时，plan 不拒绝、仍给凭证，但那次 apply 必然以 exit 7 被拒 —— 先给同名技能改名，再重新 plan。

2. **等同意**：人类伙伴明确说同意 / 可以 apply 之后才继续。你自己"读过报告"不是同意。

3. **落地**：`bash skills/upstream-sync/scripts/apply.sh --plan-id <PLAN_ID>`；有游离技能要采纳时加 `--adopt`。

   `--no-push` 只跳过最后那次 `git push`，**不跳过**推送目的地的安全检查。apply 以非 0 退出时按其退出码对应处置，逐条见 `references/recovery.md`。

4. **汇报**：报出 merge 的提交、采纳的技能、push 结果；运行时根是指向本仓库 `skills/` 的符号链接时，新内容此刻已在运行时可见（不是符号链接就谈不上这一点）。

## 本地新增技能

前提是运行时技能根确实是指向 `<repo>/skills` 的符号链接（一次性收敛 M6）。先确认：

```bash
ls -ld ~/.dsh/skills     # 期待 lrwxr-xr-x … -> …/skills
```

若它还是**普通目录**（本步骤尚未执行），建在 `~/.dsh/skills/<name>/` 里的技能**不在**仓库里 —— 此时直接把技能建在 `<repo>/skills/<name>/` 下。

建立 `skills/<name>/SKILL.md` 之后：

- `name` 必须等于目录名；`description` 必须非空；包内**不得**有嵌套 `SKILL.md`（DSH 不支持嵌套发现）。这几项由 `apply --adopt` 的采纳步骤校验，不满足即以 exit 2 拒绝 —— `plan.sh` 只把目录名列进报告，不会替你校这些。
- `plan.sh` 会把它列进"游离技能"。
- 人类伙伴同意后：`apply.sh --plan-id <hash> --adopt` 会 `git add` 该目录并提交（提交信息 `sync: 采纳本地新增技能`），随后走同一道 push 门。
- 说明性文档不是技能：放 `docs/local/`，由本人 `git add` + `git commit`（`--adopt` 只采纳 `skills/` 下的未跟踪目录）。提交之后照常走 plan → apply：**只要本克隆的 `refs/remotes/origin/*` 里没有这些提交，apply 就会走到推送那一程**，哪怕这一轮它自己既没有 merge 也没有采纳。比的是这个克隆的跟踪引用 —— `plan.sh` 只 fetch `upstream`、从不 fetch `origin`，所以若 `local` 是在别处推上去的，跟踪引用会是旧的：apply 会照着旧视图把已经发布过的提交再走一遍闸门（方向保守，但可能以 5/6 这样的码拒绝，那不是"远端真有新东西"）。手工直接 `git push` 时，管的就只有本地兜底闸门了。

## 红旗（Red Flags）

| 想法 | 事实 |
|---|---|
| "报告看起来没问题，我直接 apply 吧" | 审批门是给人的。"我读过了"不是同意。 |
| "这个命中大概是误报" | 闸门是硬失败：改写（首选）、移出仓库，或由本人写入白名单。没有第四条路。 |
| "先把 `main` 更新一下" | 永不 checkout `main`；它只由 `plan.sh` 的 `git fetch upstream main:main` 更新。 |
| "顺手改一下上游那个文件" | 纯新增是唯一约定；一改就破坏 I2，plan 会以 exit 2 拦下。 |
| "先 push 上去再修" | 远端历史不可回收。修完再推。 |
| "删掉那个冲突来源的技能就行" | 你的技能是你的资产；冲突处理是**改名**，不是删除。 |
| "`plan.json` 里写着已批准，拿它当凭证" | `apply` 不读那个文件，它重算状态哈希。凭证只有报告最后那行 `PLAN_ID`。 |
| "多算几次哈希更保险" | 每次调用都会重扫范围并跑一次 `merge-tree`；一轮只算一次、两处共用同一个值。 |
| "apply 退出 0 了，那肯定推出去了" | 0 有两支：真的无事可做（输出"无需变更"，什么都没推）与已落地（输出 `push: 已推送到 origin/local`）。看输出那一行，别只看退出码。 |
| "这批是我手工提交的，apply 大概会说'无需变更'" | 早退只在**既没东西要做、也没东西要推**时发生；本克隆的跟踪引用里没有的提交就会让推送那一程跑起来（连同它的全部闸门）。 |
| "apply 说这条路径上有东西要推，那远端一定还没有" | "有东西要推"只看**本克隆的 `refs/remotes/origin/*`**（`plan.sh` 只 fetch `upstream`）。它是旧的话，apply 会把早就发布过的提交再查一遍。 |

## 已知边界

这套机制不承诺超出它实现的保证：它的检测能力就等于 `scripts/patterns.tsv` 里那 16 条规则（规则形状之外的凭据抓不到）、G1 只扫 `local` 这一侧（pending 的上游提交要到 G3 才进扫描集）、"有没有东西要推"只看本克隆的远端跟踪引用而非真的查远端（`plan.sh` 只 fetch `upstream`、从不 fetch `origin`）、远端目的地只做 URL **字符串**比较（同一仓库的 SSH 写法与 HTTPS 写法不会被判为相同）、`--no-verify` 按设计可以绕过兜底闸门、git 把钩子解析到仓库外时钩子会拒绝安装、第一次推送长分叉会扫很多对象而相应变慢（实测约 37ms/blob）、三道闸门共用的跳过集**只有一项**且精确到位（**仓库根**的 `.sync/*`；机制自己的那一个规则表 `scripts/patterns.tsv` 也**照扫**，任何别的同名文件同样照扫，见 `references/hard-rules.md`）、范围扫描看不见"git 给出的路径恰好在跳过清单上、而另一个名字已在范围内被删除"的凭据类文件。逐条陈述见 `references/hard-rules.md`。

## 参考

- `references/hard-rules.md` —— 硬规则逐条、推送原则、`upstream` 的禁用 push URL，以及每条保证的边界
- `references/recovery.md` —— 退出码表、失败处置表、merge 与运行时根的回滚
