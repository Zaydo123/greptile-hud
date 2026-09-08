# Greptile HUD — improvement task

Make these changes to this SwiftUI macOS app. Follow AGENTS.md (Swift 5 language mode, macOS 13+, no new dependencies, colors only from Theme.swift / Tokyo palette, build via ./build.sh).

## Changes

1. **Merge Status into Crew tab**
   - Currently the tab bar has separate `.status` and `.crew` cases (see `Sources/HUDView.swift` ~line 550 and the `Tab` enum ~line 289). The status composer / status history should live INSIDE the Crew tab instead of being its own tab.
   - Remove the standalone `Status` tab button from the tab bar. Fold the `StatusesView` content (composer + history) into the Crew tab view so a user can set their status and see crew together.
   - Keep behavior: the active status indicator should still be visible somewhere (e.g. header pill / badge on the Crew tab, or shown in the Crew list).

2. **Add a "Toilet" activity preset**
   - In the activity composer, `suggestedEmoji = ["🏋️", "🍽️", "☕️", "🎯", "🚶"]` (~line 1785ish in HUDView). Add the toilet emoji **🚽** to this preset list so it appears as a quick-activity button.

3. **Restrict to preset activity text (easier tracking)**
   - The composer has a free-text message `HUDTextField` bound to `$message`. Replace free-form custom text with a **preset-only choice**: clicking a preset emoji immediately sets/clears the activity, and remove (or disable / replace) the arbitrary-message text field so people can't type custom activity text.
   - Choosing a preset should start the status with that activity's label. Keep it simple: preset emoji → status; no free-form message entry.
   - Update the empty/message handling in `StatusStore` / `StatusSession` (`Sources/Models.swift`) as needed so a preset-only status still renders (e.g. a default label per emoji, or a small fixed caption).

4. **Improve visualizations + cooler share cards**
   - Make the Crew status / activity visualizations nicer within the existing theme (respect the Tokyo palette — no raw colors).
   - The share card / status card (`CrewStatusCard`) should look noticeably better: clearer activity emoji + label, better layout/spacing, a more polished look. Keep it native SwiftUI, no new dependencies.

## Constraints
- `git status` must stay clean of build artifacts. **Do NOT** run `./build.sh` (it's a macOS universal build; this is a Linux authoring worktree — CI will build).
- After edits, ALSO add a concise `CHANGES.md` entry listing what you changed (one line each).
- Then run `git add -A && git commit` on this worktree's current branch (`bot/hud-improvements`) with a clear commit message.