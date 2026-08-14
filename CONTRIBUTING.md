# Contributing

Small, verified, gated changes. This repository is dogfooded on itself — units that change these
scripts are dispatched through the very driver they modify — and the same standard applies to
outside contributions.

## Development setup

```bash
brew install bash jq        # macOS; Linux distributions ship both
bash tests/test-deps.sh     # each test suite is self-contained
bash tests/spend-test.sh
bash tests/reflect-test.sh
bash tests/assumptions-test.sh
```

Every suite builds its own throwaway repo and stubs the lane CLIs, so no lane account or network
access is needed to develop.

## House rules

- **A gate must exercise the feature it guards.** Two units in this repository's own history passed
  a `bash -n` gate with real defects behind them. If your change builds something testable, the test
  is part of the deliverable, and CI runs it.
- **`merge.sh` refuses `main`/`master` and refuses a dirty tree.** Both refusals have fired on this
  repository's own author and both were correct. Do not weaken them.
- **Empirical claims go in `HARNESSES.md` with the exact error message.** The file exists so nobody
  re-derives a CLI trap by trial and error; a trap without its verbatim error is a rumor.
- Match the existing style: plain bash, `jq` for all JSON, no new runtime dependencies.

## Pull requests

One logical change per PR, with the test that proves it. Describe what the gate is and paste its
passing output. If the change touches a lane invocation, state which CLI version you verified
against.
