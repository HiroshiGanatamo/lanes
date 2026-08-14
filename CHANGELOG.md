# Changelog

## v0.1.0 — 2026-08-14

Initial public release.

- `run.sh` — fan-out dispatch driver: per-unit worktrees, lane round-robin with liveness probe,
  binary gates, `report.json`. Three unit kinds: `impl` (gated code change), `recon` (read-only
  question), `judge` (rubric scoring with parsed `judgement`).
- Dependency ordering: optional `deps` per unit, wave dispatch once dependencies pass, cycle and
  unknown-id rejection at plan time, normalized terminal states (`passed` / `failed` / `blocked` /
  `cancelled`) alongside the fine-grained `status`.
- Assumption escalation: workers record guesses as structured `ASSUMPTIONS_JSON`; shared-blast-radius
  guesses trigger an automatic judge pass and one auto-resume fix round.
- `merge.sh` — re-runs every gate immediately before committing, merges `--no-ff`, prunes clean
  worktrees, refuses `main`/`master` and dirty trees.
- `lanes.sh` — lane doctor and cross-lane benchmark.
- `spend.sh` — budget caps and a spend ledger written before the spend, not after.
- `nightly.sh` — unattended backlog drain with a morning digest; `HALT` file kill switch.
- `reflect.sh` — turns failed units into staged spec-writing lessons.
- Per-unit token and cost telemetry from all three lanes.
- Per-run context ledger template (`templates/context-ledger.md`) and spec templates per work type.
- Four self-contained test suites; no lane account needed to run them.
