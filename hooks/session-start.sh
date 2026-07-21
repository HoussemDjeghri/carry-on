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

if [ "$(cfg_enabled)" = "true" ]; then
  echo "CARRY-ON ACTIVE — mode: $(cfg_mode) (auto-resumes this session when a usage limit resets; 'carry-on off' to disable)"
else
  echo "carry-on installed — DISABLED ('carry-on on' to enable)"
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
