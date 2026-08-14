# Autonomy policy

The agency runs unattended on a dedicated machine. Nobody is awake to approve anything, so every
limit here is a rule the box enforces on itself rather than a question it asks a human. A gate that
requires a person is not a safety measure at three in the morning — it is just a stall.

The design rule throughout: **prefer a mechanical gate over a human gate, and prefer a recoverable
action over an approval.** Anything git can undo needs no permission. Anything git cannot undo needs
a rule, not a prompt.

## Pre-authorized, no approval, no announcement

- All local git: add, commit, branch, checkout, merge, worktree lifecycle, stash, tag.
- **Push to a remote**, on any branch except the default branch.
- **Create repositories**, private by default.
- Open, update, and comment on pull requests.
- Delete branches and worktrees the agency created.
- Install dependencies, run builds, run test suites, run the lanes.
- Deploy to preview and staging environments.
- Write and rewrite docs, specs, handoffs, memory entries, and this policy's siblings.

## Gated by a rule, not by a person

| Action | Rule that must hold |
|---|---|
| Push to the default branch | Gate green on the exact commit being pushed, and the push is a fast-forward |
| Merge a pull request | Gate green, no unresolved conflict, branch not the default branch's parent |
| Deploy to production | Gate green, plus the previous production deploy is older than the rollback window |
| Create a public repository | Secret scan clean, and no path outside the repo is referenced |
| Spend money | Under the per-run cap, under the daily cap, and the ledger write succeeded first |
| Delete a file the agency did not create | The file is tracked by git in a repo with a remote that has it |

A rule that cannot be evaluated counts as failed. Silence is not a pass.

## Full autonomy, with recoverability instead of restriction

When the operator grants full autonomy, force-push, history rewrite, file deletion, deploys, and
repository administration are all permitted. The agency does not ask before any of them.

The safety model is therefore recoverability rather than prohibition. An action that can be undone
needs no gate; the job is to make sure everything remains undoable. Two mechanisms carry that weight
and must stay working:

- **An off-box mirror, refreshed nightly**, of every repository the agency touches, including refs
  that a force-push would otherwise orphan (`git clone --mirror`, or `git push --mirror` to a backup
  remote). A rewrite that only exists on the mini is a rewrite nobody can undo.
- **A `HALT` file check before every dispatch**, so a runaway loop stops at the next unit boundary
  without needing a signal, a network round trip, or a login.

Two hard stops remain, and neither is a judgment call about risk:

- **Never commit, push, or transmit a credential.** Not caution — a leaked key is the one failure that
  cannot be rolled back by any backup, because the copy is already elsewhere.
- **Never spend past the daily cap.** The cap is a hard stop, not a target. Exceeding it halts the run
  and leaves the ledger and a reason on disk.

Everything else is the agency's call. When it takes a destructive action, it records what it did and
what would restore it, in the same place it records everything else.

## Budget

Spend is governed by `.orch/budget.json` and recorded in `.orch/spend-ledger.jsonl`. The ledger is
written before the spend, not after, so a crash mid-run overstates rather than loses cost.

Only grok reports real dollars today; codex and kimi are flat-rate subscriptions where token counts
measure consumption rather than spend. Any paid API a project itself calls must go through the same
ledger, or the cap is fiction.

When the daily cap is reached the agency stops dispatching, finishes what is already running, writes
a digest, and waits for the next day's window. It does not degrade to a cheaper model and continue —
silently buying worse work with the same money is the failure mode that looks like success.

## Kill switch

A file named `HALT` in the orchestrator directory stops all dispatch at the next unit boundary. It is
checked before every dispatch, costs nothing to check, and requires no process signal or network
access to trigger. Removing the file resumes.

## What still reaches a human

Only two things, and neither is a routine operation:

1. A decision that spends money outside the budget mechanism, or changes the cap itself.
2. Anything a rule above could not evaluate — an unknown remote, an unrecognized credential prompt, a
   deploy target the agency has never seen. The correct behavior is to halt that unit, record why,
   and continue with the rest.
