#!/bin/bash
# Vibecoders devtime agent for Greptile HUD.
#
# While any dev app (editor/terminal) is running, this sends a heartbeat to the
# backend every VC_INTERVAL seconds. The backend accrues devtime and marks you
# as online.
#
# Usage:
#   VC_API_URL=https://your-app.onrender.com VC_USER=zayd ./devtime.sh
#
# Optional:
#   VC_INTERVAL     seconds between checks (default 60)
#   VC_APPS         comma-separated process names to watch (defaults below)
#   VC_IDLE_CUTOFF  stop beating after this many seconds without keyboard/mouse
#                   input (default 900; macOS only — elsewhere presence is
#                   assumed)
#
# Run it in the background or with launchd (see launchd-example.plist).
#
# There is no authentication: pick any username. We take your word for it.

set -euo pipefail

API_URL="${VC_API_URL:?VC_API_URL is required (e.g. https://app.onrender.com)}"
USER="${VC_USER:?VC_USER is required (the username shown on the leaderboard)}"
INTERVAL="${VC_INTERVAL:-60}"

# Process names of dev apps worth counting. pgrep -x matches the exact name;
# add your own (e.g. "Zed", "Neovide", "kitty").
APPS="${VC_APPS:-Cursor,Code - Insiders,Code,iTerm2,Terminal,Ghostty,Warp,WezTerm,Alacritty,kitty,Neovide}"
IDLE_CUTOFF="${VC_IDLE_CUTOFF:-900}"

# Seconds since the last keyboard/mouse event — the aggregate counter only,
# never key contents. Prints nothing off macOS, and the guard below then
# assumes presence.
idle_seconds() {
  ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {printf "%d", $NF/1000000000; exit}'
}

while true; do
  running=""
  for app in $(printf '%s' "$APPS" | tr ',' '\n'); do
    if pgrep -x "$app" >/dev/null 2>&1; then
      running="$app"
      break
    fi
  done

  if [ -n "$running" ]; then
    idle="$(idle_seconds || true)"
    if [ -n "$idle" ] && [ "$idle" -ge "$IDLE_CUTOFF" ]; then
      running=""
    fi
  fi

  if [ -n "$running" ]; then
    if ! curl -s -o /dev/null -m 10 \
        -H "Content-Type: application/json" \
        -d "{\"user\":\"$USER\",\"app\":\"$running\"}" \
        "$API_URL/api/pulse"; then
      echo "heartbeat failed for $running" >&2
    fi
  fi
  sleep "$INTERVAL"
done
