#!/bin/bash
# SessionStart reporter. Three jobs:
#   1. Always print the state banner, so every session shows whether the
#      safety net is armed.
#   2. If sessions in THIS project were carried on since the user last saw a
#      session here, say so once.
#   3. Recovery: pendings stranded by a reboot or crashed sleeper get their
#      sleeper respawned — session start is the natural heartbeat.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"

payload=$(cat 2>/dev/null || true)
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd=$(pwd)

# Per-session marker for the statusline badge: the badge renders only in
# sessions where this hook actually ran — not from leftover state after an
# uninstall, and not in sessions of another setup. Same charset guard as the
# catcher (the id becomes a filename). Markers expire with the transcript
# retention default; the prune keeps the dir from growing forever.
session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
case "$session_id" in *[!A-Za-z0-9._-]*) session_id="" ;; esac
if [ -n "$session_id" ] && [ "$(cfg_enabled)" = "true" ]; then
  ensure_dirs
  : > "$SESSIONS_DIR/$session_id"
  find "$SESSIONS_DIR" "$RESUMED_DIR" "$RESUMING_DIR" -type f -mtime +30 -delete 2>/dev/null || true
fi

# If THIS session was resumed headlessly while it was down, this reattach is
# the user seeing the continued transcript — say so and clear the badge's
# "resumed · reload" flag. A headless resume of an interactive session lands
# on disk, not in the open TUI, so reattaching is how the work becomes visible.
if [ -n "$session_id" ] && [ -f "$RESUMED_DIR/$session_id" ]; then
  echo "carry-on: this session was resumed headlessly after a usage-limit reset — you're now seeing the continued transcript ('carry-on log ${session_id%%-*}' for the run's output)."
  rm -f "$RESUMED_DIR/$session_id"
fi

if [ "$(cfg_enabled)" = "true" ]; then
  echo "CARRY-ON ACTIVE — mode: $(cfg_mode) (auto-resumes this session when a usage limit resets; 'carry-on off' to disable)"
else
  echo "carry-on installed — DISABLED ('carry-on on' to enable)"
fi

# Statusline setup, offered once on the first session where the badge is not
# yet wired. This hook's stdout becomes session context, so the line below is
# an instruction Claude acts on — the user still approves the actual edit.
badge_dst="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/carry-on-statusline.sh"
if [ ! -f "$badge_dst" ] && [ ! -f "$CARRY_ON_HOME/statusline_offered" ]; then
  echo "The carry-on statusline badge is not set up. Offer the user ONCE to wire it: run /carry-on:statusline (copies $ROOT/hooks/statusline.sh to $badge_dst and chains it from the statusLine command in ~/.claude/settings.json). If they decline, drop it — this offer never repeats."
  ensure_dirs
  : > "$CARRY_ON_HOME/statusline_offered"
fi

# Reboot/crash recovery: a pending with no live sleeper gets one now.
ensure_sleeper "$ROOT"

[ -f "$HISTORY_FILE" ] || exit 0
ensure_dirs

# Report resumes for this cwd that happened after the last report here.
# Tolerant parse: one torn history line must not silence the report forever.
marker="$LASTSEEN_DIR/$(printf '%s' "$cwd" | shasum | cut -c1-16)"
last_seen=$(cat "$marker" 2>/dev/null || echo 0)

jq -cR 'fromjson? // empty' "$HISTORY_FILE" 2>/dev/null \
  | jq -r --arg cwd "$cwd" --argjson since "$last_seen" \
    'select(.event == "resumed" and .cwd == $cwd and .ts > $since)
     | "carry-on: session \(.session_id[0:8]) in this project was resumed after a limit reset — carry-on log \(.session_id[0:8])"' \
  | tail -3

# Marker moves only after the report went out — a crash above must replay,
# not swallow, the night's story.
now_epoch > "$marker"
exit 0
