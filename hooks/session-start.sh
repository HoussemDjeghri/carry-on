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
  # Chain-me signals are pruned on the same retention as the markers: carry-on
  # never consumes them itself, so without this the directory — and the list
  # `carry-on status` prints from it — grows for the life of the install. A
  # month-old signal describes a session no orchestrator is going to succeed.
  find "$SESSIONS_DIR" "$RESUMED_DIR" "$RESUMING_DIR" "$CHAINME_DIR" \
    -type f -mtime +30 -delete 2>/dev/null || true
fi

# If THIS session was resumed headlessly while it was down, this reattach is
# the user seeing the continued transcript — say so and clear the badge's
# "resumed · reload" flag. A headless resume of an interactive session lands
# on disk, not in the open TUI, so reattaching is how the work becomes visible.
if [ -n "$session_id" ] && [ -f "$RESUMED_DIR/$session_id" ]; then
  echo "carry-on: this session was resumed headlessly after a usage-limit reset — reload/reattach to see the live session. This reattached session IS the live one; any old tab still showing the limit error is stale. ('carry-on log ${session_id%%-*}' for the run's output.)"
  rm -f "$RESUMED_DIR/$session_id"
fi

if [ "$(cfg_enabled)" = "true" ]; then
  echo "CARRY-ON ACTIVE — mode: $(cfg_mode) (auto-resumes this session when a usage limit resets; 'carry-on off' to disable)"
else
  echo "carry-on installed — DISABLED ('carry-on on' to enable)"
fi

# Statusline badge wiring. This hook's stdout becomes session context, so the
# lines below are instructions Claude acts on — the user still approves any edit.
# Two jobs:
#   1. Offer to wire the badge once, on the first session where it is not set up.
#   2. Self-heal: if a previously-wired badge is no longer reachable from the
#      active statusLine — the one collision the drop-in dir cannot prevent, a
#      foreign statusline setup repointing settings.json — re-offer to re-wire.
# The statusline_wired flag makes the re-offer fire once per wired→unwired
# transition, never as a nag. Only while enabled — a disabled plugin shows no
# badge by design.
if [ "$(cfg_enabled)" = "true" ]; then
  if statusline_wired; then
    ensure_dirs; : > "$CARRY_ON_HOME/statusline_wired"
  elif [ -f "$CARRY_ON_HOME/statusline_wired" ]; then
    rm -f "$CARRY_ON_HOME/statusline_wired"
    echo "carry-on: the statusline badge is no longer wired into your active statusline — another statusline setup replaced it. Re-wire it (collision-proof, via the drop-in dir) by running /carry-on:statusline."
  elif [ ! -f "$STATUSLINE_BADGE" ] && [ ! -f "$CARRY_ON_HOME/statusline_offered" ]; then
    echo "The carry-on statusline badge is not set up. Offer the user ONCE to wire it: run /carry-on:statusline (it drops a fragment into $STATUSLINE_D and never overwrites another tool's statusline). If they decline, drop it — this offer never repeats."
    ensure_dirs
    : > "$CARRY_ON_HOME/statusline_offered"
  fi
fi

# A session that is STARTING is, by definition, no longer waiting on a reset.
#
# Nothing used to retire a pending except carry-on resuming it itself, so a
# session the user brought back by hand — reattaching once the window lifted, or
# just continuing where the limit had stopped it — left its pending behind. The
# badge then read "waiting for reset" for as long as the session lived, which is
# the visible half. The expensive half is that the sleeper still had it queued:
# at the next reset it would launch a headless resume of a session the user is
# actively typing in, billed, with two writers on one transcript. Failing that it
# sat until max_wait (7 days) and expired with a notification about a session that
# came back a week earlier.
#
# NOT when we are the resume: `resuming/<id>` exists exactly for the span of our
# own headless run, whose child fires this hook too. Clearing there would delete
# the record the sleeper needs to retry a resume that fails.
if [ -n "$session_id" ] && [ ! -f "$RESUMING_DIR/$session_id" ] &&
  [ -f "$PENDING_DIR/$session_id.json" ]; then
  rm -f "$PENDING_DIR/$session_id.json"
  history_append reattached "$session_id" "$cwd"
fi

# The same reasoning retires a chain-me signal. It asked an orchestrator to
# start a FRESH successor because this session was not worth reviving — and
# here the session is, revived by the user. Nothing else ever clears one: it
# would hold the badge at "chained · start fresh" and sit in `carry-on status`
# until the 30-day prune, advising a successor for a session already back.
if [ -n "$session_id" ] && [ ! -f "$RESUMING_DIR/$session_id" ] &&
  [ -f "$CHAINME_DIR/$session_id.json" ]; then
  rm -f "$CHAINME_DIR/$session_id.json"
fi

# Reboot/crash recovery: a pending with no live sleeper gets one now.
ensure_sleeper "$ROOT"

[ -f "$HISTORY_FILE" ] || exit 0
ensure_dirs

# Report resumes for this cwd that happened after the last report here.
# Tolerant parse: one torn history line must not silence the report forever.
marker="$LASTSEEN_DIR/$(printf '%s' "$cwd" | shasum | cut -c1-16)"
last_seen=$(read_int "$marker")   # a torn marker must not become jq's --argjson

jq -cR 'fromjson? // empty' "$HISTORY_FILE" 2>/dev/null \
  | jq -r --arg cwd "$cwd" --argjson since "$last_seen" \
    'select(.event == "resumed" and .cwd == $cwd and .ts > $since)
     | "carry-on: session \(.session_id[0:8]) in this project was resumed after a limit reset — carry-on log \(.session_id[0:8])"' \
  | tail -3

# Marker moves only after the report went out — a crash above must replay,
# not swallow, the night's story.
now_epoch > "$marker"
exit 0
