# <TITLE>

## Goal
Upgrade <DEPENDENCY_NAME> from <OLD_VERSION> to <NEW_VERSION> in the dependency manifest and resolve any lockfile changes required by the bump.

## Exact paths
- <MANIFEST_FILE>
- <LOCKFILE>

## Requirements
1. Update the declared version constraint for <DEPENDENCY_NAME> in <MANIFEST_FILE> to <NEW_VERSION>.
2. Regenerate <LOCKFILE> using the project's normal package manager command.
3. Fix any build or test failures caused by breaking changes in the new version.
4. Leave unrelated dependencies unpinned and unchanged.

## Non-goals
- Do not upgrade unrelated dependencies at the same time.
- Do not refactor code that still compiles and passes tests after the bump.
- Do not change the package manager or build tooling.

## Conflict resolution
If a transitive dependency update is required for security but conflicts with the direct version pin, update the direct pin and document the transitive change in the lockfile only.

## Gate
bun install && bun test
