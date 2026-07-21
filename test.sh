#!/bin/bash
# carry-on test suite. Self-contained: fake HOME, fake `claude` shim on PATH,
# notification capture via CARRY_ON_NOTIFY_LOG. Run: ./test.sh
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "ok  - $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { # check DESC CONDITION...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}

fresh_env() {
  TESTDIR=$(mktemp -d)
  export CARRY_ON_HOME="$TESTDIR/state"
  export CARRY_ON_NOTIFY_LOG="$TESTDIR/notifications.log"
  export CARRY_ON_SLICE=1
  export CARRY_ON_FALLBACK_STEPS="2 2 2"
  export CLAUDE_BIN="$TESTDIR/bin/claude"
  mkdir -p "$TESTDIR/bin" "$TESTDIR/proj"
  export SHIM_STATE="$TESTDIR/shim"
  mkdir -p "$SHIM_STATE"
  # Shim: limited until $SHIM_STATE/reset-done exists; records every argv.
  cat > "$TESTDIR/bin/claude" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$SHIM_STATE/calls.log"
if [ ! -f "$SHIM_STATE/reset-done" ]; then
  # Deliberately timestamp-free: a parseable time here would make the
  # sleeper reschedule to that wall-clock time and stall the suite.
  echo "You've hit your usage limit"
  exit 1
fi
case "$*" in
  *"--resume"*) echo "resumed-and-continued"; exit "${SHIM_RESUME_EXIT:-0}" ;;
  *) echo "OK" ;;
esac
SHIM
  chmod +x "$TESTDIR/bin/claude"
}

payload() { # payload SESSION_ID CWD MODE [ERROR]
  jq -cn --arg id "$1" --arg cwd "$2" --arg pm "$3" --arg err "${4:-rate_limit}" \
    '{session_id:$id, cwd:$cwd, permission_mode:$pm, hook_event_name:"StopFailure",
      error:$err, error_details:"429",
      last_assistant_message:"API Error: Rate limit reached · resets 3:45pm"}'
}

# ───────────────────────── parser ─────────────────────────
echo "# parser"
# shellcheck source=lib/parse-reset.sh
. "$ROOT/lib/parse-reset.sh"
NOW=$(date +%s)

e=$(parse_reset_epoch "You've hit your session limit · resets 3:45pm")
check "parses 'resets 3:45pm' to a future epoch" test -n "$e" -a "$e" -gt "$NOW" -a $((e - NOW)) -le 86400

e=$(parse_reset_epoch "Limit reached. Your limit will reset at 11pm.")
check "parses 'reset at 11pm'" test -n "$e" -a "$e" -gt "$NOW"

e=$(parse_reset_epoch "usage limit resets at 15:00 today")
check "parses 24h 'resets at 15:00'" test -n "$e" -a "$e" -gt "$NOW"

iso=$(date -r $((NOW + 3600)) +%Y-%m-%dT%H:%M 2>/dev/null || date -d "@$((NOW + 3600))" +%Y-%m-%dT%H:%M)
e=$(parse_reset_epoch "retry after $iso please")
check "parses ISO timestamp to ~now+3600" test -n "$e" -a $((e > NOW + 3300)) = 1 -a $((e < NOW + 3900)) = 1

e=$(parse_reset_epoch "You've reached your model limit. Run /usage-credits to continue or switch models with /model.")
check "no timestamp -> empty (fallback schedule territory)" test -z "$e"

e=$(parse_reset_epoch "")
check "empty text -> empty" test -z "$e"

# ───────────────────────── catcher guards ─────────────────────────
echo "# catcher"
fresh_env
payload s-alpha "$TESTDIR/proj" acceptEdits | "$ROOT/hooks/stop-failure.sh"
check "catch writes pending file" test -f "$CARRY_ON_HOME/pending/s-alpha.json"
check "pending records cwd" bash -c "jq -re '.cwd==\"$TESTDIR/proj\"' '$CARRY_ON_HOME/pending/s-alpha.json'"
check "pending parsed reset epoch from message" bash -c "jq -re '.reset_epoch != null' '$CARRY_ON_HOME/pending/s-alpha.json'"
check "catch notifies" grep -q "limit hit" "$CARRY_ON_NOTIFY_LOG"
check "catch appends history" grep -q '"event":"caught"' "$CARRY_ON_HOME/history.jsonl"

fresh_env
mkdir -p "$CARRY_ON_HOME"; echo "enabled=false" > "$CARRY_ON_HOME/config"
payload s-off "$TESTDIR/proj" acceptEdits | "$ROOT/hooks/stop-failure.sh"
check "disabled config -> no pending" test ! -f "$CARRY_ON_HOME/pending/s-off.json"

fresh_env
mkdir -p "$CARRY_ON_HOME"; echo "deny=$TESTDIR/proj*" > "$CARRY_ON_HOME/config"
payload s-deny "$TESTDIR/proj" acceptEdits | "$ROOT/hooks/stop-failure.sh"
check "deny glob -> no pending" test ! -f "$CARRY_ON_HOME/pending/s-deny.json"

fresh_env
payload s-plan "$TESTDIR/proj" plan | "$ROOT/hooks/stop-failure.sh"
check "plan-mode session -> no pending" test ! -f "$CARRY_ON_HOME/pending/s-plan.json"

fresh_env
payload s-wrongerr "$TESTDIR/proj" acceptEdits server_error | "$ROOT/hooks/stop-failure.sh"
check "non-rate_limit error -> no pending (script-side guard)" test ! -f "$CARRY_ON_HOME/pending/s-wrongerr.json"

fresh_env
mkdir -p "$CARRY_ON_HOME/chains"; echo 3 > "$CARRY_ON_HOME/chains/s-chain"
payload s-chain "$TESTDIR/proj" acceptEdits | "$ROOT/hooks/stop-failure.sh"
check "chain cap -> no pending, exhausted notice" bash -c "test ! -f '$CARRY_ON_HOME/pending/s-chain.json' && grep -q exhausted '$CARRY_ON_NOTIFY_LOG'"

# ───────────────────────── sleeper full cycle ─────────────────────────
echo "# sleeper"
fresh_env
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-cycle", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t+1), chain:0, caught_at:$t}' \
  > "$CARRY_ON_HOME/pending/s-cycle.json" 2>/dev/null || { mkdir -p "$CARRY_ON_HOME/pending"; jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-cycle", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t+1), chain:0, caught_at:$t}' \
  > "$CARRY_ON_HOME/pending/s-cycle.json"; }
mkdir -p "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains"
# First probe is limited (no reset-done marker); create it after 3s so the
# second probe succeeds — exercises the probe-reschedule path.
( sleep 3; touch "$SHIM_STATE/reset-done" ) &
"$ROOT/lib/sleeper.sh"
check "probe was limited then retried (>=2 probes)" bash -c "grep -c -- '-p Reply' '$SHIM_STATE/calls.log' | grep -qE '^[2-9]'"
check "resume invoked with --resume s-cycle" grep -q -- "--resume s-cycle" "$SHIM_STATE/calls.log"
check "resume used recorded permission mode" grep -q -- "--permission-mode acceptEdits" "$SHIM_STATE/calls.log"
check "pending cleared after resume" test ! -f "$CARRY_ON_HOME/pending/s-cycle.json"
check "chain incremented" bash -c "test \"\$(cat '$CARRY_ON_HOME/chains/s-cycle')\" = 1"
check "resume log captured" bash -c "ls '$CARRY_ON_HOME/logs/' | grep -q s-cycle"
check "history has resumed event" grep -q '"event":"resumed"' "$CARRY_ON_HOME/history.jsonl"
check "summary notification sent" grep -q "resumed 1" "$CARRY_ON_NOTIFY_LOG"

echo "# sleeper: bypassPermissions downgrade"
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-bypass", cwd:$cwd, permission_mode:"bypassPermissions", reset_epoch:($t-1), chain:0, caught_at:$t}' \
  > "$CARRY_ON_HOME/pending/s-bypass.json"
"$ROOT/lib/sleeper.sh"
check "bypassPermissions never replayed (downgraded)" bash -c "grep -- '--resume s-bypass' '$SHIM_STATE/calls.log' | grep -q -- '--permission-mode acceptEdits'"

echo "# sleeper: notify-only mode"
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs"
echo "mode=notify" > "$CARRY_ON_HOME/config"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-notify", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t-1), chain:0, caught_at:$t}' \
  > "$CARRY_ON_HOME/pending/s-notify.json"
"$ROOT/lib/sleeper.sh"
check "notify mode: no resume call" bash -c "! grep -q -- '--resume s-notify' '$SHIM_STATE/calls.log'"
check "notify mode: reset notification sent" grep -qi "reset" "$CARRY_ON_NOTIFY_LOG"
check "notify mode: pending cleared" test ! -f "$CARRY_ON_HOME/pending/s-notify.json"

echo "# sleeper: expiry past max_wait"
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs"
echo "max_wait=10" > "$CARRY_ON_HOME/config"
old=$(( $(date +%s) - 100 ))
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$old" \
  '{session_id:"s-old", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:null, chain:0, caught_at:$t}' \
  > "$CARRY_ON_HOME/pending/s-old.json"
"$ROOT/lib/sleeper.sh"
check "expired pending removed, not resumed" bash -c "test ! -f '$CARRY_ON_HOME/pending/s-old.json' && ! grep -q -- '--resume s-old' '$SHIM_STATE/calls.log' 2>/dev/null"
check "expiry recorded" grep -q '"event":"expired"' "$CARRY_ON_HOME/history.jsonl"

# ───────────────────────── CLI ─────────────────────────
echo "# cli"
fresh_env
mkdir -p "$CARRY_ON_HOME/pending"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-cli", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t+900), chain:0, caught_at:$t}' \
  > "$CARRY_ON_HOME/pending/s-cli.json"
out=$("$ROOT/bin/carry-on" status)
check "status lists pending session" bash -c "printf '%s' \"$out\" | grep -q s-cli"
"$ROOT/bin/carry-on" cancel s-cli >/dev/null
check "cancel removes pending" test ! -f "$CARRY_ON_HOME/pending/s-cli.json"
"$ROOT/bin/carry-on" off >/dev/null
check "off writes config" bash -c "grep -q 'enabled=false' '$CARRY_ON_HOME/config'"
"$ROOT/bin/carry-on" on >/dev/null
check "on writes config" bash -c "grep -q 'enabled=true' '$CARRY_ON_HOME/config'"
"$ROOT/bin/carry-on" config mode notify >/dev/null
check "config set persists" bash -c "grep -q 'mode=notify' '$CARRY_ON_HOME/config'"

# ───────────────────────── session-start reporter ─────────────────────────
echo "# reporter"
fresh_env
out=$(printf '{"session_id":"s-r","cwd":"%s"}' "$TESTDIR/proj" | "$ROOT/hooks/session-start.sh")
check "banner shows ACTIVE by default" bash -c "printf '%s' \"$out\" | grep -q 'CARRY-ON ACTIVE'"
mkdir -p "$CARRY_ON_HOME"; echo "enabled=false" > "$CARRY_ON_HOME/config"
out=$(printf '{"session_id":"s-r","cwd":"%s"}' "$TESTDIR/proj" | "$ROOT/hooks/session-start.sh")
check "banner shows DISABLED when off" bash -c "printf '%s' \"$out\" | grep -q 'DISABLED'"
rm -f "$CARRY_ON_HOME/config"
jq -cn --arg cwd "$TESTDIR/proj" --argjson ts "$(date +%s)" \
  '{ts:$ts, event:"resumed", session_id:"s-r-old", cwd:$cwd}' >> "$CARRY_ON_HOME/history.jsonl"
out=$(printf '{"session_id":"s-r","cwd":"%s"}' "$TESTDIR/proj" | "$ROOT/hooks/session-start.sh")
check "reporter mentions prior resume for this cwd" bash -c "printf '%s' \"$out\" | grep -q 'was resumed'"
out2=$(printf '{"session_id":"s-r","cwd":"%s"}' "$TESTDIR/proj" | "$ROOT/hooks/session-start.sh")
check "reporter reports each resume once" bash -c "! printf '%s' \"$out2\" | grep -q 'was resumed'"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
