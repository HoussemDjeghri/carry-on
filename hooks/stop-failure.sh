#!/bin/bash
# The catcher. Registered on the StopFailure hook (matcher: rate_limit).
# Reads the event payload on stdin, records a pending resume, and spawns the
# sleeper. Hook output is ignored by Claude Code, so this script only has
# side effects. It must never block a dying session: every guard exits 0.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=../lib/parse-reset.sh
. "$ROOT/lib/parse-reset.sh"

payload=$(cat)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty')
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty')
pmode=$(printf '%s' "$payload" | jq -r '.permission_mode // "default"')
error=$(printf '%s' "$payload" | jq -r '.error // empty')
message=$(printf '%s' "$payload" | jq -r '((.last_assistant_message // "") + " " + (.error_details // ""))')

[ -n "$session_id" ] || exit 0
# Script-side guard so behavior stays correct even if the hook was
# registered without the rate_limit matcher.
[ "$error" = "rate_limit" ] || exit 0
[ "$(cfg_enabled)" = "true" ] || exit 0
# A plan-mode session is a conversation with a human mid-decision — never
# auto-resume one headlessly.
[ "$pmode" = "plan" ] && exit 0

# Deny globs: colon-separated cwd patterns.
deny=$(cfg_deny)
if [ -n "$deny" ]; then
  IFS=: read -ra patterns <<< "$deny"
  for pat in "${patterns[@]}"; do
    # shellcheck disable=SC2254  # glob match is the point
    case "$cwd" in $pat) exit 0 ;; esac
  done
fi

ensure_dirs

# Chain cap: this session has already been carried on max_chain times.
if [ "$(chain_count "$session_id")" -ge "$(cfg_max_chain)" ]; then
  history_append exhausted "$session_id" "$cwd"
  notify "carry-on: session ${session_id:0:8} hit the limit again after $(cfg_max_chain) resumes — exhausted, not resuming. carry-on status"
  exit 0
fi

reset_epoch=$(parse_reset_epoch "$message")
jq -cn \
  --arg id "$session_id" --arg cwd "$cwd" --arg pm "$pmode" \
  --arg snippet "${message:0:120}" \
  --argjson reset "${reset_epoch:-null}" \
  --argjson chain "$(chain_count "$session_id")" \
  --argjson t "$(now_epoch)" \
  '{session_id:$id, cwd:$cwd, permission_mode:$pm, reset_epoch:$reset,
    chain:$chain, caught_at:$t, error_snippet:$snippet}' \
  > "$PENDING_DIR/$session_id.json"

history_append caught "$session_id" "$cwd"

# One sleeper serves all pending files; mkdir is the atomic test-and-set.
if mkdir "$LOCK_DIR" 2>/dev/null; then
  echo $$ > "$LOCK_DIR/spawner"
  (setsid nohup "$ROOT/lib/sleeper.sh" >> "$CARRY_ON_HOME/sleeper.log" 2>&1 &)
elif [ -f "$LOCK_DIR/pid" ] && ! kill -0 "$(cat "$LOCK_DIR/pid")" 2>/dev/null; then
  # Stale lock (sleeper died); take over.
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null && (setsid nohup "$ROOT/lib/sleeper.sh" >> "$CARRY_ON_HOME/sleeper.log" 2>&1 &)
fi

if [ -n "$reset_epoch" ]; then
  notify "carry-on: usage limit hit — will resume ~$(fmt_time "$reset_epoch")"
else
  notify "carry-on: usage limit hit — no reset time given, will retry on a schedule"
fi
exit 0
