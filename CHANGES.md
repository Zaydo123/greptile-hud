# HUD improvements

- Focus activity now requires computer activity: it auto-stops when the user
  has been idle past the presence cutoff, so a walk-away doesn't keep accruing
  focus time ("Focus stops when you're idle" hint on the running card).
- Any activity auto-stops after 8 hours and must be restarted explicitly, so a
  forgotten timer (e.g. coffee) can't run for days.
- Added inline activity-label editing on the running card and history rows
  (pencil → rename); renaming the running status re-shares it with Crew,
  editing completed history stays local-only.
- Moved the activity composer and collapsible local history into Crew, including before joining.
- Added six one-click activity presets, including 🚽 Toilet; click again to stop or switch to save and restart.
- Polished Crew cards with large emoji, activity accents, elapsed timers, hover feedback, and separate Online/Away indicators.
- Redesigned local 1200 × 630 stats exports with a two-column layout using only aggregate Crew data.
- Updated README with the Crew activity workflow and refreshed card descriptions.

Validation: `bash -n build.sh`, Python plist parsing, and `git diff --check` passed. No build artifacts generated. Swift compilation, macOS UI smoke tests, and signature verification remain for macOS CI/manual validation; `build.sh` was not run.