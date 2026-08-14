# <TITLE>

## Goal
Add or modify the Anchor program instruction <INSTRUCTION_NAME> so it correctly enforces <BUSINESS_RULE> on chain.

## Exact paths
- <PROGRAM_FILE>
- <ACCOUNTS_FILE> (if separate)
- <IDL_PATH>
- <TEST_FILE>

## Requirements
1. Implement or update the instruction handler in <PROGRAM_FILE> with the required validation and state transitions.
2. Update account structs and validation logic in <PROGRAM_FILE> or <ACCOUNTS_FILE> to match the new instruction semantics.
3. Regenerate the IDL at <IDL_PATH> if the public interface changed.
4. Add or update Anchor tests in <TEST_FILE> that assert both success and failure cases.

## Non-goals
- Do not change program deployment configuration or authority keys.
- Do not add front-end or SDK code outside the program and its tests.
- Do not modify unrelated instructions.

## Conflict resolution
If a stricter security check and a smaller transaction size conflict, keep the stricter security check and accept the larger transaction.

## Gate
anchor test --skip-deploy
