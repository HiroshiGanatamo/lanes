# Spec Templates

| Template | Use when | Typical gate |
|---|---|---|
| `refactor.md` | Consolidating duplication or replacing deprecated code without changing behavior | `pytest <TEST_PATH> -q` |
| `bugfix.md` | Fixing a specific failure with a failing-then-passing test | `pytest <TEST_PATH>::<TEST_NAME> -v` |
| `test-fill.md` | Adding missing unit tests for existing behavior | `pytest <TEST_PATH> -q` |
| `dep-bump.md` | Upgrading a single dependency and reconciling its lockfile | `npm ci && npm test` |
| `swiftui-view.md` | Building or updating a SwiftUI view | `xcodebuild -scheme <SCHEME> -destination 'platform=iOS Simulator,name=iPhone 16' build test` |
| `anchor-instruction.md` | Adding or changing a Solana Anchor program instruction | `anchor test --skip-deploy` |
| `motionsite-section.md` | Adding or updating a section on a motion-rich site | `npm run build` |
| `context-ledger.md` | Starting `<repo>/.orch/context.md` for one orchestration run | n/a — documentation artifact |
