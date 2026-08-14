# <TITLE>

## Goal
Implement the SwiftUI view <VIEW_NAME> in <MODULE> so it renders the specified state and responds to the specified interactions.

## Exact paths
- <VIEW_FILE>
- <TEST_FILE>

## Requirements
1. Create or edit <VIEW_FILE> to match the layout described in <DESIGN_REFERENCE>.
2. Wire the view to the existing data source <DATA_SOURCE> without changing the data source API.
3. Add SwiftUI previews for light and dark appearances in the same file.
4. Add or update tests in <TEST_FILE> that verify rendering with sample data.

## Non-goals
- Do not change navigation architecture or app-level state management.
- Do not add network calls or persistence inside the view.
- Do not redesign the view beyond the provided reference.

## Conflict resolution
If a visual design detail and accessibility contrast requirements conflict, prioritize accessibility contrast and note the design deviation.

## Gate
xcodebuild -scheme <SCHEME> -destination 'platform=iOS Simulator,name=iPhone 16' build test
