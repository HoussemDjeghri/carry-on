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

TESTDIRS=()
cleanup() {
  local d pid
  for d in "${TESTDIRS[@]:-}"; do
    [ -n "$d" ] || continue
    pid=$(cat "$d/state/sleeper.lock/pid" 2>/dev/null || true)
    if [ -n "$pid" ]; then pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; fi
    rm -rf "$d"
  done
}
trap cleanup EXIT

# Kill the current env's sleeper (tests that trigger a real spawn must not
# leak a week-long process — that leak was itself an audit finding).
reap() {
  local pid
  pid=$(cat "$CARRY_ON_HOME/sleeper.lock/pid" 2>/dev/null || true)
  if [ -n "$pid" ]; then pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; fi
  rm -rf "$CARRY_ON_HOME/sleeper.lock"
}

fresh_env() {
  TESTDIR=$(mktemp -d)
  TESTDIRS+=("$TESTDIR")
  export CARRY_ON_HOME="$TESTDIR/state"
  export CARRY_ON_NOTIFY_LOG="$TESTDIR/notifications.log"
  export CARRY_ON_SLICE=1
  export CARRY_ON_FALLBACK_STEPS="2 2 2"
  export CLAUDE_BIN="$TESTDIR/bin/claude"
  # Isolate statusline wiring from the real ~/.claude — settings.json edits and
  # the drop-in dir must never touch the developer's machine during a test run.
  export CLAUDE_CONFIG_DIR="$TESTDIR/cfg"
  mkdir -p "$TESTDIR/bin" "$TESTDIR/proj" "$TESTDIR/cfg/hooks"
  export SHIM_STATE="$TESTDIR/shim"
  mkdir -p "$SHIM_STATE"
  # Shim: limited until $SHIM_STATE/reset-done exists; records every argv.
  cat > "$TESTDIR/bin/claude" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$SHIM_STATE/calls.log"
if [ -f "$SHIM_STATE/net-error" ] && [ ! -f "$SHIM_STATE/reset-done" ]; then
  echo "Error: request failed, connect ECONNREFUSED 160.79.104.10:443"
  exit 1
fi
if [ ! -f "$SHIM_STATE/reset-done" ]; then
  # Record that a call actually TOOK the limited branch. A test that needs "one
  # probe was refused before the window opened" can then wait for that fact
  # instead of racing a fixed sleep against the sleeper's first probe.
  echo x >> "$SHIM_STATE/limited.log"
  # Deliberately timestamp-free: a parseable time here would make the
  # sleeper reschedule to that wall-clock time and stall the suite.
  echo "You've hit your usage limit"
  exit 1
fi
case "$*" in
  *"--resume"*)
    # `claude -p` reads piped stdin, so the real binary drains whatever it is
    # given. Model that, and record it: if the sleeper hands the resume its
    # pending queue, this file is where the evidence lands.
    # APPEND, never truncate. The first child is the one that eats the queue;
    # every child after it is handed the drained end and writes nothing, so a
    # truncating redirect erased the evidence before the assertion ever saw it.
    cat >> "$SHIM_STATE/resume-stdin.log" 2>/dev/null
    # The "resuming" badge marker only exists WHILE the run is in flight, so the
    # only place it can be observed is from inside the child. Asserting after the
    # sleeper returns can prove it was cleared, which a marker that was never
    # written satisfies just as well.
    ls "$CARRY_ON_HOME/resuming" >> "$SHIM_STATE/resuming-during.log" 2>/dev/null
    echo "resumed-and-continued"; exit "${SHIM_RESUME_EXIT:-0}" ;;
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
# The spawn path itself — the exact line a platform without setsid breaks.
# 15s, not 3s. This waits on a detached nohup/setsid spawn reaching the point
# where it writes its pid — the one thing here whose latency is the machine's,
# not the code's. A budget tight enough to expire under load turns a platform
# assertion into a load assertion, and a red here reads as "detach is broken".
spawn_ok=false
for _ in $(seq 30); do
  spid=$(cat "$CARRY_ON_HOME/sleeper.lock/pid" 2>/dev/null || true)
  [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null && { spawn_ok=true; break; }
  sleep 0.5
done
check "catch actually spawns a live sleeper (portable detach)" test "$spawn_ok" = true
reap

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
reap
check "chain cap -> pending kept as notify-only + exhausted recorded" \
  bash -c "jq -re '.notify_only == true' '$CARRY_ON_HOME/pending/s-chain.json' && grep -q '\"event\":\"exhausted\"' '$CARRY_ON_HOME/history.jsonl'"

# Chain decay: a limit hit long after the last resume is healthy usage that
# ran a full window, not a runaway loop — the chain clears and it resumes,
# even though the raw count was already at the cap. This is what lets a long
# unattended run survive many resets.
fresh_env
mkdir -p "$CARRY_ON_HOME/chains"
echo 3 > "$CARRY_ON_HOME/chains/s-decay"
echo $(( $(date +%s) - 7200 )) > "$CARRY_ON_HOME/chains/s-decay.at"   # resumed 2h ago > 1h decay
payload s-decay "$TESTDIR/proj" acceptEdits | "$ROOT/hooks/stop-failure.sh"
reap
check "healthy gap clears the chain -> auto-resumes despite prior count" \
  bash -c "jq -re '.notify_only == false' '$CARRY_ON_HOME/pending/s-decay.json'"

# But a rapid re-death (fresh window burned through fast) is a real loop and
# still trips the cap.
fresh_env
mkdir -p "$CARRY_ON_HOME/chains"
echo 3 > "$CARRY_ON_HOME/chains/s-loop"
echo $(( $(date +%s) - 30 )) > "$CARRY_ON_HOME/chains/s-loop.at"      # resumed 30s ago < 1h decay
payload s-loop "$TESTDIR/proj" acceptEdits | "$ROOT/hooks/stop-failure.sh"
reap
check "rapid re-death still caps -> notify-only" \
  bash -c "jq -re '.notify_only == true' '$CARRY_ON_HOME/pending/s-loop.json'"

# ───────────────────────── sleeper full cycle ─────────────────────────
echo "# sleeper"
fresh_env
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-cycle", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t+1), chain:0, caught_at:$t}' \
  > "$CARRY_ON_HOME/pending/s-cycle.json" 2>/dev/null || { mkdir -p "$CARRY_ON_HOME/pending"; jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-cycle", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t+1), chain:0, caught_at:$t}' \
  > "$CARRY_ON_HOME/pending/s-cycle.json"; }
mkdir -p "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains"
# First probe is limited; the window opens only once a probe has actually been
# REFUSED, so the reschedule path is exercised no matter how loaded the machine
# is. A fixed `sleep 3` raced the sleeper: under load it reached its first probe
# after the marker already existed, succeeded first time, and the test red for a
# reason that had nothing to do with the code.
( for _ in $(seq 150); do [ -s "$SHIM_STATE/limited.log" ] && break; sleep 0.2; done
  touch "$SHIM_STATE/reset-done" ) &   # bounded: never wait forever if no probe comes
"$ROOT/lib/sleeper.sh"
# Numeric, not a leading-digit pattern: `^[2-9]` also rejects 10 and up, so the
# assertion had an invisible upper bound it never meant to have.
check "probe was limited then retried (>=2 probes)" \
  bash -c "[ \"\$(grep -c -- '-p Reply' '$SHIM_STATE/calls.log')\" -ge 2 ]"
check "resume invoked with --resume s-cycle" grep -q -- "--resume s-cycle" "$SHIM_STATE/calls.log"
check "resume used recorded permission mode" grep -q -- "--permission-mode acceptEdits" "$SHIM_STATE/calls.log"
check "pending cleared after resume" test ! -f "$CARRY_ON_HOME/pending/s-cycle.json"
check "chain incremented" bash -c "test \"\$(cat '$CARRY_ON_HOME/chains/s-cycle')\" = 1"
check "resume stamps window-handover time (chain decay signal)" test -f "$CARRY_ON_HOME/chains/s-cycle.at"
check "resume flags resumed-reload for the TUI" test -f "$CARRY_ON_HOME/resumed/s-cycle"
check "resuming marker set DURING the run (badge shows 'resuming…')" \
  grep -q s-cycle "$SHIM_STATE/resuming-during.log"
check "resuming marker cleared after the run" test ! -f "$CARRY_ON_HOME/resuming/s-cycle"
check "resume log captured" bash -c "ls '$CARRY_ON_HOME/logs/' | grep -q s-cycle"
check "history has resumed event" grep -q '"event":"resumed"' "$CARRY_ON_HOME/history.jsonl"
check "summary notification sent" grep -q "resumed 1" "$CARRY_ON_NOTIFY_LOG"

echo "# sleeper: bypassPermissions inherited by default (continuity)"
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-bypass", cwd:$cwd, permission_mode:"bypassPermissions", reset_epoch:($t-1), chain:0, caught_at:$t}' \
  > "$CARRY_ON_HOME/pending/s-bypass.json"
"$ROOT/lib/sleeper.sh"
check "bypassPermissions replayed by default (inherits the original)" bash -c "grep -- '--resume s-bypass' '$SHIM_STATE/calls.log' | grep -q -- '--permission-mode bypassPermissions'"

echo "# sleeper: bypassPermissions downgrade (opt-out)"
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains"
echo "resume_bypass_mode=acceptEdits" > "$CARRY_ON_HOME/config"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-bypass2", cwd:$cwd, permission_mode:"bypassPermissions", reset_epoch:($t-1), chain:0, caught_at:$t}' \
  > "$CARRY_ON_HOME/pending/s-bypass2.json"
"$ROOT/lib/sleeper.sh"
check "resume_bypass_mode=acceptEdits downgrades to acceptEdits" \
  bash -c "grep -- '--resume s-bypass2' '$SHIM_STATE/calls.log' | grep -q -- '--permission-mode acceptEdits'"

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

# ─────────────────── audit regressions: parser ───────────────────
echo "# parser (audit regressions)"
e=$(parse_reset_epoch "resets at 09:30")
hm=$([ -n "$e" ] && (date -r "$e" +%H:%M 2>/dev/null || date -d "@$e" +%H:%M))
check "leading-zero 09:30 parses to 09:30, not 00:30" test "$hm" = "09:30"

e=$(parse_reset_epoch "resets 09:30pm")
hm=$([ -n "$e" ] && (date -r "$e" +%H:%M 2>/dev/null || date -d "@$e" +%H:%M))
check "leading-zero 09:30pm parses to 21:30" test "$hm" = "21:30"

isoz=$(date -ju -r $((NOW + 3600)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -ud "@$((NOW + 3600))" +%Y-%m-%dT%H:%M:%SZ)
e=$(parse_reset_epoch "retry after $isoz")
check "ISO with Z honors the zone (~now+3600)" test -n "$e" -a $((e > NOW + 3300)) = 1 -a $((e < NOW + 3900)) = 1

two_min_ago=$(date -r $((NOW - 120)) +%H:%M 2>/dev/null || date -d "@$((NOW - 120))" +%H:%M)
e=$(parse_reset_epoch "resets at $two_min_ago")
check "just-passed reset time -> imminent, not tomorrow" test -n "$e" -a $((e - NOW)) -lt 300

echo "# catcher: error_details outranks assistant prose"
fresh_env
jq -cn --arg cwd "$TESTDIR/proj" \
  '{session_id:"s-prio", cwd:$cwd, permission_mode:"acceptEdits", hook_event_name:"StopFailure",
    error:"rate_limit", error_details:"Rate limit reached · resets at 23:59",
    last_assistant_message:"as discussed, the cron resets at 01:00 daily"}' \
  | "$ROOT/hooks/stop-failure.sh"
reap
hm=$(jq -r '.reset_epoch' "$CARRY_ON_HOME/pending/s-prio.json" | { read -r ep; date -r "$ep" +%H:%M 2>/dev/null || date -d "@$ep" +%H:%M; })
check "pending epoch comes from error_details (23:59)" test "$hm" = "23:59"

echo "# sleeper: audit regressions"
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-default", cwd:$cwd, permission_mode:"default", reset_epoch:($t-1), chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-default.json"
"$ROOT/lib/sleeper.sh"
check "default-mode session resumes at acceptEdits (documented escalation)" \
  bash -c "grep -- '--resume s-default' '$SHIM_STATE/calls.log' | grep -q -- '--permission-mode acceptEdits'"

fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs"
echo "resume_default_mode=skip" > "$CARRY_ON_HOME/config"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-defskip", cwd:$cwd, permission_mode:"default", reset_epoch:($t-1), chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-defskip.json"
"$ROOT/lib/sleeper.sh"
check "resume_default_mode=skip -> notified, never resumed" \
  bash -c "! grep -q -- '--resume s-defskip' '$SHIM_STATE/calls.log' && grep -q '\"event\":\"reset_notified\"' '$CARRY_ON_HOME/history.jsonl'"

fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
export SHIM_RESUME_EXIT=1
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-retry", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t-1), chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-retry.json"
"$ROOT/lib/sleeper.sh"
unset SHIM_RESUME_EXIT
check "failed resume retried once then declared failed" \
  bash -c "grep -q '\"event\":\"resume_retry\"' '$CARRY_ON_HOME/history.jsonl' && grep -q '\"event\":\"resume_failed\"' '$CARRY_ON_HOME/history.jsonl' && test ! -f '$CARRY_ON_HOME/pending/s-retry.json'"
check "retry made exactly two resume attempts" \
  bash -c "test \"\$(grep -c -- '--resume s-retry' '$SHIM_STATE/calls.log')\" = 2"

fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/daily"
echo "daily_cap=0" > "$CARRY_ON_HOME/config"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-capped", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t-1), chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-capped.json"
"$ROOT/lib/sleeper.sh"
check "daily cap -> not resumed, capped event recorded" \
  bash -c "! grep -q -- '--resume s-capped' '$SHIM_STATE/calls.log' && grep -q '\"event\":\"daily_capped\"' '$CARRY_ON_HOME/history.jsonl'"

# A cap that must bind has to bind on the STALEST pending. Serving in glob order
# spends it on whichever session id sorts first: a 22-pending backlog once ate a
# whole day's cap that way and left the session that mattered capped.
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
echo "daily_cap=1" > "$CARRY_ON_HOME/config"
now=$(date +%s)
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$now" \
  '{session_id:"s-aaa-stale", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t-1), chain:0, caught_at:($t-86400), retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-aaa-stale.json"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$now" \
  '{session_id:"s-zzz-fresh", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t-1), chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-zzz-fresh.json"
"$ROOT/lib/sleeper.sh"
check "cap binds on the stalest pending, not on glob order" \
  bash -c "grep -q -- '--resume s-zzz-fresh' '$SHIM_STATE/calls.log' && ! grep -q -- '--resume s-aaa-stale' '$SHIM_STATE/calls.log'"

# Capacity renews at every limit reset, not at midnight: a day's spend must never
# strand a window that has already reopened.
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
echo "daily_cap=2" > "$CARRY_ON_HOME/config"
echo 2 > "$CARRY_ON_HOME/daily/count"
now=$(date +%s)
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$now" \
  '{session_id:"s-window", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t-1), chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-window.json"
"$ROOT/lib/sleeper.sh"
check "an elapsed reset refunds the cap -- a spent day never strands a fresh window" \
  bash -c "grep -q -- '--resume s-window' '$SHIM_STATE/calls.log'"

# ...and the refund is the WINDOW's, not the clock's: with no reset boundary to
# credit, the cap still binds, or it would not be a cap at all.
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
echo "daily_cap=2" > "$CARRY_ON_HOME/config"
echo 2 > "$CARRY_ON_HOME/daily/count"
date +%s > "$CARRY_ON_HOME/daily/window"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-nowindow", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:null, chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-nowindow.json"
"$ROOT/lib/sleeper.sh"
check "no elapsed reset -> the cap still binds" \
  bash -c "! grep -q -- '--resume s-nowindow' '$SHIM_STATE/calls.log' && grep -q '\"event\":\"daily_capped\"' '$CARRY_ON_HOME/history.jsonl'"

# Spend is per WINDOW, so a date-named counter file must be inert. Keying it to
# the date handed out a second refund at midnight, inside the same paid window.
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
echo "daily_cap=1" > "$CARRY_ON_HOME/config"
echo 1 > "$CARRY_ON_HOME/daily/$(date +%Y-%m-%d)"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-datefile", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:null, chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-datefile.json"
"$ROOT/lib/sleeper.sh"
check "spend is not keyed to the calendar date" \
  bash -c "grep -q -- '--resume s-datefile' '$SHIM_STATE/calls.log'"

# A truncated marker (kill mid-write, reboot, a user editing state) must not
# silently disable crediting forever: `[ "\$b" -gt "" ]` errors and returns.
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
echo "daily_cap=1" > "$CARRY_ON_HOME/config"
echo 1 > "$CARRY_ON_HOME/daily/count"
: > "$CARRY_ON_HOME/daily/window"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-emptymark", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t-1), chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-emptymark.json"
"$ROOT/lib/sleeper.sh"
check "an empty window marker does not disable crediting" \
  bash -c "grep -q -- '--resume s-emptymark' '$SHIM_STATE/calls.log'"

# A marker in the future was written by a clock that was wrong; once the clock
# is fixed it would block every real boundary until it elapsed for real.
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
echo "daily_cap=1" > "$CARRY_ON_HOME/config"
echo 1 > "$CARRY_ON_HOME/daily/count"
echo $(( $(date +%s) + 999999 )) > "$CARRY_ON_HOME/daily/window"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-futuremark", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t-1), chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-futuremark.json"
"$ROOT/lib/sleeper.sh"
check "a future window marker is distrusted, not obeyed" \
  bash -c "grep -q -- '--resume s-futuremark' '$SHIM_STATE/calls.log'"

# When the limit message carried no reset time, a probe going limited -> open is
# the ONLY evidence a window began; without it a spent cap strands the session
# the fix exists to save. No reset-done marker: the first probe is limited.
fresh_env
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
echo "daily_cap=1" > "$CARRY_ON_HOME/config"
echo 1 > "$CARRY_ON_HOME/daily/count"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-observed", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:null, chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-observed.json"
( sleep 3; touch "$SHIM_STATE/reset-done" ) &
"$ROOT/lib/sleeper.sh"
check "a probe going limited -> open credits the cap with no parsed reset time" \
  bash -c "grep -q -- '--resume s-observed' '$SHIM_STATE/calls.log'"

# A probe fails for many reasons. Only a LIMIT means a window was closed, so a
# network blip must not read as one and buy a whole fresh cap.
fresh_env
touch "$SHIM_STATE/net-error"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
echo "daily_cap=1" > "$CARRY_ON_HOME/config"
echo 1 > "$CARRY_ON_HOME/daily/count"
date +%s > "$CARRY_ON_HOME/daily/window"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-blip", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:null, chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-blip.json"
( sleep 3; touch "$SHIM_STATE/reset-done" ) &
"$ROOT/lib/sleeper.sh"
check "a non-limit probe failure does not refund the cap" \
  bash -c "! grep -q -- '--resume s-blip' '$SHIM_STATE/calls.log'"

# A credit is the counter's only writer, so a budget nothing has cleared for
# longer than the longest window we model is stale, not spent — otherwise the
# cap binds forever and every later session is capped and deleted.
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
echo "daily_cap=1" > "$CARRY_ON_HOME/config"
echo 1 > "$CARRY_ON_HOME/daily/count"
# The floor measures when SPENDING started, not the boundary last credited.
echo $(( $(date +%s) - 7 * 3600 )) > "$CARRY_ON_HOME/daily/spend_started"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-stale", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:null, chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-stale.json"
"$ROOT/lib/sleeper.sh"
check "a counter no credit has cleared in a full window is stale, not spent" \
  bash -c "grep -q -- '--resume s-stale' '$SHIM_STATE/calls.log'"

# A non-numeric cap made `[ N -ge twelve ]` throw and come back false: silently
# unlimited resumes, the opposite of what the key is for.
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
echo "daily_cap=twelve" > "$CARRY_ON_HOME/config"
echo 99 > "$CARRY_ON_HOME/daily/count"
date +%s > "$CARRY_ON_HOME/daily/window"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-badcap", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:null, chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-badcap.json"
"$ROOT/lib/sleeper.sh"
check "a non-numeric cap falls back to the default, never to unlimited" \
  bash -c "! grep -q -- '--resume s-badcap' '$SHIM_STATE/calls.log' && grep -q '\"event\":\"daily_capped\"' '$CARRY_ON_HOME/history.jsonl'"
check "config rejects a non-numeric cap outright" \
  bash -c "! '$ROOT/bin/carry-on' config daily_cap twelve"

# A reset that has already passed must not shorten the wait: the slice loop
# re-reads it every slice, so a past epoch collapsed the back-off to one slice
# and turned a 15-60 minute probe schedule into a billed probe every minute.
fresh_env
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
CARRY_ON_FALLBACK_STEPS="5 5 5" \
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-backoff", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t-100), chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-backoff.json"
backoff_t0=$SECONDS
( CARRY_ON_FALLBACK_STEPS="5 5 5"; export CARRY_ON_FALLBACK_STEPS; "$ROOT/lib/sleeper.sh" ) &
sleeper_pid=$!
sleep 6
kill "$sleeper_pid" 2>/dev/null; wait "$sleeper_pid" 2>/dev/null
backoff_elapsed=$((SECONDS - backoff_t0))
reap
# The bar scales with the time the sleeper actually got, because a fixed count
# over a `sleep 6` that overruns under load counts probes the schedule was
# entitled to make. With SLICE=1 and 5s steps, correct behaviour is ~1 probe per
# 5s and the collapse is ~1 per second, so half the elapsed seconds separates
# them at any duration.
check "a past reset does not collapse the probe back-off to one slice" \
  bash -c "[ \"\$(grep -c -- '-p Reply' '$SHIM_STATE/calls.log')\" -le $(( backoff_elapsed / 2 + 1 )) ]"

fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs"
jq -cn --argjson t "$(date +%s)" \
  '{session_id:"s-nocwd", cwd:"", permission_mode:"acceptEdits", reset_epoch:($t-1), chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-nocwd.json"
"$ROOT/lib/sleeper.sh"
check "empty cwd -> resume_failed, never launched" \
  bash -c "! grep -q -- '--resume s-nocwd' '$SHIM_STATE/calls.log' 2>/dev/null && grep -q '\"event\":\"resume_failed\"' '$CARRY_ON_HOME/history.jsonl'"
# Deleting or renaming a finished worktree is ordinary, and this path drops the
# queued session for good. Every other terminal path says so; this one counted
# nothing, so the end-of-pass summary stayed silent and the loss was visible only
# in the history tail.
check "a pending whose project directory is gone is reported, not dropped in silence" \
  grep -q "failed" "$CARRY_ON_NOTIFY_LOG"

fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
t0=$SECONDS
now=$(date +%s)
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$now" \
  '{session_id:"s-null", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:null, chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-null.json"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$now" \
  '{session_id:"s-far", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t+400), chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-far.json"
"$ROOT/lib/sleeper.sh"
check "null-epoch pending not starved by far-future one (fallback fired)" \
  bash -c "grep -q -- '--resume s-null' '$SHIM_STATE/calls.log' && grep -q -- '--resume s-far' '$SHIM_STATE/calls.log' && test $((SECONDS - t0)) -lt 60"

echo "# recovery: session-start respawns a stranded sleeper"
fresh_env
mkdir -p "$CARRY_ON_HOME/pending"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-strand", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t+900), chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-strand.json"
printf '{"session_id":"s-r2","cwd":"%s"}' "$TESTDIR/proj" | "$ROOT/hooks/session-start.sh" >/dev/null
# 15s, not 3s. This waits on a detached nohup/setsid spawn reaching the point
# where it writes its pid — the one thing here whose latency is the machine's,
# not the code's. A budget tight enough to expire under load turns a platform
# assertion into a load assertion, and a red here reads as "detach is broken".
spawn_ok=false
for _ in $(seq 30); do
  spid=$(cat "$CARRY_ON_HOME/sleeper.lock/pid" 2>/dev/null || true)
  [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null && { spawn_ok=true; break; }
  sleep 0.5
done
check "stranded pending gets a sleeper at session start" test "$spawn_ok" = true
reap

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
out=$("$ROOT/bin/carry-on" config 2>&1)
check "config no-arg prints defaults without syntax errors" \
  bash -c "printf '%s' \"$out\" | grep -q 'max_chain=3' && ! printf '%s' \"$out\" | grep -qi 'syntax error'"
printf 'not json at all\n' >> "$CARRY_ON_HOME/history.jsonl"
jq -cn --argjson ts "$(date +%s)" '{ts:$ts, event:"resumed", session_id:"s-tolerant", cwd:"/tmp/x"}' >> "$CARRY_ON_HOME/history.jsonl"
out=$("$ROOT/bin/carry-on" status 2>&1)
check "status survives a torn history line" bash -c "printf '%s' \"$out\" | grep -q s-tolera"

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

# Reattaching a session that was resumed headlessly: it says so once and clears
# the "resumed · reload" flag (the user is now seeing the continued transcript).
fresh_env
mkdir -p "$CARRY_ON_HOME/resumed"; : > "$CARRY_ON_HOME/resumed/s-back"
out=$(printf '{"session_id":"s-back","cwd":"%s"}' "$TESTDIR/proj" | "$ROOT/hooks/session-start.sh")
check "reattach announces the headless resume" bash -c "printf '%s' \"$out\" | grep -q 'resumed headlessly'"
check "reattach clears the resumed-reload flag" test ! -f "$CARRY_ON_HOME/resumed/s-back"
out2=$(printf '{"session_id":"s-back","cwd":"%s"}' "$TESTDIR/proj" | "$ROOT/hooks/session-start.sh")
check "resumed note shows once" bash -c "! printf '%s' \"$out2\" | grep -q 'resumed headlessly'"

# ───────────────────────── statusline badge ─────────────────────────
echo "# statusline"
fresh_env
spayload() { printf '{"session_id":"%s","workspace":{"current_dir":"%s"}}' "$1" "$TESTDIR/proj"; }

# No SessionStart marker yet → no badge, even though carry-on is enabled.
out=$(spayload s-line | "$ROOT/hooks/statusline.sh")
check "no badge without a session marker" test -z "$out"

# SessionStart drops the marker → the badge appears for THAT session only.
printf '{"session_id":"s-line","cwd":"%s"}' "$TESTDIR/proj" | "$ROOT/hooks/session-start.sh" >/dev/null
out=$(spayload s-line | "$ROOT/hooks/statusline.sh")
check "armed badge after marker" bash -c "printf '%s' \"$out\" | grep -q 'CARRY-ON'"
check "armed badge is not the waiting variant" bash -c "! printf '%s' \"$out\" | grep -q 'waiting'"

# A different session with no marker still gets nothing.
out=$(spayload s-other | "$ROOT/hooks/statusline.sh")
check "badge stays session-scoped" test -z "$out"

# This session hits the limit (pending file for its id) → waiting variant.
mkdir -p "$CARRY_ON_HOME/pending"; echo '{}' > "$CARRY_ON_HOME/pending/s-line.json"
out=$(spayload s-line | "$ROOT/hooks/statusline.sh")
check "waiting badge when this session is pending" bash -c "printf '%s' \"$out\" | grep -q 'waiting for reset'"

# A headless resume in flight → "resuming…", and it outranks the still-present
# pending file (which is deleted only after the run).
mkdir -p "$CARRY_ON_HOME/resuming"; : > "$CARRY_ON_HOME/resuming/s-line"
out=$(spayload s-line | "$ROOT/hooks/statusline.sh")
check "resuming badge while a headless resume runs (beats waiting)" bash -c "printf '%s' \"$out\" | grep -q 'resuming'"
rm -f "$CARRY_ON_HOME/resuming/s-line"
rm -f "$CARRY_ON_HOME/pending/s-line.json"

# After a resume → "resumed · reload" cues the still-open TUI to reattach.
mkdir -p "$CARRY_ON_HOME/resumed"; : > "$CARRY_ON_HOME/resumed/s-line"
out=$(spayload s-line | "$ROOT/hooks/statusline.sh")
check "resumed-reload badge after a headless resume" bash -c "printf '%s' \"$out\" | grep -q 'reload'"
rm -f "$CARRY_ON_HOME/resumed/s-line"

# Disabled globally → no badge regardless of marker.
echo "enabled=false" > "$CARRY_ON_HOME/config"
out=$(spayload s-line | "$ROOT/hooks/statusline.sh")
check "no badge when disabled" test -z "$out"
rm -f "$CARRY_ON_HOME/config"

# A hostile session id can neither traverse paths nor reach the terminal.
out=$(printf '{"session_id":"../../etc/passwd"}' | "$ROOT/hooks/statusline.sh")
check "path-traversal session id yields no badge" test -z "$out"

# ───────────── statusline: drop-in dispatcher, wiring, self-heal ─────────────
echo "# statusline drop-in"
wired()    { bash -c ". \"$ROOT/lib/common.sh\"; statusline_wired"; }
notwired() { if bash -c ". \"$ROOT/lib/common.sh\"; statusline_wired"; then return 1; else return 0; fi; }
set_dispatcher_statusline() { # active statusLine = a dispatcher reading statusline.d
  cp "$ROOT/hooks/statusline-dispatch.sh" "$CLAUDE_CONFIG_DIR/hooks/statusline-dispatch.sh"
  jq -n --arg c "bash \"$CLAUDE_CONFIG_DIR/hooks/statusline-dispatch.sh\"" \
    '{statusLine:{type:"command",command:$c}}' > "$CLAUDE_CONFIG_DIR/settings.json"
}

# The shipped dispatcher runs fragments in filename order, joins with a space,
# and skips one that errors or prints nothing.
fresh_env
mkdir -p "$CLAUDE_CONFIG_DIR/statusline.d"
printf '#!/bin/bash\necho AAA\n' > "$CLAUDE_CONFIG_DIR/statusline.d/20-a.sh"
printf '#!/bin/bash\nexit 1\n'   > "$CLAUDE_CONFIG_DIR/statusline.d/40-broken.sh"
printf '#!/bin/bash\necho ZZZ\n' > "$CLAUDE_CONFIG_DIR/statusline.d/60-z.sh"
out=$(printf '{"session_id":"x"}' | bash "$ROOT/hooks/statusline-dispatch.sh")
check "dispatcher joins fragments in order, skips broken/empty" test "$out" = "AAA ZZZ"

# statusline_wired reflects only the ACTIVE statusLine command.
fresh_env
mkdir -p "$CLAUDE_CONFIG_DIR/statusline.d"
: > "$CLAUDE_CONFIG_DIR/statusline.d/60-carry-on.sh"
set_dispatcher_statusline
check "wired: active dispatcher routes the drop-in dir + fragment present" wired
rm -f "$CLAUDE_CONFIG_DIR/statusline.d/60-carry-on.sh"
check "not wired: dispatcher active but our fragment missing" notwired

fresh_env
jq -n '{statusLine:{type:"command",command:"echo hello"}}' > "$CLAUDE_CONFIG_DIR/settings.json"
check "not wired: foreign statusline never mentions the badge" notwired

fresh_env
printf '#!/bin/bash\ninput=$(cat)\nbash "$HOME/.claude/hooks/carry-on-statusline.sh" <<<"$input"\n' \
  > "$CLAUDE_CONFIG_DIR/hooks/mine.sh"
jq -n --arg c "bash \"$CLAUDE_CONFIG_DIR/hooks/mine.sh\"" \
  '{statusLine:{type:"command",command:$c}}' > "$CLAUDE_CONFIG_DIR/settings.json"
check "wired: a composer script that chains the badge" wired

fresh_env
rm -f "$CLAUDE_CONFIG_DIR/settings.json"
check "not wired: no settings.json" notwired

echo "# statusline wiring (carry-on statusline)"
# No statusline yet → install the dispatcher, point settings at it, drop the
# fragment, report wired.
fresh_env
rm -f "$CLAUDE_CONFIG_DIR/settings.json"
out=$("$ROOT/bin/carry-on" statusline); rc=$?
check "no statusline → exits 0" test "$rc" = 0
check "no statusline → dispatcher installed" test -f "$CLAUDE_CONFIG_DIR/hooks/statusline-dispatch.sh"
check "no statusline → fragment dropped" test -f "$CLAUDE_CONFIG_DIR/statusline.d/60-carry-on.sh"
check "no statusline → stable badge copy installed" test -f "$CLAUDE_CONFIG_DIR/hooks/carry-on-statusline.sh"
check "no statusline → settings point at the dispatcher" \
  bash -c "jq -re '.statusLine.command | contains(\"statusline-dispatch\")' '$CLAUDE_CONFIG_DIR/settings.json'"
check "no statusline → now wired" wired

# Existing foreign dispatcher already reading statusline.d → drop the fragment,
# never touch settings.
fresh_env
set_dispatcher_statusline
before=$(cat "$CLAUDE_CONFIG_DIR/settings.json")
out=$("$ROOT/bin/carry-on" statusline); rc=$?
check "existing dispatcher → exits 0, fragment present" \
  bash -c "test '$rc' = 0 && test -f '$CLAUDE_CONFIG_DIR/statusline.d/60-carry-on.sh'"
check "existing dispatcher → settings left untouched (no clobber)" \
  test "$(cat "$CLAUDE_CONFIG_DIR/settings.json")" = "$before"

# Foreign non-dispatcher statusline → never overwrite; signal a choice.
fresh_env
jq -n '{statusLine:{type:"command",command:"echo hi"}}' > "$CLAUDE_CONFIG_DIR/settings.json"
before=$(cat "$CLAUDE_CONFIG_DIR/settings.json")
out=$("$ROOT/bin/carry-on" statusline); rc=$?
check "foreign statusline → exit 3" test "$rc" = 3
check "foreign statusline → NEEDS-CHOICE emitted" bash -c "printf '%s' \"$out\" | grep -q NEEDS-CHOICE"
check "foreign statusline → not overwritten" \
  test "$(cat "$CLAUDE_CONFIG_DIR/settings.json")" = "$before"

echo "# reporter: statusline self-heal"
# Wired now → SessionStart records the flag, stays quiet.
fresh_env
mkdir -p "$CLAUDE_CONFIG_DIR/statusline.d"
: > "$CLAUDE_CONFIG_DIR/statusline.d/60-carry-on.sh"
: > "$CLAUDE_CONFIG_DIR/hooks/carry-on-statusline.sh"
set_dispatcher_statusline
out=$(printf '{"session_id":"s-heal","cwd":"%s"}' "$TESTDIR/proj" | "$ROOT/hooks/session-start.sh")
check "wired → wired flag set" test -f "$CARRY_ON_HOME/statusline_wired"
check "wired → no re-offer" bash -c "! printf '%s' \"$out\" | grep -q 'no longer wired'"

# A foreign setup replaces the statusline → next session re-offers ONCE.
jq -n '{statusLine:{type:"command",command:"echo hi"}}' > "$CLAUDE_CONFIG_DIR/settings.json"
out=$(printf '{"session_id":"s-heal","cwd":"%s"}' "$TESTDIR/proj" | "$ROOT/hooks/session-start.sh")
check "un-wired after being wired → re-offer emitted" bash -c "printf '%s' \"$out\" | grep -q 'no longer wired'"
check "re-offer clears the wired flag" test ! -f "$CARRY_ON_HOME/statusline_wired"
out2=$(printf '{"session_id":"s-heal","cwd":"%s"}' "$TESTDIR/proj" | "$ROOT/hooks/session-start.sh")
check "re-offer fires once, not every session (no nag)" \
  bash -c "! printf '%s' \"$out2\" | grep -qE 'no longer wired|not set up'"

# First-time offer: never wired, badge not installed → offer once.
fresh_env
rm -f "$CLAUDE_CONFIG_DIR/settings.json"
out=$(printf '{"session_id":"s-first","cwd":"%s"}' "$TESTDIR/proj" | "$ROOT/hooks/session-start.sh")
check "first session → badge setup offered" bash -c "printf '%s' \"$out\" | grep -q 'not set up'"
out2=$(printf '{"session_id":"s-first","cwd":"%s"}' "$TESTDIR/proj" | "$ROOT/hooks/session-start.sh")
check "setup offer never repeats" bash -c "! printf '%s' \"$out2\" | grep -q 'not set up'"

# ────────── a headless resume that hits the limit is not lost ──────────
# The resume child runs the user's hooks, so a child killed by a FRESH usage
# limit re-queues its own session through the catcher while the sleeper is still
# waiting on it. The sleeper's `retries` was read before the run and describes a
# pending that no longer exists; acting on it deleted the fresh catch, losing the
# only record that the session is waiting on the next reset. Long chains reach
# this on the ordinary path — running until the window closes again is the point.
echo "# headless resume re-caught by a fresh limit"
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
# The shim stands in for a resume that dies on a new limit: it re-queues the
# session exactly as the catcher would, with a fresh caught_at, then exits 1.
cat > "$TESTDIR/bin/claude" <<SHIM
#!/bin/bash
printf '%s\n' "\$*" >> "\$SHIM_STATE/calls.log"
case "\$*" in
  *"--resume"*)
    jq -cn --arg cwd "$TESTDIR/proj" --argjson t "\$(date +%s)" --argjson r \$(( \$(date +%s) + 1800 )) \\
      '{session_id:"s-again", cwd:\$cwd, permission_mode:"acceptEdits", reset_epoch:\$r,
        chain:1, caught_at:\$t, retries:0, notify_only:false}' \\
      > "$CARRY_ON_HOME/pending/s-again.json"
    echo "You've hit your usage limit"; exit 1 ;;
  *) echo "OK" ;;
esac
SHIM
chmod +x "$TESTDIR/bin/claude"
# retries already spent: the old code would delete the fresh catch outright.
jq -cn --arg cwd "$TESTDIR/proj" --argjson t $(( $(date +%s) - 60 )) \
  '{session_id:"s-again", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:null,
    chain:1, caught_at:$t, retries:1, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-again.json"
"$ROOT/lib/sleeper.sh" &
sleeper_pid=$!
sleep 6
kill "$sleeper_pid" 2>/dev/null; wait "$sleeper_pid" 2>/dev/null
reap
check "a resume re-caught by a fresh limit keeps its new pending" \
  test -f "$CARRY_ON_HOME/pending/s-again.json"
check "the re-queued pending keeps the NEW window's reset, not our stale retry count" \
  bash -c "[ \"\$(jq -r .retries '$CARRY_ON_HOME/pending/s-again.json')\" = 0 ] &&
           [ \"\$(jq -r .reset_epoch '$CARRY_ON_HOME/pending/s-again.json')\" != null ]"
check "the re-queue is recorded, not counted as a failure" \
  bash -c "grep -q '\"event\":\"resume_requeued\"' '$CARRY_ON_HOME/history.jsonl' &&
           ! grep -q '\"event\":\"resume_failed\"' '$CARRY_ON_HOME/history.jsonl'"

# ────────── a lock naming a recycled pid is stale, not healthy ──────────
# The lock dir and its pid file survive a reboot on disk, and the OS recycles
# pids. Proving the number is ALIVE proves nothing about whose it is: an
# unrelated process landing on it read as "healthy sleeper", so every recovery
# entry point returned having done nothing and the pending stranded by the reboot
# was never resumed, never notified and never expired — expire_stale runs only
# inside the sleeper that never started.
echo "# stale lock: pid identity"
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-reboot", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:null,
    chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-reboot.json"
sleep 600 & impostor=$!
mkdir -p "$CARRY_ON_HOME/sleeper.lock"
echo "$impostor" > "$CARRY_ON_HOME/sleeper.lock/pid"
echo "$(date +%s)" > "$CARRY_ON_HOME/sleeper.lock/spawned_at"
printf '{"session_id":"s-rb","cwd":"%s"}' "$TESTDIR/proj" | "$ROOT/hooks/session-start.sh" >/dev/null
recovered=false
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "$CARRY_ON_HOME/pending/s-reboot.json" ] || { recovered=true; break; }
  sleep 1
done
check "a lock naming someone else's pid is stolen, not trusted" test "$recovered" = true
check "the impostor process is never signalled" bash -c "kill -0 $impostor 2>/dev/null"
kill "$impostor" 2>/dev/null; wait "$impostor" 2>/dev/null
reap

# `cancel` signalled the pid with no check at all — not even the `kill -0` the
# spawn path had — and `pkill -P` took its children with it. Reboot, recycled
# pid, user tidies up: carry-on kills an unrelated process of theirs.
fresh_env
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs"
bash -c 'sleep 400 & sleep 400' & victim=$!
sleep 0.5
mkdir -p "$CARRY_ON_HOME/sleeper.lock"
echo "$victim" > "$CARRY_ON_HOME/sleeper.lock/pid"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-cx", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t+900), chain:0, caught_at:$t}' \
  > "$CARRY_ON_HOME/pending/s-cx.json"
"$ROOT/bin/carry-on" cancel all >/dev/null 2>&1
check "cancel never signals a pid it cannot identify as its own sleeper" \
  bash -c "kill -0 $victim 2>/dev/null"
check "cancel still clears a lock naming a process that is not ours" \
  test ! -d "$CARRY_ON_HOME/sleeper.lock"
kill "$victim" 2>/dev/null; pkill -P "$victim" 2>/dev/null; wait "$victim" 2>/dev/null

# ────────── torn state files are not silently obeyed ──────────
# `echo N > file` is not atomic; a kill, a reboot or a full disk leaves a
# zero-length one. The empty string then reaches jq's --argjson, which rejects
# it, so the `&&` short-circuits and the pending is never written — while the
# user is told, in the same breath, exactly when their session will resume.
echo "# torn state files"
fresh_env
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/chains"
: > "$CARRY_ON_HOME/chains/s-torn"
payload s-torn "$TESTDIR/proj" acceptEdits | "$ROOT/hooks/stop-failure.sh" >/dev/null 2>&1
check "a zero-length chain counter still writes the pending" \
  test -f "$CARRY_ON_HOME/pending/s-torn.json"
check "a zero-length chain counter leaves no orphan .tmp in the queue" \
  bash -c "! ls '$CARRY_ON_HOME/pending'/.*.tmp.* >/dev/null 2>&1"
reap

# The chain cap is the brake on a runaway resume loop, and it was the one cap
# without a sanitiser: a non-numeric value made its comparison throw and come
# back FALSE, so the session kept auto-resuming past the cap. daily_cap got this
# treatment; max_chain did not.
fresh_env
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/chains"
echo 3 > "$CARRY_ON_HOME/chains/s-cap"
echo "max_chain=three" > "$CARRY_ON_HOME/config"
payload s-cap "$TESTDIR/proj" acceptEdits | "$ROOT/hooks/stop-failure.sh" >/dev/null 2>&1
check "a non-numeric max_chain falls back to the default, never to unlimited" \
  bash -c "[ \"\$(jq -r .notify_only '$CARRY_ON_HOME/pending/s-cap.json')\" = true ]"
reap

# ────────── the resume child never inherits the pending queue ──────────
echo "# resume stdin"
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
for s in s-q1 s-q2 s-q3; do
  jq -cn --arg id "$s" --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
    '{session_id:$id, cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:null, chain:0, caught_at:$t, retries:0, notify_only:false}' \
    > "$CARRY_ON_HOME/pending/$s.json"
done
"$ROOT/lib/sleeper.sh"
# ONE pass means ONE probe. The resume tally alone cannot tell the two apart:
# a child that eats the queue off stdin ends the pass after one session, and the
# rest come back on later cycles — three resumes either way. Each of those extra
# cycles is a fresh billed probe, which is the cost being guarded, so the probe
# count is the assertion that has teeth.
check "every queued pending is resumed in one pass, not one per cycle" \
  bash -c "[ \"\$(grep -c -- '--resume' '$SHIM_STATE/calls.log')\" = 3 ] &&
           [ \"\$(grep -c 'Reply with exactly' '$SHIM_STATE/calls.log')\" = 1 ]"
check "the resume child is handed no stdin (the queue is not its input)" \
  bash -c "[ ! -s '$SHIM_STATE/resume-stdin.log' ]"

# ────────── a real resume stamps the spend clock, not the window ──────────
# Every other staleness test seeds daily/spend_started by hand, which leaves the
# code that CREATES it untested: repointing that write at the window marker kept
# the whole suite green. Spend through an actual resume and read both files.
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-spend", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:null,
    chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-spend.json"
"$ROOT/lib/sleeper.sh"
check "a resume spends the budget" \
  bash -c "[ \"\$(cat '$CARRY_ON_HOME/daily/count' 2>/dev/null)\" = 1 ]"
check "the first spend stamps the spend clock with now" \
  bash -c "s=\$(cat '$CARRY_ON_HOME/daily/spend_started' 2>/dev/null);
           case \"\$s\" in ''|*[!0-9]*) exit 1 ;; esac
           [ \$(( \$(date +%s) - s )) -lt 300 ]"
# No pending carried a reset epoch and no probe ever failed, so nothing proved a
# boundary — a window marker here could only have come from the spend writing to
# the wrong file, which is precisely the mutation the suite used to sleep through.
check "spending does not write a window marker no boundary proved" \
  bash -c "[ ! -s '$CARRY_ON_HOME/daily/window' ]"

# ────────── a boundary is credited exactly once ──────────
# The cap only means anything if the boundary that refunds it can refund it one
# time. A retry pending keeps its elapsed reset_epoch by design, so without the
# credit-once guard that same boundary is re-proved on every probe cycle and the
# cap is refunded every few minutes for the life of the pending. Every other cap
# test either has no provable boundary or finishes inside one cycle, so all of
# them stayed green with the guard deleted.
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
echo "daily_cap=1" > "$CARRY_ON_HOME/config"
boundary=$(( $(date +%s) - 300 ))
echo 1 > "$CARRY_ON_HOME/daily/count"
echo "$boundary" > "$CARRY_ON_HOME/daily/window"          # this boundary is already credited
echo "$(date +%s)" > "$CARRY_ON_HOME/daily/spend_started"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" --argjson b "$boundary" \
  '{session_id:"s-once", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:$b,
    chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-once.json"
"$ROOT/lib/sleeper.sh"
check "a boundary already credited does not refund the cap again" \
  bash -c "! grep -q -- '--resume s-once' '$SHIM_STATE/calls.log' &&
           grep -q '\"event\":\"daily_capped\"' '$CARRY_ON_HOME/history.jsonl'"

# ────────── crediting a window restarts the spend clock ──────────
# The stamp half of the spend clock is tested above; this is the clearing half.
# Left unclear, the clock keeps the oldest spend time forever and the staleness
# floor fires on a budget spent seconds ago — which is the headline bug the spend
# clock was introduced to fix, reachable again by deleting one line.
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
boundary=$(( $(date +%s) - 300 ))
echo 3 > "$CARRY_ON_HOME/daily/count"
echo $(( $(date +%s) - 9000 )) > "$CARRY_ON_HOME/daily/spend_started"   # an old spend clock
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" --argjson b "$boundary" \
  '{session_id:"s-clear", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:$b,
    chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-clear.json"
"$ROOT/lib/sleeper.sh"
check "crediting a window clears the counter" \
  bash -c "[ \"\$(cat '$CARRY_ON_HOME/daily/count' 2>/dev/null)\" = 1 ]"
# 1, not 0: the credit zeroes it and this pass then spends once.
check "crediting a window restarts the spend clock, not keeps the old one" \
  bash -c "s=\$(cat '$CARRY_ON_HOME/daily/spend_started' 2>/dev/null);
           case \"\$s\" in ''|*[!0-9]*) exit 1 ;; esac
           [ \$(( \$(date +%s) - s )) -lt 300 ]"

# ────────── a boundary credited long ago is not a stale budget ──────────
# The staleness floor measures when SPENDING started, never the boundary last
# credited: sleeping through a reset credits an hours-old boundary, and reading
# that as the budget's age refunds the whole cap seconds after it was spent.
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
echo "daily_cap=1" > "$CARRY_ON_HOME/config"
echo 1 > "$CARRY_ON_HOME/daily/count"
echo $(( $(date +%s) - 10 * 3600 )) > "$CARRY_ON_HOME/daily/window"       # credited 10h ago
echo "$(date +%s)" > "$CARRY_ON_HOME/daily/spend_started"                  # but spent just now
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-fresh", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:null, chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-fresh.json"
"$ROOT/lib/sleeper.sh"
check "an old credited boundary does not make a fresh budget stale" \
  bash -c "! grep -q -- '--resume s-fresh' '$SHIM_STATE/calls.log'"

# ────────── a distrusted marker must not disable the floor ──────────
# Distrusting a future marker and the staleness floor were added together and
# used to cancel: zeroing the marker killed the guard the floor stood on, so the
# case the floor exists for bound again for as long as the clock stayed ahead.
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
echo "daily_cap=1" > "$CARRY_ON_HOME/config"
echo 1 > "$CARRY_ON_HOME/daily/count"
echo $(( $(date +%s) + 3600 )) > "$CARRY_ON_HOME/daily/window"             # impossible marker
echo $(( $(date +%s) - 7 * 3600 )) > "$CARRY_ON_HOME/daily/spend_started"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-skew", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:null, chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-skew.json"
"$ROOT/lib/sleeper.sh"
check "a distrusted future marker does not disable the staleness floor" \
  bash -c "grep -q -- '--resume s-skew' '$SHIM_STATE/calls.log'"

# ────────── a passed reset arms the fallback, like an unknown one ──────────
# It can never be the wake time, so if it is not counted as unscheduled it is in
# neither set and parks behind any future reset — days, for a weekly one.
fresh_env
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
printf 'probe_backoff=3\n' > "$CARRY_ON_HOME/config"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" --argjson r "$(( $(date +%s) + 600 ))" \
  '{session_id:"s-far", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:$r, chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-far.json"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" --argjson r "$(( $(date +%s) - 100 ))" \
  '{session_id:"s-past", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:$r, chain:0, caught_at:$t, retries:1, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-past.json"
"$ROOT/lib/sleeper.sh" & sleeper_pid=$!
sleep 8
check "a passed reset is not starved by a far-future one (fallback fired)" \
  bash -c "[ -s '$SHIM_STATE/calls.log' ]"

# ────────── SIGTERM ends the sleeper, it does not merely unlock it ──────────
# Dropping the lock and looping on left a sleeper serving pendings with its
# claim released, so a second one could start beside it.
kill -TERM "$sleeper_pid" 2>/dev/null
sleep 2
check "SIGTERM exits the sleeper rather than only releasing its lock" \
  bash -c "! kill -0 $sleeper_pid 2>/dev/null"
wait "$sleeper_pid" 2>/dev/null

# ────────── looks_limited answers 'is this a limit', not 'is there a time' ──────────
( . "$ROOT/lib/parse-reset.sh"
  looks_limited "fetch failed at 2026-07-29T10:00:00.000Z" ) && ll_time=yes || ll_time=no
check "a failure that merely carries a timestamp is not a limit" test "$ll_time" = no
( . "$ROOT/lib/parse-reset.sh"
  looks_limited "You've reached your model limit. Run /usage-credits to continue." ) && ll_real=yes || ll_real=no
check "a real limit message with no reset time still reads as a limit" test "$ll_real" = yes

# ───────────────────────── notify: no desktop popup ─────────────────────────
echo "# notify"
fresh_env
( unset CARRY_ON_NOTIFY_LOG; . "$ROOT/lib/common.sh"; notify "silent notice test" )
check "notify records to notices.log, not a desktop popup" bash -c "grep -q 'silent notice test' '$CARRY_ON_HOME/notices.log'"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
