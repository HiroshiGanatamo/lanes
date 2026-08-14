# <TITLE>

## Goal
Add missing unit tests that cover <TARGET_BEHAVIOR> with assertions that fail if the behavior regresses.

## Exact paths
- <IMPLEMENTATION_FILE>
- <TEST_FILE>

## Requirements
1. Identify untested branches and edge cases in <IMPLEMENTATION_FILE>.
2. Add tests in <TEST_FILE> that exercise each identified case with explicit assertions.
3. Modify the implementation only to expose package-visible test hooks; any larger change is out of scope.
4. Ensure all new tests pass and no existing tests break.

## Non-goals
- Do not refactor the implementation to improve readability.
- Do not add integration, end-to-end, or manual tests.
- Do not remove existing tests to silence failures.

## Conflict resolution
If covering an edge case requires changing the public API, skip that edge case and note the gap in a comment.

## Gate
bun test <TEST_PATH>
