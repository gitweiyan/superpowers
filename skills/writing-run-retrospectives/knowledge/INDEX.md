# Knowledge index

One line per sunk knowledge point. A retrospective lists its candidates in the report (section 6) and
writes the file here only **after the user decides**.

| Topic | File | One-line summary | Source |
|---|---|---|---|
| 分支基线导致"修好的代码没在跑" | `branch-base-regression.md` | `git checkout -b <new> <old-base>` rewrites the working tree, so a fix committed on a sibling branch silently vanishes; verify the base by content, integrate explicitly, then re-check with `git diff --stat <branch-with-the-fix> HEAD` | 复盘 20261009-<target-app> · I1（用户于 2026-10-09 决定落地） |
| 陈旧观察竞态：障碍类目标"已消失"如何判定 | `stale-target-races.md` | A vanished obstacle is **cancelled / moot** — never "completed" (marking `[x]` fabricates completion and feeds task termination) and never retried into a failure; the repo's `retired` vocabulary is the precedent. Needs "was there → is now gone → obstacle-class" evidence; obstacle budget 1×XML + 1×pixel | 复盘 20261009-<target-app> · K3（对应 I4；用户于 2026-10-10 修正语义：已消失 = 取消，不是完成） |

## Candidates awaiting a decision

Listed by the 20261009 retrospective (获取电池信息测试 & <target-app>); nothing has been written yet.

| Candidate | Proposed file | Why it transfers |
|---|---|---|
| 无 Google 凭据环境下的静默降级谱系 | `no-google-provider-degradation.md` | One wiring mistake shows up three ways (startup crash, memory-prompt fallback, visual-summary failure); the log signatures tell you which |
| 运行取证速查 | `run-forensics.md` | `traces.payload.message` is the truth while `status` says success; `check_ledger` inconclusive semantics; when the archive is empty, read the DB |
| 时间线静默间隔判据 | `timeline-gap-detection.md` | A >15 s gap (or >3× median) must become its own timeline entry — that is how a 30 s probe timeout surfaced |
| 运行前断言"代码身份" | `assert-code-identity.md` | The pre-run check that would have caught the branch-base regression before spending a device run on it（对应 I2；代码已于 2026-10-10 落地为"运行开始记录身份"，沉淀待写） |
