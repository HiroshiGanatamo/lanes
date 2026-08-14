# <TITLE>

## Goal
Add or update the <SECTION_NAME> section on the site so it matches the provided content and motion design while respecting reduced-motion preferences.

## Exact paths
- <SECTION_COMPONENT>
- <PAGE_FILE>
- <STYLES_FILE> (if separate)

## Requirements
1. Implement the section in <SECTION_COMPONENT> according to <DESIGN_REFERENCE>.
2. Import and render the section in <PAGE_FILE> in the correct position.
3. Apply motion only through the project's existing animation utilities or libraries.
4. Ensure the section respects `prefers-reduced-motion` and remains accessible.

## Non-goals
- Do not change site routing, global navigation, or footer.
- Do not add new runtime dependencies for animation.
- Do not modify unrelated sections.

## Conflict resolution
If a motion effect and the user's reduced-motion preference conflict, disable the motion effect for that preference.

## Gate
bun run build
