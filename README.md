# lanes

**Fan-out orchestrator for CLI coding agents.** Decompose work into frozen specs, dispatch each unit to a worker lane — [Codex CLI](https://github.com/openai/codex), [Kimi Code](https://kimi.com/code), [Grok](https://x.ai) — in its own git worktree, verify every unit with a binary gate, and merge only what passed.

[![ci](https://github.com/HiroshiGanatamo/lanes/actions/workflows/ci.yml/badge.svg)](https://github.com/HiroshiGanatamo/lanes/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![bash 5+](https://img.shields.io/badge/bash-5%2B-4EAA25)

```
                  ┌───────────────┐
      units.json  │    run.sh     │    report.json
     specs/*.md ─▶│   dispatch    │─▶  results/*.json
                  └──┬────┬────┬──┘
               ┌─────┘    │    └─────┐
          ┌────▼───┐ ┌────▼───┐ ┌────▼───┐
          │ codex  │ │  kimi  │ │  grok  │   one git worktree per unit
          │ .wt/u1 │ │ .wt/u2 │ │ .wt/u3 │   one binary gate per unit
          └────┬───┘ └────┬───┘ └────┬───┘
               └─────┐    │    ┌─────┘
                  ┌──▼────▼────▼──┐
                  │   merge.sh    │   re-runs every gate, merges --no-ff,
                  └───────────────┘   prunes clean worktrees
```

One Bash call replaces the dispatch-and-babysit loop. An orchestrating agent (or a human) decomposes the work and writes the specs; the driver creates the worktrees, dispatches every unit to a CLI worker lane, runs each unit's gate, and writes a single `report.json`. The orchestrator reads the report, not the transcripts.

The point is context economics. Routing worker CLIs through an LLM orchestrator's own subagents means paying frontier-model tokens for what amounts to a shell wrapper, and every fix round re-briefs a cold worker with the whole spec again. Here the wrapper is gone and workers keep their sessions, so a follow-up costs a sentence.

Design principles, each of which exists because its absence cost real debugging time:

- **The gate is the only evidence.** Worker self-reports are advisory. A unit passes when its named test command exits 0 in its worktree, and `merge.sh` re-runs that gate immediately before committing — a green line in a JSON file is not a green test now.
- **Specs are frozen.** Workers start with zero session context. Everything unstated is unknown to them, and a follow-up resumes the same session rather than re-briefing a cold one.
- **Workers never touch git history.** They leave worktrees dirty; review, commit, and merge happen in the orchestrator's hands, so nothing lands unreviewed.
- **Every dispatch is accountable.** Per-unit token and cost telemetry, a spend ledger written *before* the money is spent, and a `HALT` file kill switch checked at every unit boundary.

## Quickstart

```bash
git clone https://github.com/HiroshiGanatamo/lanes
cd ~/my-repo

mkdir -p .orch/specs
cat > .orch/units.json <<'EOF'
{
  "units": [
    { "id": "u1", "slug": "titlecase-fix", "spec": "specs/titlecase.md",
      "gate": "bun test src/titlecase", "lane": "auto" }
  ]
}
EOF
$EDITOR .orch/specs/titlecase.md     # goal, exact paths, constraints, non-goals

~/lanes/run.sh --dry-run             # show the plan, dispatch nothing
~/lanes/run.sh                       # dispatch, gate, report
~/lanes/merge.sh                     # re-gate, commit, merge what passed
```

Requirements: `bash` 5+ (macOS ships 3.2 — `brew install bash`), `jq`, `uuidgen`, and at least one authenticated lane CLI on `PATH`.

## The toolkit

| Script | Use |
|---|---|
| `run.sh` | dispatch units to lanes, gate each, write `report.json` |
| `merge.sh` | commit and merge every passing unit, prune worktrees, write `merge-report.json` |
| `lanes.sh` | `doctor` — are the lanes alive, what version and model; `eval` — same benchmark on each lane |
| `nightly.sh` | unattended: drain `.orch/backlog/*.json` through run + merge, leave a digest |
| `reflect.sh` | turn failed units into spec lessons; stages them, `--promote` moves them into `LESSONS.md` |
| `spend.sh` | budget: `check` before a run, `record` per unit, `report` by day and lane |
| `AUTONOMY.md` | policy for unattended operation — pre-authorized, rule-gated, and off-limits actions |
| `HARNESSES.md` | every verified CLI flag and every trap. Read before hand-rolling any lane invocation |
| `templates/` | fill-in-the-blank spec templates per work type |

## Usage

```bash
run.sh              # reads ./.orch/units.json in the current repo
run.sh --dry-run    # show the plan and lane assignment, dispatch nothing
run.sh --only u2    # re-run a single unit
```

| Flag | Meaning |
|---|---|
| `--repo DIR` | Repo root. Defaults to `git rev-parse --show-toplevel`. |
| `-j, --jobs N` | Concurrency. Defaults to `jobs` in units.json, else 5. |
| `--only id,id` | Run a subset. |
| `--no-probe` | Skip the lane liveness probe (saves ~30s when you already know the lanes answer). |
| `--dry-run` | Print the plan and exit. |
| `--clean` | Remove existing worktrees for these slugs before dispatching. |

## Layout

The driver lives in one place; per-run state lives in the target repo:

```
<repo>/.orch/
  units.json        # you write this
  specs/*.md        # you write these
  prompts/<id>.md   # generated: hard rules + your spec
  logs/<id>.<lane>.log
  logs/<id>.gate.log
  results/<id>.json
  report.json       # read this
<repo>/.wt/<slug>   # one worktree per unit, branch wip/<slug>
```

`.orch/` and `.wt/` are appended to `.git/info/exclude`, so the repo's tracked `.gitignore` is never
touched.

## units.json

```json
{
  "jobs": 5,
  "units": [
    {
      "id": "u1",
      "slug": "parser-refactor",
      "spec": "specs/parser.md",
      "gate": "bun test src/parser",
      "lane": "auto",
      "effort": "medium",
      "model": "",
      "max_turns": 60,
      "deps": []
    }
  ]
}
```

- `spec` is relative to `.orch/`.
- `kind` is `impl` (default), `recon`, or `judge`. See below.
- `subagents` defaults to true. See below.
- `gate` runs inside the unit's worktree. It is the only evidence that counts; worker self-reports
  are advisory. Name the one test path that proves the unit — a full `check` run returns large
  output on every cycle and drives the turn count up.
- `lane` is `codex`, `kimi`, `grok`, or `auto`. `auto` round-robins across the lanes that answered
  the probe, assigning by index rather than by perceived difficulty.
- `max_turns` applies to grok only; the other two CLIs have no equivalent. Send anything that might
  not converge to grok.
- `deps` is an optional array of unit ids that must reach state `passed` before this unit
  dispatches. Unknown ids and cycles are rejected at plan time, before dispatch.

## Per-run context ledger

`<repo>/.orch/context.md` is per-run scratch state the orchestrator maintains — a lab notebook,
not `units.json`, not a spec, and not `report.json`. Create it at the start of a run, update it
as units move, and close it by promoting durable conclusions into the operator's persistent
memory and deleting the rest. Never commit the file.

Start from `templates/context-ledger.md`. Four sections: disposable `State`; `Open questions`
(owner + resolving evidence, drop when closed); `Dead ends` (what failed, why, when to retry);
`Contracts` (invariants shared by more than one unit and not already in a frozen spec).

## Choosing model and effort

Every lane defaults to expensive. Codex's config sits at `model_reasoning_effort = "max"`, which is
why a routine unit there can burn four minutes on work a medium-effort pass finishes in one. Effort
is the cheapest quality dial available, so set it deliberately per unit.

Defaults when a unit says nothing: `recon` → `low`, everything else → `medium`. Write
`"effort": "inherit"` to leave the CLI's own config alone.

| Unit shape | effort | lane |
|---|---|---|
| Recon, lookup, "where is X wired" | `low` | grok or kimi — speed matters more than depth |
| Mechanical: rename, codemod, dep bump, test fill, boilerplate | `low` | kimi (flat rate, fast) |
| Ordinary feature from a frozen spec with a binary gate | `medium` | any live lane, round-robin |
| Subtle semantics, concurrency, performance, a failing test whose cause is unknown | `high` | codex |
| Might not converge; exploratory; no binary gate | `medium` + `max_turns` | grok — the only cappable lane |
| Whole-subsystem read, very large context | `medium` | kimi with `"model": "kimi-code/k3"` (1M context) |

Values: codex and grok both take `low`, `medium`, `high` — grok rejects `max`. Kimi exposes no
effort flag; its dial is the model alias (`kimi-code/kimi-for-coding`,
`kimi-code/kimi-for-coding-highspeed`, `kimi-code/k3`, `kimi-code/k3-256k`), so an `effort` on a kimi
unit is ignored and dropped from the command.

**Raising effort does not fix a vague spec.** A unit that fails because its constraints contradict
each other fails identically at `high`, just slower and dearer. First failure → fix the spec. Second
failure → different lane, same spec. Reach for higher effort only when the unit is genuinely hard,
which usually means you knew that before you dispatched it.

## Recon units

`"kind": "recon"` asks a question about the repo instead of changing it. No worktree, no branch, no
gate; the unit runs read-only against the repo as it stands, and the worker's final message lands in
the result as `answer` with status `answered`.

```json
{ "id": "r1", "slug": "auth-map", "spec": "specs/auth-map.md", "kind": "recon", "lane": "grok" }
```

This is what replaces reading files yourself when the goal is to conserve orchestrator context. The
file dumps stay in the worker's context and only the answer crosses back — and the answer does not
get re-sent on every subsequent turn the way a file-read result does. Ask for a compact shape ("answer
as a list of path:line, nothing else"); the recon prompt already tells the worker its final message
is the entire deliverable and is read by a machine.

## Judge units

`"kind": "judge"` scores an existing artifact against a rubric instead of changing it. Read-only like
recon, status `judged`, default effort `high`. The worker is held to a strict output contract and the
result carries a parsed `judgement`:

```json
"judgement": { "score": 8, "verdict": "one sentence", "issues": ["…", "…"] }
```

This is how "output eval, not structure eval" becomes executable. A gate proves a test passes; it
cannot tell you whether a landing page reads well or a prompt produces good output. For subjective
work, run several judge units on different lanes over the same artifact and take the majority — one
model's taste is not evidence. `judgement` is null when the worker's reply could not be parsed; the
raw text stays in `answer`.

## Cost telemetry

Each result carries `tokens` and `cost_usd`, summed into `summary.tokens` and `summary.cost_usd`. All
three lanes report usage, each from a different place:

| Lane | Source | Gives |
|---|---|---|
| codex | stdout, after the `tokens used` line | total tokens |
| grok | `--output-format json` → `.usage.total_tokens`, `.total_cost_usd` | tokens **and real USD** |
| kimi | `~/.kimi-code/sessions/*/session_<id>/agents/*/wire.jsonl` → `usage.record` | tokens (no cost figure) |

Kimi's lookup globs `agents/*`, so a unit's subagents count toward its total. It is keyed by session id,
so it necessarily runs after the session is resolved.

Codex and kimi are flat-rate subscriptions, so their `cost_usd` stays 0 — a token count there measures
consumption, not spend. Only grok's figure is money. Measured on one 3-lane recon fan-out: 205k tokens
total, $0.11, all of it grok.

Switching grok to JSON output has two consequences worth knowing: its answer is `.text` rather than raw
stdout, and its reported `.sessionId` differs from the UUID passed via `-s`. The driver prefers
`.sessionId`, because that is the one that actually resumes.

## Subagents

All three lanes spawn their own subagents, so a unit is not capped at one worker's serial attention.
The generated prompt names the right tool per lane and tells the worker when spawning is worth it:

| Lane | Tool | Notes |
|---|---|---|
| codex | `collaboration.spawn_agent` | `multi_agent` feature, stable and on by default |
| kimi | `AgentSwarm` | on by default |
| grok | `spawn_subagent` | on by default; several calls in one turn run in parallel. `--no-subagents` disables |

Set `"subagents": false` on a unit to drop that paragraph — worth doing for a unit small enough that
coordination overhead beats the parallelism, since a worker handed the option will sometimes take it
for work that was never parallel.

This nests: the driver fans out across lanes, and each lane fans out internally. A unit covering
three independent modules can be one dispatch rather than three.

## The generated prompt

You never write the boilerplate. `render_prompt` prepends the worktree path, the ban on git writes
and worktree changes, the no-questions rule, and the gate as the definition of done. Your spec file
holds only the goal, the exact paths, the constraints, and the non-goals.

Before dispatching, read the spec back and ask whether its constraints can all hold at once. The
expensive failure is not a vague spec but an impossible one — "add required field `x` to shared type
`T`" plus "do not touch unrelated tests" cannot both be satisfied, and a worker will spend many
turns discovering that, pick a side, and bury the deviation in its report. When a conflict is
possible, say which side wins.

## report.json

```json
{
  "repo": "/path/to/repo",
  "units": [
    {
      "id": "u1", "slug": "parser-refactor", "lane": "codex",
      "branch": "wip/parser-refactor", "worktree": "/path/to/repo/.wt/parser-refactor",
      "worker_exit": 0, "gate_exit": 0, "gate_tail": "…last 40 lines…",
      "files_changed": 3, "insertions": 84, "deletions": 12, "dirty_paths": 3,
      "seconds": 190, "session": "…", "resume": "codex exec resume --last -C … '<message>'",
      "log": "…/.orch/logs/u1.codex.log",
      "assumptions": [], "assumption_judgement": null,
      "status": "pass", "state": "passed"
    }
  ],
  "summary": { "total": 3, "pass": 2, "gate_failed": 1, "worker_failed": 0, "no_gate": 0, "blocked": 0, "seconds": 240 }
}
```

`status` is one of `pass`, `gate_failed`, `worker_failed`, `no_gate`, `assumption_unresolved`,
`answered`, `judged`, `halted`, `blocked`. `blocked` is assigned only to units skipped because a
dependency did not reach `passed`.

`state` is the normalized terminal state derived from `status`:

| state | meaning |
|---|---|
| `passed` | completed successfully (`pass`, `answered`, or `judged`) |
| `failed` | dispatched but did not succeed (`gate_failed`, `worker_failed`, `no_gate`, `assumption_unresolved`) |
| `cancelled` | never dispatched — a HALT file was present (`halted`) |
| `blocked` | never dispatched — a dependency did not reach `passed` |

## Assumption escalation

The no-questions rule means a worker never blocks on ambiguity — it guesses and is told to
record the guess. Its final message may carry a trailing block:

```
ASSUMPTIONS_JSON:
[{"what": "which field wins", "reading_chosen": "…", "alternative_rejected": "…", "blast_radius": "local|shared"}]
```

The driver parses this into `assumptions` on the result. A `local` guess changes nothing — the gate
is still the only thing that decides pass/fail. A `shared` guess (a public API, a shared type, a
schema, persisted data — anything another unit or caller could depend on) triggers a second,
independent opinion before the unit is trusted: a `judge` unit scores the chosen reading against the
spec. Score at or above 7 keeps the pass, with `assumption_judgement` recorded. Below 7, the driver
auto-resumes the original worker once with the judge's issues and re-runs the gate — no human reads
or approves any of this, per `AUTONOMY.md`'s rule to prefer a mechanical gate over a person. A unit
still weak after the auto-fix becomes `assumption_unresolved`; `merge.sh`'s existing pass-only filter
already excludes it, and nothing about it blocks the rest of the run.

## Fix rounds

Never re-dispatch a cold worker. Every result carries a `resume` command; the worker still holds the
spec, the codebase, and its own reasoning, so a follow-up is one sentence instead of a re-brief:

```bash
codex exec -C .wt/parser-refactor resume <session_id> 'gate still fails: <paste the 3 relevant lines>'
cd .wt/chunk && kimi -r session_<id> -p 'gate still fails: …'
grok --cwd .wt/titlecase --always-approve -r <uuid> -p 'gate still fails: …'
```

Note the shape of the codex one: `-C` belongs to `exec`, before the `resume` subcommand. `codex exec
resume -C …` is rejected. Without a session id, `--last` works too — resume filters by cwd, so each
worktree resolves to its own unit even with several running.

If a unit fails after two fix rounds on one lane, re-dispatch the same spec to a different lane
before implementing it directly. Different model, same spec, no extra design work.

## Verified CLI invocations

Checked against the installed CLIs. The flags in the right column look plausible and do not work:

| Lane | Working invocation | Does not work |
|---|---|---|
| codex | `codex exec --yolo -C <dir> - < prompt.md` | `-p` is `--profile`, not prompt |
| kimi | `cd <dir> && kimi -p "$(cat prompt.md)"` | `-p` rejects both `--auto` and `-y` |
| grok | `grok --cwd <dir> --always-approve --max-turns N -s <uuid> --prompt-file prompt.md` | `-p` with `--prompt-file` (pick one) |

Resume: codex prints `session id: <uuid>` in its header and the driver scrapes it. kimi prints
`To resume this session: kimi -r session_<id>` and the driver scrapes that. grok accepts an assigned
UUID via `-s`, so its session id is known before the worker even starts. All three resume commands
land in `report.json` already filled in.

The full trap list — every flag that looks right and fails, with exact error messages — lives in
[`HARNESSES.md`](./HARNESSES.md).

## Merging

The driver does not touch git history. Workers leave their worktrees dirty; review the diff, then
commit and merge — either by hand or with `merge.sh`, which re-runs each gate immediately before
committing, merges `--no-ff`, prunes clean worktrees, and keeps conflicted ones for a human. It
refuses to merge into `main`/`master` and refuses a dirty tree; both refusals have fired on this
repository's own author, and both were correct.

```bash
git -C .wt/<slug> diff --stat HEAD     # start here; read the full diff only if the gate is red
./merge.sh                             # or commit and merge by hand
```

## Contributing

See [`CONTRIBUTING.md`](./CONTRIBUTING.md). House rule worth knowing before opening a PR: a gate must
exercise the feature it guards — two units in this repository's own history passed a `bash -n` gate
with real defects behind them. When a unit builds something testable, the test is the deliverable.

## License

[MIT](./LICENSE)
