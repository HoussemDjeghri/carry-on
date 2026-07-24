#!/bin/bash
# The catcher. Registered on the StopFailure hook (matcher: rate_limit).
# Reads the event payload on stdin, records a pending resume, and ensures a
# sleeper is running. Hook output is ignored by Claude Code, so this script
# only has side effects. It must never block a dying session: every guard
# exits 0.
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
details=$(printf '%s' "$payload" | jq -r '.error_details // empty')
message=$(printf '%s' "$payload" | jq -r '.last_assistant_message // empty')

[ -n "$session_id" ] || exit 0
# The id builds file paths and argv below — accept only sane characters.
case "$session_id" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
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

# Chain decay: a limit hit long after the last resume means the fresh window
# ran its full healthy course, not a runaway resume loop — clear the chain so
# long unattended runs keep being carried on across many resets. Only rapid
# re-deaths (a fresh window burned through inside chain_decay) accumulate.
last_resume=$(chain_last_resume "$session_id")
if [ "$last_resume" -gt 0 ] && [ $(( $(now_epoch) - last_resume )) -ge "$(cfg_chain_decay)" ]; then
  chain_reset "$session_id"
fi

# Chain cap: this session has been carried on max_chain times already.
# Per the advertised behavior it degrades to notify-only, not to silence —
# the pending still tracks the reset so the user hears when the window lifts.
notify_only=false
if [ "$(chain_count "$session_id")" -ge "$(cfg_max_chain)" ]; then
  notify_only=true
  history_append exhausted "$session_id" "$cwd"
  notify "carry-on: session ${session_id:0:8} hit the limit again after $(cfg_max_chain) resumes — switching to notify-only for it"
fi

# The structured error detail is authoritative; assistant prose is the
# fallback only — a final message that happens to discuss reset times must
# not outrank the API's own text.
reset_epoch=$(parse_reset_epoch "$details")
[ -z "$reset_epoch" ] && reset_epoch=$(parse_reset_epoch "$message")

tmp="$PENDING_DIR/.$session_id.tmp.$$"
jq -cn \
  --arg id "$session_id" --arg cwd "$cwd" --arg pm "$pmode" \
  --argjson reset "${reset_epoch:-null}" \
  --argjson chain "$(chain_count "$session_id")" \
  --argjson notify_only "$notify_only" \
  --argjson t "$(now_epoch)" \
  '{session_id:$id, cwd:$cwd, permission_mode:$pm, reset_epoch:$reset,
    chain:$chain, caught_at:$t, retries:0, notify_only:$notify_only}' \
  > "$tmp" && mv "$tmp" "$PENDING_DIR/$session_id.json"

history_append caught "$session_id" "$cwd"
ensure_sleeper "$ROOT"

if [ -n "$reset_epoch" ]; then
  notify "carry-on: usage limit hit — will resume ~$(fmt_time "$reset_epoch")"
else
  notify "carry-on: usage limit hit — no reset time given, will retry on a schedule"
fi
exit 0
