<!-- Lifecycle: create `<repo>/.orch/context.md` at the start of an orchestration run; update it continuously as the run progresses; at session close, promote durable conclusions into the operator's persistent memory and delete the rest. Never commit this file. -->

# Per-run context ledger

Fill in and keep at `<repo>/.orch/context.md`. Scratch notebook for one run — not a spec, not `units.json`, not `report.json`.

## State
*(Overwrite freely. Disposable run state, not history.)*

`unit: u1 | gate: bun test src/parser | lane: grok | worktree: .wt/parser-refactor | retries: 0 | next: dispatch`

## Open questions
*(One bullet per question: the question, owner (orchestrator or user), and what evidence would resolve it. Remove the bullet once resolved.)*

- Does lane X support flag Y? owner: orchestrator; resolves via: run `lane X --help` and check.

## Dead ends
*(What was tried, the evidence that it failed, and when it is worth reconsidering.)*

- Tried routing u2 through kimi; evidence: probe returned quota 429; reconsider if: `lanes.sh doctor` shows kimi answering again.

## Contracts
*(Only invariants shared by multiple units that are not already in a frozen spec — shared interface, path ownership, a binary acceptance both units depend on. Do not restate a single unit's spec.)*

- `src/parser.ts` exports `parse(input: string): Ast`; u1 writes it, u3 consumes it; both gates fail if the signature changes.
