# Branch-base regression: the fix is committed, the working tree is not standing on it

## Symptom

A run behaves as if a fix you already landed does not exist — same error text as before the fix —
while a run minutes earlier on "the same code" was clean.

## Mechanism

`git checkout -b <new> <older-base>` moves the **working tree** to that base, not just the branch
pointer. Every fix committed on another branch disappears from disk, and nothing warns you: processes
start, the device attaches, the task completes, and the failure only shows up as degradation in logs.

## Evidence (2026-10-09, `<analyzed-repo>`)

| When | Tree contained the provider-aware lens fix | `Transcript prompt path failed` | `Failed to dispatch visual step summary` |
|---|---|---|---|
| 17:38–17:43 (6 runs) | yes | 0 | 0 |
| 18:32 (one run, after `git checkout -b … fix/helper-token-provider`) | no | 9 | 8 |

At that moment no single branch held all four lines of work:

| branch | tip | provider-aware lens | device e2e case | probe deadline |
|---|---|---|---|---|
| `fix/helper-token-provider` | 4cd590a | – | – | – |
| `fix/provider-aware-lenses` | 72e0c5d | yes | – | – |
| `test/e2e-battery-level-case` | e022a01 | yes | yes | – |
| `fix/helper-probe-deadline` | f7e2844 | **–** | – | yes |

## Discipline

1. **Name the base explicitly, and verify it by content** — never by branch name or date:
   `git show <base>:path/to/file | grep -c <marker>`.
2. **Integrate explicitly.** If the work spans several branches, merge/cherry-pick them and re-verify.
   "Current HEAD is newest" is an assumption, and it is wrong whenever a fix was committed on a
   sibling branch.
3. **Check for silent reversions right after branching or merging:**
   `git diff --stat <branch-that-has-the-fix> HEAD -- <paths>` — only additions are expected; a
   deletion of the fix *is* the defect.
4. **Assert code identity before any run whose result you intend to trust:** branch, HEAD, dirty
   files, and one grep per fix that must be live (see the snippet below).
5. **Never commit a fix and then switch to a branch based on an older commit in the same session**
   without re-running step 3.

## Copy-paste check

```bash
BASE=<branch with the most coverage>          # verify by content, not by name
git show $BASE:<analyzed-repo>/agents/flash/summarizer.py | grep -c get_llm_for_model   # must be > 0
git checkout -b <new-branch> $BASE
git merge --no-edit <branch holding the rest>                                    # integrate explicitly
git diff --stat <branch holding the rest> HEAD -- <analyzed-repo>/ tests/                # empty = nothing lost
printf 'branch=%s head=%s dirty=%s\n' "$(git branch --show-current)" "$(git rev-parse --short HEAD)" \
       "$(git status --porcelain | tr '\n' ' ')"
```

A single branch that contains every line of work is cheaper to reason about than a matrix of branches:
prefer integrating before starting the next change, not after the next surprise.
