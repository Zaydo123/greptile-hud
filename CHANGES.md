# HUD improvements

- Moved the activity composer and collapsible local history into Crew, including before joining.
- Added six one-click activity presets, including 🚽 Toilet; click again to stop or switch to save and restart.
- Removed custom activity input and centralized labels while preserving existing timers, notes, history, and ordered sync.
- Polished Crew cards with large emoji, activity accents, elapsed timers, hover feedback, and separate Online/Away indicators.
- Redesigned local 1200 × 630 stats exports with a two-column layout using only aggregate Crew data.
- Updated README with the Crew activity workflow and refreshed card descriptions.

Validation: `bash -n build.sh`, Python plist parsing, and `git diff --check` passed. No build artifacts generated. Swift compilation, macOS UI smoke tests, and signature verification remain for macOS CI/manual validation; `build.sh` was not run.
