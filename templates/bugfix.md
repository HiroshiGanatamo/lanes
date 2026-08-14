# <TITLE>

## Goal
Eliminate the failure described in <ISSUE_REFERENCE> in <COMPONENT> while keeping all currently passing tests green.

## Exact paths
- <BUGGY_FILE>
- <TEST_FILE>
- <REPRODUCTION_FILE> (if separate)

## Requirements
1. Reproduce the failure with a test in <TEST_FILE> before modifying production code.
2. Change only the implementation in <BUGGY_FILE>; do not alter unrelated behavior.
3. Verify the reproduction test passes after the fix.
4. If no reproduction test existed, add one that fails before the fix and passes after it.

## Non-goals
- Do not refactor unrelated code or rename symbols outside the minimal fix.
- Do not change the public API or contract to accommodate the fix.
- Do not mark the issue resolved without a failing-then-passing test.

## Conflict resolution
If the smallest fix and the cleanest fix conflict, choose the smallest fix and document the remaining cleanup in a code comment.

## Gate
bun test <TEST_PATH> -t '<TEST_NAME>'
