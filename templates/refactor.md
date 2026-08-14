# <TITLE>

## Goal
Replace duplicated or deprecated code in <TARGET_MODULE> with a single, maintainable implementation while preserving all observable behavior.

## Exact paths
- <PATH_1>
- <PATH_2>
- <NEW_FILE> (if created)

## Requirements
1. Consolidate <DUPLICATED_LOGIC> into one implementation located at <CONSOLIDATED_LOCATION>.
2. Update every caller in <CALLER_PATHS> to use the consolidated implementation.
3. Keep public signatures, tests, and runtime output identical to the pre-refactor state.
4. Add or update tests for any new helper that introduces branching.

## Non-goals
- Do not add new features or change user-visible behavior beyond the consolidation.
- Do not rewrite callers in a different language or framework.
- Do not delete existing tests; update them only if paths change.

## Conflict resolution
If preserving the public signature and removing the duplication conflict, keep the signature and leave a comment naming the duplication.

## Gate
bun test <TEST_PATH>
