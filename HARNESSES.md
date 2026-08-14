# Harnesses: driving the three CLI worker lanes

This is a gotchas reference for dispatching work to codex, kimi, and grok from this repo. The goal is that the next person never re-derives any of this by trial and error. Every fact below was verified empirically against the installed versions. If a fact seems to contradict a CLI's `--help`, trust the measured behavior.

For how to run the harnesses from this repo, see [`README.md`](./README.md).

## Verified invocations

| Lane | Invocation |
|------|------------|
| codex | `codex exec --yolo -C <dir> -o <lastmsg-file> - < prompt.md` |
| kimi | `cd <dir> && kimi -p "$(cat prompt.md)"` |
| grok | `grok --cwd <dir> --always-approve --max-turns N -s <uuid> --prompt-file prompt.md` |

## Traps

| # | Failure | Error | Fix |
|---|---------|-------|-----|
| 1 | `codex exec -p 'prompt'` | `invalid value '<prompt>' for '--profile <CONFIG_PROFILE_V2>'` | `-p` is `--profile`; pass the prompt positionally, or `-` to read stdin. |
| 2 | `kimi -p ... --auto` | `Cannot combine --prompt with --auto.` | Headless `-p` is already non-interactive; pass neither `--auto` nor `-y`. Same for `-y`. |
| 3 | `grok --effort max` | `unknown effort level 'max'; use one of: high, medium, low` | grok's ceiling is `high`. Codex accepts `low`/`medium`/`high`. |
| 4 | `codex exec resume -C <dir>` | `tip: to pass '-C' as a value, use '-- -C'` | `-C` belongs to `exec`, before the subcommand: `codex exec -C <dir> resume <id> '<msg>'`. |
| 5 | `grok --agents '[...]'` | `invalid JSON: invalid type: sequence, expected a map` | `--agents` takes a JSON map keyed by agent name, not an array. |
| 6 | `git diff --shortstat HEAD` reports 0 files after a worker run | Workers create files without staging, so diff cannot see untracked paths. | `git add -N .` first. |
| 7 | `timeout`/`gtimeout` missing | macOS has no `timeout`/`gtimeout` unless coreutils is installed. | Background the process and poll with `kill -0`. |

## Dials

Codex ships at `model_reasoning_effort = "max"` in `~/.codex/config.toml`, which is the single largest hidden cost — a measured 3-module unit took 60s at `low` versus 130–242s at `max` for a smaller 1-module unit. Override per invocation with `-c model_reasoning_effort="low"`.

Grok uses `--effort low|medium|high`.

Kimi has no per-invocation effort flag — `--thinking-effort` errors with `unknown option`. Effort does
exist, but only as config: the `k3` and `k3-256k` entries in `~/.kimi-code/config.toml` carry
`support_efforts = ["low","high","max"]` and `default_effort = "high"`, and kimi's session wire log
records the `thinkingEffort` actually used. So a per-unit dial has to be the model alias, passed with `-m`:

- `kimi-code/kimi-for-coding`
- `kimi-code/kimi-for-coding-highspeed`
- `kimi-code/k3` (1M context)
- `kimi-code/k3-256k`

## Session resume — never re-brief a cold worker

- **codex** prints `session id: <uuid>` in its header. Resume: `codex exec -C <dir> resume <uuid> '<msg>'`. Without an id, `--last` works and filters by cwd, so a per-unit worktree resolves correctly.
- **kimi** prints `To resume this session: kimi -r session_<id>`. Resume: `kimi -r session_<id> -p '<msg>'`.
- **grok** accepts an assigned UUID for a **new** session via `-s <uuid>`, so its id is known before dispatch. Resume: `grok --cwd <dir> --always-approve -r <uuid> -p '<msg>'`.

## Subagents — all three, on by default

- codex: `collaboration.spawn_agent` (feature `multi_agent`, stable/on; inspect with `codex features list`)
- kimi: `AgentSwarm`
- grok: `spawn_subagent`, several calls in one turn running in parallel, disabled with `--no-subagents`

Verified: grok spawned 3 subagents for a 3-module unit when the spec asked for it.

## Probing lanes

Lane quotas are global across every session on the machine, so a dead account surfaces minutes into a unit unless probed first. Probe each lane with `reply with exactly: LANE_OK` before a fan-out and drop the ones that fail.
