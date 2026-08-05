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
    # Remove the state FIRST. The pid file names only the newest sleeper for this
    # dir, so any earlier one — a run whose lock was stolen — is missed by the
    # kill below and would keep sleeping. With its pending queue gone it exits on
    # its own within one slice instead, which bounds the leak whatever we miss.
    rm -rf "$d"
    if [ -n "$pid" ]; then pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; fi
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
  # The wake stagger is 3 minutes in production; every multi-resume test here
  # would sit through it. Off by default, and switched on explicitly by the
  # tests that measure it.
  export CARRY_ON_WAKE_GAP=0
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
    # The real CLI's verbatim refusal for a session it is already running itself.
    if [ -f "$SHIM_STATE/bg-agent" ]; then
      echo "Error: Session x is currently running as a background agent (bg). Use \`claude agents\` to find and attach to it, or add --fork-session to branch off a copy."
      exit 1
    fi
    # A run that FAILED for an ordinary reason, whose transcript happens to talk
    # about background agents. This log is the resumed session's own output, so
    # that is not a hypothetical shape.
    if [ -f "$SHIM_STATE/bg-prose" ]; then
      echo "I checked whether this session is currently running as a background agent; it is not."
      exit 1
    fi
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
    # A resume that is still RUNNING when the test wants to act on it. Publishes
    # its own pid, so a test can prove the process itself died rather than
    # inferring it from the sleeper's bookkeeping.
    if [ -f "$SHIM_STATE/slow-resume" ]; then
      printf '%s' "$$" > "$SHIM_STATE/resume-child.pid"
      sleep 30
    fi
    # A resume that outlives its own TERM for a moment, so a test can observe
    # the sleeper's state WHILE a killed resume is still winding down. `sleep &
    # wait` deliberately, not a foreground sleep: a trapped signal interrupts
    # `wait`, where a foreground command would defer the handler until it ended
    # — the same bash fact the sleeper's own resume launch turns on.
    if [ -f "$SHIM_STATE/stubborn-resume" ]; then
      trap 'touch "$SHIM_STATE/child-signalled"; sleep 3; exit 143' TERM
      printf '%s' "$$" > "$SHIM_STATE/resume-child.pid"
      sleep 30 & wait $!
    fi
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
# The stamp's VALUE, not just its existence. Chain decay's consumer is well
# covered, but its producer was asserted only with `test -f`, and the three decay
# tests write this file themselves — so the stamp could be a placeholder with the
# suite fully green. The catcher's decay guard is `-gt 0`, so a zero means decay
# never fires and a long unattended run degrades to notify-only after max_chain
# resumes even when every window ran a healthy course.
check "the stamp is a live epoch, not a placeholder" \
  bash -c "at=\$(cat '$CARRY_ON_HOME/chains/s-cycle.at'); now=\$(date +%s); test \"\$at\" -gt \$((now - 600)) && test \"\$at\" -le \$((now + 5))"
# The reporter's per-project "was resumed" line is read from these two fields,
# and every test of it appends its OWN history lines — so the writer was never
# asserted. Emptying `cwd` or zeroing `ts` in `history_append` left the suite at
# 140/0 while the report could no longer fire for any real resume.
check "the resumed line the product wrote carries this cwd and a live ts" \
  bash -c "now=\$(date +%s); jq -rs --arg cwd '$TESTDIR/proj' --argjson now \"\$now\" '[.[]|select(.event==\"resumed\")]|last|((.cwd==\$cwd) and (.ts>(\$now-600)) and (.ts<=(\$now+5)))' '$CARRY_ON_HOME/history.jsonl' | grep -qx true"
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

# The chain cap's READER. Three tests assert the catcher WRITES notify_only, and
# nothing handed a `notify_only: true` pending to the sleeper — every sleeper
# fixture in the suite sets it false or omits it. So the flag's only consumer was
# dead to the suite: delete the guard and a runaway session is resumed past
# max_chain forever, which is the loop the cap exists to brake.
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-capped-flag", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t-1), chain:3, caught_at:$t, retries:0, notify_only:true}' \
  > "$CARRY_ON_HOME/pending/s-capped-flag.json"
"$ROOT/lib/sleeper.sh"
check "a notify_only pending is notified, never resumed" \
  bash -c "! grep -q -- '--resume s-capped-flag' '$SHIM_STATE/calls.log' 2>/dev/null && grep -q '\"event\":\"reset_notified\"' '$CARRY_ON_HOME/history.jsonl'"

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

# Same non-zero exit as the retry case above, one word different in the log, and
# the correct answer is the opposite: retire immediately. Observed live — two
# resets in a row spent ~15 min of retry schedule each on a session the CLI was
# never going to hand over.
fresh_env
touch "$SHIM_STATE/reset-done" "$SHIM_STATE/bg-agent"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-bgagent", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t-1), chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-bgagent.json"
"$ROOT/lib/sleeper.sh"
rm -f "$SHIM_STATE/bg-agent"
check "a session the CLI runs as a background agent is retired at once, never retried" \
  bash -c "grep -q '\"event\":\"resume_unattachable\"' '$CARRY_ON_HOME/history.jsonl' && ! grep -q '\"event\":\"resume_retry\"' '$CARRY_ON_HOME/history.jsonl' && test ! -f '$CARRY_ON_HOME/pending/s-bgagent.json'"
# The retire must follow an attempt that was actually made: "no retry" alone is
# equally satisfied by a pass that never launched anything.
check "the unattachable session was attempted exactly once" \
  bash -c "test \"\$(grep -c -- '--resume s-bgagent' '$SHIM_STATE/calls.log')\" = 1"

# The other side of that match. The log being read is the resumed session's own
# output, so "the CLI refused" and "the session talked about the CLI refusing"
# have to stay distinguishable, or an ordinary failure loses its retry.
fresh_env
touch "$SHIM_STATE/reset-done" "$SHIM_STATE/bg-prose"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-bgprose", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t-1), chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-bgprose.json"
"$ROOT/lib/sleeper.sh"
rm -f "$SHIM_STATE/bg-prose"
check "a failure that merely MENTIONS background agents keeps its retry" \
  bash -c "grep -q '\"event\":\"resume_retry\"' '$CARRY_ON_HOME/history.jsonl' && ! grep -q '\"event\":\"resume_unattachable\"' '$CARRY_ON_HOME/history.jsonl'"
check "it was attempted twice, like any other failed resume" \
  bash -c "test \"\$(grep -c -- '--resume s-bgprose' '$SHIM_STATE/calls.log')\" = 2"

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
( CARRY_ON_FALLBACK_STEPS="5 5 5"; export CARRY_ON_FALLBACK_STEPS; "$ROOT/lib/sleeper.sh" ) &
sleeper_pid=$!
# Time the window from the FIRST probe, never from the spawn. The schedule's
# first step is 5s and a "1s" slice costs SLICE plus two jq runs, so the first
# probe lands past 6s about half the time — and a fixed `sleep 6` that expires
# first leaves no calls.log at all, which reads as "very few probes" and passes
# the collapse check without the back-off code having run once.
backoff_first=false
for _ in $(seq 60); do
  [ -s "$SHIM_STATE/calls.log" ] && { backoff_first=true; break; }
  sleep 0.5
done
probe_t0=$SECONDS
sleep 6
# The subshell FORKS the sleeper, so $sleeper_pid is only the wrapper: killing
# it leaves the real one probing, and those probes land after the window closed
# but are still counted inside it. The sleeper names itself in the lock.
backoff_sleeper=$(cat "$CARRY_ON_HOME/sleeper.lock/pid" 2>/dev/null || true)
kill "$sleeper_pid" 2>/dev/null; wait "$sleeper_pid" 2>/dev/null
[ -n "$backoff_sleeper" ] && kill "$backoff_sleeper" 2>/dev/null
for _ in $(seq 25); do
  [ -n "$backoff_sleeper" ] && kill -0 "$backoff_sleeper" 2>/dev/null || break
  sleep 0.2
done
backoff_elapsed=$((SECONDS - probe_t0))
backoff_probes=$(grep -c -- '-p Reply' "$SHIM_STATE/calls.log" 2>/dev/null || true)
reap
# Both halves: the schedule ran at all, and it did not collapse. With SLICE=1
# and 5s steps correct behaviour is ~1 probe per 5s while the collapse probes
# with no sleep between, so half the elapsed seconds separates them.
check "the back-off schedule reaches its first probe" test "$backoff_first" = true
check "a past reset does not collapse the probe back-off to one slice" \
  test "${backoff_probes:-0}" -le $(( backoff_elapsed / 2 + 1 ))

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

# Both fixtures above use an EMPTY cwd, which the `-z` half catches, so the
# missing-directory half — the case the test above is named for — never ran.
# Deleting it costs a second billed probe cycle and records `resume_retry`, which
# misdescribes a directory that is simply gone.
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs"
jq -cn --arg cwd "$TESTDIR/gone-for-good" --argjson t "$(date +%s)" \
  '{session_id:"s-gonedir", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t-1), chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-gonedir.json"
"$ROOT/lib/sleeper.sh"
check "a cwd that no longer exists -> resume_failed on the first pass, never launched" \
  bash -c "! grep -q -- '--resume s-gonedir' '$SHIM_STATE/calls.log' 2>/dev/null && grep -q '\"event\":\"resume_failed\"' '$CARRY_ON_HOME/history.jsonl' && ! grep -q '\"event\":\"resume_retry\"' '$CARRY_ON_HOME/history.jsonl'"

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

# A session carry-on deliberately did NOT resume says so, rather than dropping
# silently back to plain "armed" as though it had been forgotten.
mkdir -p "$CARRY_ON_HOME/chain-me"; echo '{}' > "$CARRY_ON_HOME/chain-me/s-line.json"
out=$(spayload s-line | "$ROOT/hooks/statusline.sh")
check "chained badge when the session was deliberately not resumed" \
  bash -c "printf '%s' \"$out\" | grep -q 'chained'"
rm -f "$CARRY_ON_HOME/chain-me/s-line.json"

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
# …and that assertion passed for the wrong reason: `../../etc/passwd` resolves to
# nothing under the test state dir, so an EMPTY badge proves only that the file was
# missing. Aim the traversal at a marker that really exists, and the charset guard
# is the only thing left standing between a hostile id and a badge rendered in a
# session carry-on was never armed for.
mkdir -p "$CARRY_ON_HOME/sessions"; : > "$CARRY_ON_HOME/sessions/s-line"
out=$(printf '{"session_id":"../sessions/s-line"}' | "$ROOT/hooks/statusline.sh")
check "a traversal resolving to a REAL marker still yields no badge" test -z "$out"

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

# The two fast paths, which twelve wiring tests never reached: every fixture
# above resolves through the one-level-down loop, because its statusLine command
# names a dispatcher script and neither the badge nor the drop-in dir appears in
# the command STRING. Inverting both `case` arms left the suite at 140/0 — and
# these are the two configurations the badge's own header documents.
fresh_env
printf '#!/bin/bash\necho badge\n' > "$CLAUDE_CONFIG_DIR/hooks/carry-on-statusline.sh"
jq -n --arg c "bash \"$CLAUDE_CONFIG_DIR/hooks/carry-on-statusline.sh\"" \
  '{statusLine:{type:"command",command:$c}}' > "$CLAUDE_CONFIG_DIR/settings.json"
check "wired: the statusLine command names the badge directly" wired

fresh_env
mkdir -p "$CLAUDE_CONFIG_DIR/statusline.d"
: > "$CLAUDE_CONFIG_DIR/statusline.d/60-carry-on.sh"
jq -n --arg c 'for f in "$CLAUDE_CONFIG_DIR"/statusline.d/*.sh; do bash "$f"; done' \
  '{statusLine:{type:"command",command:$c}}' > "$CLAUDE_CONFIG_DIR/settings.json"
check "wired: an inline drop-in loop with our fragment present" wired
rm -f "$CLAUDE_CONFIG_DIR/statusline.d/60-carry-on.sh"
check "not wired: an inline drop-in loop with our fragment missing" notwired

# A settings command may store the path unexpanded, and nothing tested that the
# expansion happens — so a wired badge could be read as un-wired and the user
# nagged to re-wire what already works.
check "a settings path stored as \$HOME is expanded before it is tested" \
  bash -c ". \"$ROOT/lib/common.sh\"; test \"\$(_expand_config_path '\"\$HOME/.claude/hooks/x.sh\"')\" = \"\$HOME/.claude/hooks/x.sh\""

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

# ────────── a session that comes back on its own retires its pending ──────────
# Only carry-on resuming a session used to retire its pending, so a session the
# user brought back by hand kept one forever: the badge read "waiting for reset"
# for the life of the session, and the sleeper still had it QUEUED — at the next
# reset it would launch a headless resume of a session being actively typed in.
echo "# a live session is not still waiting"
fresh_env
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/resuming"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-back", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t+900), chain:0, caught_at:$t}' \
  > "$CARRY_ON_HOME/pending/s-back.json"
printf '{"session_id":"s-back","cwd":"%s"}' "$TESTDIR/proj" | "$ROOT/hooks/session-start.sh" >/dev/null
check "a session that starts again is no longer waiting for a reset" \
  test ! -f "$CARRY_ON_HOME/pending/s-back.json"
check "coming back by hand is recorded" \
  grep -q '"event":"reattached"' "$CARRY_ON_HOME/history.jsonl"
reap

# ...but NOT when the SessionStart is carry-on's own headless resume: that child
# fires this hook too, and its pending is the record the sleeper needs to retry.
fresh_env
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/resuming"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-mid", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t+900), chain:0, caught_at:$t}' \
  > "$CARRY_ON_HOME/pending/s-mid.json"
: > "$CARRY_ON_HOME/resuming/s-mid"
printf '{"session_id":"s-mid","cwd":"%s"}' "$TESTDIR/proj" | "$ROOT/hooks/session-start.sh" >/dev/null
check "our own resume does not delete the pending it may need to retry" \
  test -f "$CARRY_ON_HOME/pending/s-mid.json"
reap

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
# Wait for the re-queue to be RECORDED, never a guessed sleep. The first two
# checks look for a pending file the FIXTURE already wrote, so a sleeper that
# never reached its probe satisfies them without the code having run.
for _ in $(seq 60); do
  grep -q '"event":"resume_requeued"' "$CARRY_ON_HOME/history.jsonl" 2>/dev/null && break
  sleep 0.5
done
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
# The starved case never probes at all, so waiting for the probe IS the
# assertion — bounded, rather than a fixed sleep the machine can outrun.
for _ in $(seq 60); do [ -s "$SHIM_STATE/calls.log" ] && break; sleep 0.5; done
check "a passed reset is not starved by a far-future one (fallback fired)" \
  bash -c "[ -s '$SHIM_STATE/calls.log' ]"

# ────────── SIGTERM ends the sleeper, it does not merely unlock it ──────────
# Dropping the lock and looping on left a sleeper serving pendings with its
# claim released, so a second one could start beside it.
kill -TERM "$sleeper_pid" 2>/dev/null
for _ in $(seq 40); do kill -0 "$sleeper_pid" 2>/dev/null || break; sleep 0.25; done
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

# ═══════════════════ cache economy: stagger, gate, policy ═══════════════════
# A wake is not free: a session idle past the prompt-cache TTL re-primes its
# ENTIRE transcript as cache-creation tokens on its first turn. These cover the
# three brakes — space the wakes, refuse the ones that cost more than they are
# worth, and let a fleet say up front which sessions may be resumed at all.

# Run a cache-economy function in isolation. The libraries are the unit here;
# the sleeper integration is exercised further down.
economy() { # economy FUNCTION ARGS...
  ( . "$ROOT/lib/common.sh"; . "$ROOT/lib/cache-economy.sh"; "$@" )
}

# A transcript that looks like the real thing: untimestamped metadata first
# (which is why the age probe scans a head rather than line 1), then JSONL
# padded to size.
fake_transcript() { # fake_transcript SESSION_ID BYTES [STARTED_ISO]
  local dir="$CLAUDE_CONFIG_DIR/projects/-fake-proj" f pad
  mkdir -p "$dir"
  f="$dir/$1.jsonl"
  printf '{"type":"mode","mode":"normal"}\n' > "$f"
  [ -n "${3:-}" ] && printf '{"type":"user","timestamp":"%s"}\n' "$3" >> "$f"
  pad='{"type":"assistant","text":"'$(printf 'x%.0s' $(seq 1 200))'"}'
  yes "$pad" 2>/dev/null | head -c "$2" >> "$f"
}

echo "# cache economy: the gate's threshold logic"
fresh_env
r=$(economy gate_verdict 3145728 14400 0)
check "fat + long idle trips the gate, and the reason names the size and the idle" \
  bash -c "printf '%s' '$r' | grep -q 'transcript 3145728B > 2097152B' && printf '%s' '$r' | grep -q 'idle 14400s'"
r=$(economy gate_verdict 3145728 60 86400)
check "fat + old session trips the gate on age alone" bash -c "printf '%s' '$r' | grep -q 'age 86400s'"
r=$(economy gate_verdict 3145728 60 60)
check "fat but WARM is resumed — the case carry-on exists for" test -z "$r"
r=$(economy gate_verdict 204800 99999 99999)
check "lean is resumed however cold it got" test -z "$r"
r=$(CARRY_ON_GATE_TRANSCRIPT_BYTES=0 economy gate_verdict 3145728 99999 99999)
check "gate_transcript_bytes=0 disables the gate entirely" test -z "$r"
r=$(CARRY_ON_GATE_IDLE=0 CARRY_ON_GATE_AGE=0 economy gate_verdict 3145728 99999 99999)
check "size with both cold signals disabled never gates on its own" test -z "$r"
r=$(economy gate_verdict 3145728 14400 86400)
check "both cold signals report both, not the first one found" \
  bash -c "printf '%s' '$r' | grep -q 'idle' && printf '%s' '$r' | grep -q 'age'"

echo "# cache economy: transcript probes"
fresh_env
fake_transcript s-probe 4096 "2026-08-04T10:00:00.000Z"
p=$(economy transcript_path s-probe)
check "the transcript is found by session id, whatever the cwd munging" test -n "$p"
size=$(economy file_size "$p")
check "its size is read" test "$size" -gt 4000
started=$(economy transcript_started_at "$p")
check "session start comes from the first TIMESTAMPED line, past the metadata" \
  bash -c "test '$started' -gt 0 && test \"\$(date -r $started -u +%Y-%m-%dT%H:%M 2>/dev/null || date -u -d @$started +%Y-%m-%dT%H:%M)\" = '2026-08-04T10:00'"
fake_transcript s-nots 4096
nots=$(economy transcript_started_at "$CLAUDE_CONFIG_DIR/projects/-fake-proj/s-nots.jsonl")
check "a transcript with no timestamp leaves age UNKNOWN, it does not invent one" \
  test "$nots" = 0
economy transcript_path s-nowhere >/dev/null 2>&1 && found=yes || found=no
check "a session with no transcript on disk cannot be gated" test "$found" = no

echo "# cache economy: a cold fat session is chained, not resumed"
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
fake_transcript s-fat 3145728
caught=$(( $(date +%s) - 14400 ))   # caught 4h ago: long past the prompt-cache TTL
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$caught" \
  '{session_id:"s-fat", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t+1),
    chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-fat.json"
"$ROOT/lib/sleeper.sh"
check "a 3MB transcript idle 4h is not resumed" \
  bash -c "! grep -q -- '--resume s-fat' '$SHIM_STATE/calls.log' 2>/dev/null"
check "the wake is consumed, not left to fire later" test ! -f "$CARRY_ON_HOME/pending/s-fat.json"
check "a chain-me signal is written for a fresh successor" test -f "$CARRY_ON_HOME/chain-me/s-fat.json"
check "the signal carries session, cwd, caught_at and the original wake" \
  bash -c "jq -re '.session_id == \"s-fat\" and .cwd == \"$TESTDIR/proj\" and .caught_at == $caught and .written_at > 0 and .wake.session_id == \"s-fat\" and .wake.permission_mode == \"acceptEdits\"' '$CARRY_ON_HOME/chain-me/s-fat.json'"
check "the reason names the thresholds that tripped, with values" \
  bash -c "jq -re '.reason | test(\"transcript [0-9]+B > 2097152B\") and test(\"idle [0-9]+s > 3600s\")' '$CARRY_ON_HOME/chain-me/s-fat.json'"
check "it is logged visibly, in history and in the notices" \
  bash -c "grep -q '\"event\":\"chain_me\"' '$CARRY_ON_HOME/history.jsonl' && grep -q 'not resumed' '$CARRY_ON_NOTIFY_LOG'"
# Composition with chain-decay: a session that was never resumed must not look
# like one that was. Stamping the handover here would tell the catcher a fresh
# window had been granted, and a gated session would silently decay the chain.
check "a gated session spends no chain step and gets no window stamp" \
  bash -c "test ! -f '$CARRY_ON_HOME/chains/s-fat' && test ! -f '$CARRY_ON_HOME/chains/s-fat.at'"
check "carry-on status surfaces the signal" \
  bash -c "'$ROOT/bin/carry-on' status | grep -q 'chain-me signals'"

echo "# cache economy: a lean recent session still resumes exactly as before"
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
fake_transcript s-lean 204800
caught=$(( $(date +%s) - 600 ))     # 10 minutes: cache still warm
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$caught" \
  '{session_id:"s-lean", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t+1),
    chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-lean.json"
"$ROOT/lib/sleeper.sh"
check "200KB idle 10min resumes, untouched by the gate" \
  bash -c "grep -q -- '--resume s-lean' '$SHIM_STATE/calls.log' && test ! -f '$CARRY_ON_HOME/chain-me/s-lean.json'"

# A signal is advice about a session, not a permanent label on it. Once the
# session carries on — resumed here, reattached below — the advice is WRONG, and
# nothing else ever cleared it: it held the badge at "chained · start fresh" and
# sat in `carry-on status` recommending a successor for a month.
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" \
  "$CARRY_ON_HOME/daily" "$CARRY_ON_HOME/chain-me"
echo '{"session_id":"s-stale"}' > "$CARRY_ON_HOME/chain-me/s-stale.json"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-stale", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t-1),
    chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-stale.json"
"$ROOT/lib/sleeper.sh"
check "a later successful resume retires the session's stale chain-me signal" \
  bash -c "grep -q -- '--resume s-stale' '$SHIM_STATE/calls.log' && test ! -f '$CARRY_ON_HOME/chain-me/s-stale.json'"

fresh_env
mkdir -p "$CARRY_ON_HOME/chain-me"
echo '{"session_id":"s-back2"}' > "$CARRY_ON_HOME/chain-me/s-back2.json"
printf '{"session_id":"s-back2","cwd":"%s"}' "$TESTDIR/proj" | "$ROOT/hooks/session-start.sh" >/dev/null
reap
check "the user reattaching retires it too — the successor it asked for is moot" \
  test ! -f "$CARRY_ON_HOME/chain-me/s-back2.json"

echo "# cache economy: the wake stagger"
fresh_env
export CARRY_ON_WAKE_GAP=60
mkdir -p "$CARRY_ON_HOME"
# Five hooks claiming at once — the exact race the shared reservation exists
# for. Two claimants concluding "I'm first" is the herd this feature removes.
for _ in 1 2 3 4 5; do
  ( printf '%s\n' "$(economy stagger_claim)" ) >> "$TESTDIR/slots.txt" &
done
wait
check "five racing claims reserve five DISTINCT slots" \
  bash -c "test \"\$(sort -u '$TESTDIR/slots.txt' | wc -l | tr -d ' ')\" = 5"
check "the slots are exactly one gap apart, first one immediate" \
  bash -c "s=\$(sort -n '$TESTDIR/slots.txt'); f=\$(printf '%s' \"\$s\" | head -1); l=\$(printf '%s' \"\$s\" | tail -1); now=\$(date +%s); test \$((l - f)) = 240 && test \"\$f\" -le \"\$now\""
r=$(CARRY_ON_WAKE_GAP=0 economy stagger_claim)
check "wake_gap=0 disables the stagger — every claim is immediate" \
  bash -c "now=\$(date +%s); test \"$r\" -ge \$((now - 5)) && test \"$r\" -le \$((now + 5))"
export CARRY_ON_WAKE_GAP=0

echo "# cache economy: the wake-slot lock"
# The reservation's whole job is that two claimants never conclude "I'm first".
# A lock that is stolen on a timer alone breaks exactly that: six processes
# forking at once on a loaded machine is this feature's NORMAL case, and a
# holder that is merely slow would have its slot handed to someone else.
fresh_env
export CARRY_ON_WAKE_GAP=60
mkdir -p "$CARRY_ON_HOME"
sleep 30 & holder=$!
printf '%s' "$holder" > "$CARRY_ON_HOME/wake-slot.lock"
printf '%s' 4242424242 > "$CARRY_ON_HOME/wake-slot"   # a reservation it must not touch
slot=$(economy stagger_claim)
check "a lock held by a LIVE process is never stolen — 'slow' is not 'dead'" \
  bash -c "test \"\$(cat '$CARRY_ON_HOME/wake-slot.lock' 2>/dev/null)\" = '$holder'"
# …and the wake still happens. This lock guards an optimisation; a resume that
# never fired because a lock file could not be taken would be the worse bug.
check "a lock it cannot take degrades the stagger, it never blocks the resume" \
  bash -c "now=\$(date +%s); test -n '$slot' && test '$slot' -ge \$((now - 60)) && test '$slot' -le \$((now + 5))"
# But it must not write the shared queue unprotected on the way out. Every
# giver-up would read the same value and write the same slot back — one instant
# for all of them, and a reservation none of them respected left behind to
# mis-stagger everyone after. That is the herd, restored by the fallback.
check "a claim that could not lock leaves the shared reservation untouched" \
  bash -c "test \"\$(cat '$CARRY_ON_HOME/wake-slot')\" = 4242424242"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# A pid naming no live process — obtained BEFORE the test directory exists.
# This suite traps EXIT, so bash keeps a subshell alive to run the handler
# instead of exec'ing the background command, and killing that job fires
# `cleanup` inside it: every registered test directory is deleted, including
# the one this fixture is about to write into. Planting the lock afterwards
# then failed with ENOENT, and `test ! -f` below was satisfied by a lock that
# had never existed — the check passed while proving nothing.
sleep 5 & dead=$!; kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null
fresh_env
export CARRY_ON_WAKE_GAP=60
mkdir -p "$CARRY_ON_HOME"
printf '%s' "$dead" > "$CARRY_ON_HOME/wake-slot.lock"
# The fixture asserts itself. A planting that silently failed leaves `test ! -f`
# trivially true below, and the check would pass while proving nothing — which
# is exactly what it did until this line was added.
check "fixture: a lock naming a dead holder was really planted" \
  test -f "$CARRY_ON_HOME/wake-slot.lock"
slot=$(economy stagger_claim)
check "a lock naming a DEAD holder is stolen, not queued behind forever" \
  bash -c "test -n '$slot' && test ! -f '$CARRY_ON_HOME/wake-slot.lock'"
export CARRY_ON_WAKE_GAP=0

echo "# sleeper: SIGTERM while a resume is in flight"
# `wait` is interruptible by a trapped signal — the foreground command it
# replaced was not. Without the handler taking the child with it, a terminated
# sleeper leaves a headless resume running unsupervised with its pending still
# on disk, and the next ensure_sleeper starts a SECOND resume of that session.
fresh_env
touch "$SHIM_STATE/reset-done" "$SHIM_STATE/slow-resume"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-term", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t-1),
    chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-term.json"
"$ROOT/lib/sleeper.sh" & term_sleeper=$!
# Wait for the resume to be genuinely in flight — never a guessed sleep.
for _ in $(seq 100); do [ -s "$SHIM_STATE/resume-child.pid" ] && break; sleep 0.2; done
term_child=$(cat "$SHIM_STATE/resume-child.pid" 2>/dev/null || echo 0)
kill -TERM "$term_sleeper" 2>/dev/null
for _ in $(seq 40); do kill -0 "$term_sleeper" 2>/dev/null || break; sleep 0.25; done
wait "$term_sleeper" 2>/dev/null
check "a terminated sleeper takes its in-flight resume with it, never orphans it" \
  bash -c "test '$term_child' -gt 0 && ! kill -0 '$term_child' 2>/dev/null"
check "the pending survives — the session was not resumed, so it is still owed one" \
  test -f "$CARRY_ON_HOME/pending/s-term.json"
check "the 'resuming…' marker is cleared, not left claiming a run that is over" \
  test ! -f "$CARRY_ON_HOME/resuming/s-term"
rm -f "$SHIM_STATE/slow-resume"

# …and it holds its CLAIM until that child is actually gone. The lock is the
# only thing stopping ensure_sleeper from starting a second sleeper, and the
# pending is deliberately left on disk — so dropping the lock while the killed
# resume was still winding down let a fresh sleeper relaunch the same session
# beside a process still writing its transcript.
fresh_env
touch "$SHIM_STATE/reset-done" "$SHIM_STATE/stubborn-resume"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-lockorder", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t-1),
    chain:0, caught_at:$t, retries:0, notify_only:false}' \
  > "$CARRY_ON_HOME/pending/s-lockorder.json"
"$ROOT/lib/sleeper.sh" & order_sleeper=$!
for _ in $(seq 100); do [ -s "$SHIM_STATE/resume-child.pid" ] && break; sleep 0.2; done
kill -TERM "$order_sleeper" 2>/dev/null
# Wait for the evidence the child was signalled, never a guessed sleep. It then
# lingers ~3s, which is the window this assertion has to land in.
for _ in $(seq 100); do [ -f "$SHIM_STATE/child-signalled" ] && break; sleep 0.1; done
check "the claim is held until the killed resume is actually gone" \
  test -d "$CARRY_ON_HOME/sleeper.lock"
for _ in $(seq 80); do kill -0 "$order_sleeper" 2>/dev/null || break; sleep 0.25; done
wait "$order_sleeper" 2>/dev/null
check "…and released once it is, so the next sleeper may take over" \
  test ! -d "$CARRY_ON_HOME/sleeper.lock"
rm -f "$SHIM_STATE/stubborn-resume"

echo "# cache economy: one reset, several sessions"
fresh_env
# Four, asserted at three. The wait is sliced a second at a time (so a cancel
# is not deferred for the whole gap, and a suspend cannot oversleep it), which
# lets a wake overshoot its slot by up to a second — and launch stamps are whole
# seconds, so a gap of N can legitimately read as N-1. Asserting the gap exactly
# would be measuring that jitter; asserting one less still fails the moment the
# stagger is removed, which is what the check is for.
export CARRY_ON_WAKE_GAP=4
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
now=$(date +%s)
for spec in "s-q-old 300" "s-q-mid 200" "s-q-new 100"; do
  set -- $spec
  jq -cn --arg id "$1" --arg cwd "$TESTDIR/proj" --argjson t "$((now - $2))" \
    '{session_id:$id, cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t+1),
      chain:0, caught_at:$t, retries:0, notify_only:false}' \
    > "$CARRY_ON_HOME/pending/$1.json"
done
"$ROOT/lib/sleeper.sh"
export CARRY_ON_WAKE_GAP=0
order=$(grep -o -- '--resume s-q-[a-z]*' "$SHIM_STATE/calls.log" | sed 's/--resume //' | tr '\n' ' ')
check "wakes fire most-recently-caught first" test "$order" = "s-q-new s-q-mid s-q-old "
_launched_at() { ls "$CARRY_ON_HOME/logs" | grep "^$1-" | head -1 | sed "s/^$1-//; s/\.log\$//"; }
a=$(_launched_at s-q-new); b=$(_launched_at s-q-mid); c=$(_launched_at s-q-old)
check "the wakes are spaced, not a herd — each at least a gap after the last" \
  test $((b - a)) -ge 3 -a $((c - b)) -ge 3
check "all three still resumed — staggering delays wakes, it never drops them" \
  bash -c "test \"\$(grep -c -- '--resume s-q-' '$SHIM_STATE/calls.log')\" = 3"

echo "# resume log: a resumed session's old pid maps to its new one"
fresh_env
touch "$SHIM_STATE/reset-done"
mkdir -p "$CARRY_ON_HOME/pending" "$CARRY_ON_HOME/logs" "$CARRY_ON_HOME/chains" "$CARRY_ON_HOME/daily"
jq -cn --arg cwd "$TESTDIR/proj" --argjson t "$(date +%s)" \
  '{session_id:"s-pid", cwd:$cwd, permission_mode:"acceptEdits", reset_epoch:($t-1),
    chain:0, caught_at:$t, retries:0, notify_only:false, pid:4242}' \
  > "$CARRY_ON_HOME/pending/s-pid.json"
# A line already in the log. With only ever ONE resume in the fixture, "the log
# has one line" is satisfied identically by appending and by TRUNCATING, so the
# append this test is named for went unmeasured. A supervisor reads this file
# for history; a truncating writer would erase every earlier resume.
printf '{"resumed_at":1,"session_id":"s-earlier","old_pid":1,"new_pid":2}\n' > "$CARRY_ON_HOME/resumes.jsonl"
"$ROOT/lib/sleeper.sh"
check "the resume log names both pids, so a supervisor stops reporting a false death" \
  bash -c "jq -re 'select(.session_id == \"s-pid\") | .old_pid == 4242 and .new_pid > 0 and .resumed_at > 0' '$CARRY_ON_HOME/resumes.jsonl' | grep -qx true"
check "the new pid is the resume process, not the sleeper's guess" \
  bash -c "n=\$(jq -r 'select(.session_id==\"s-pid\") | .new_pid' '$CARRY_ON_HOME/resumes.jsonl'); test \"\$n\" != 4242 && test \"\$n\" -gt 0"
check "the log is append-only — an earlier entry survives a later resume" \
  bash -c "test \"\$(wc -l < '$CARRY_ON_HOME/resumes.jsonl' | tr -d ' ')\" = 2 && grep -q s-earlier '$CARRY_ON_HOME/resumes.jsonl'"

echo "# per-session resume policy"
fresh_env
printf 'chain\n' > "$TESTDIR/proj/.carry-on"
payload s-policy-chain "$TESTDIR/proj" acceptEdits | "$ROOT/hooks/stop-failure.sh"
# BEFORE reap, which removes the lock dir itself — asserting after it made this
# unconditionally true and the check proved nothing.
check "no sleeper is spawned for a session that will never be resumed" \
  test ! -d "$CARRY_ON_HOME/sleeper.lock"
reap
check "mode=chain never queues a wake — it signals for a fresh successor" \
  bash -c "test ! -f '$CARRY_ON_HOME/pending/s-policy-chain.json' && test -f '$CARRY_ON_HOME/chain-me/s-policy-chain.json'"
check "the chain-me signal says the policy sent it, not a threshold" \
  bash -c "jq -re '.reason == \"policy: mode=chain\" and .wake.cwd == \"$TESTDIR/proj\"' '$CARRY_ON_HOME/chain-me/s-policy-chain.json'"

fresh_env
printf 'off\n' > "$TESTDIR/proj/.carry-on"
payload s-policy-off "$TESTDIR/proj" acceptEdits | "$ROOT/hooks/stop-failure.sh"
reap
check "mode=off tracks nothing at all — no wake, no signal" \
  bash -c "test ! -f '$CARRY_ON_HOME/pending/s-policy-off.json' && test ! -f '$CARRY_ON_HOME/chain-me/s-policy-off.json'"

fresh_env
printf 'notify\n' > "$TESTDIR/proj/.carry-on"
payload s-policy-notify "$TESTDIR/proj" acceptEdits | "$ROOT/hooks/stop-failure.sh"
reap
check "mode=notify keeps the wake but marks it notify-only" \
  bash -c "jq -re '.notify_only == true' '$CARRY_ON_HOME/pending/s-policy-notify.json'"

fresh_env
printf 'chain\n' > "$TESTDIR/proj/.carry-on"
mkdir -p "$CARRY_ON_HOME/modes"; printf 'resume\n' > "$CARRY_ON_HOME/modes/s-policy-pin"
payload s-policy-pin "$TESTDIR/proj" acceptEdits | "$ROOT/hooks/stop-failure.sh"
reap
check "a session's own policy outranks the project's" \
  bash -c "test -f '$CARRY_ON_HOME/pending/s-policy-pin.json'"

# Precedence alone left the pin's own EFFECT untested: every assertion above
# passes for a pin that is read and then ignored.
fresh_env
mkdir -p "$CARRY_ON_HOME/modes"; printf 'chain\n' > "$CARRY_ON_HOME/modes/s-policy-pinchain"
payload s-policy-pinchain "$TESTDIR/proj" acceptEdits | "$ROOT/hooks/stop-failure.sh"
reap
check "a session pinned to chain really chains — no wake, a signal instead" \
  bash -c "test ! -f '$CARRY_ON_HOME/pending/s-policy-pinchain.json' && jq -re '.reason == \"policy: mode=chain\"' '$CARRY_ON_HOME/chain-me/s-policy-pinchain.json'"

fresh_env
printf 'nonsense\n' > "$TESTDIR/proj/.carry-on"
payload s-policy-junk "$TESTDIR/proj" acceptEdits | "$ROOT/hooks/stop-failure.sh"
reap
check "an unreadable policy falls back to resume — it can hold the net back, never break it" \
  bash -c "test -f '$CARRY_ON_HOME/pending/s-policy-junk.json'"

fresh_env
rm -f "$TESTDIR/proj/.carry-on"
out=$(cd "$TESTDIR/proj" && "$ROOT/bin/carry-on" mode chain)
check "carry-on mode writes the project's .carry-on file" \
  bash -c "grep -qx chain '$TESTDIR/proj/.carry-on'"
check "carry-on mode with no value reports what is in force" \
  bash -c "test \"\$(cd '$TESTDIR/proj' && '$ROOT/bin/carry-on' mode)\" = chain"
out=$("$ROOT/bin/carry-on" mode off s-pinned)
check "carry-on mode <m> <id> pins one session" \
  bash -c "grep -qx off '$CARRY_ON_HOME/modes/s-pinned'"
check "carry-on mode rejects a value it does not implement" \
  bash -c "! '$ROOT/bin/carry-on' mode sideways 2>/dev/null"
check "carry-on mode rejects a session id that is a path" \
  bash -c "! '$ROOT/bin/carry-on' mode off '../../etc/passwd' 2>/dev/null"

echo "# config: env outranks the file"
fresh_env
mkdir -p "$CARRY_ON_HOME"; echo "wake_gap=999" > "$CARRY_ON_HOME/config"
check "an env override beats the shared config file" \
  bash -c "test \"\$(CARRY_ON_WAKE_GAP=7 bash -c '. \"$ROOT/lib/common.sh\"; cfg_wake_gap')\" = 7"
check "without the env var the file still rules" \
  bash -c "test \"\$(env -u CARRY_ON_WAKE_GAP bash -c '. \"$ROOT/lib/common.sh\"; cfg_wake_gap')\" = 999"
check "a non-numeric override falls back to the documented default, never to unlimited" \
  bash -c "test \"\$(CARRY_ON_WAKE_GAP=soon bash -c '. \"$ROOT/lib/common.sh\"; cfg_wake_gap')\" = 180"

echo "# external contract: the pending shape consumers glob and cancel"
fresh_env
payload s-contract "$TESTDIR/proj" acceptEdits | "$ROOT/hooks/stop-failure.sh"
reap
check "a pending still carries every field the documented shape promised" \
  bash -c "jq -re 'has(\"session_id\") and has(\"cwd\") and has(\"permission_mode\") and has(\"reset_epoch\") and has(\"chain\") and has(\"caught_at\") and has(\"retries\") and has(\"notify_only\")' '$CARRY_ON_HOME/pending/s-contract.json'"
check "the new field is additive" \
  bash -c "jq -re 'has(\"pid\")' '$CARRY_ON_HOME/pending/s-contract.json'"
check "carry-on cancel <id> still retires it" \
  bash -c "'$ROOT/bin/carry-on' cancel s-contract >/dev/null && test ! -f '$CARRY_ON_HOME/pending/s-contract.json'"

# The wake record is built with jq and written with printf, and printf cannot
# fail — so a jq that died would publish an EMPTY file into the very directory
# a watchdog globs, where nothing downstream can tell it from a real claim.
fresh_env
mkdir -p "$TESTDIR/wrapbin"
printf '#!/bin/bash\ncase "$*" in *notify_only*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v jq)" \
  > "$TESTDIR/wrapbin/jq"
chmod +x "$TESTDIR/wrapbin/jq"
# The export has to cover the HOOK, not just the payload — a `VAR=x cmd | hook`
# prefix applies only to the left of the pipe, and the hook is what runs jq.
( export PATH="$TESTDIR/wrapbin:$PATH"
  payload s-torn "$TESTDIR/proj" acceptEdits | "$ROOT/hooks/stop-failure.sh" )
reap
check "a wake record that could not be built is never published as a pending" \
  bash -c "test ! -e '$CARRY_ON_HOME/pending/s-torn.json'"
check "…and the catch says so rather than failing silently" \
  bash -c "grep -q 'NOT queued' '$CARRY_ON_NOTIFY_LOG'"

# ───────────────────────── notify: no desktop popup ─────────────────────────
echo "# notify"
fresh_env
( unset CARRY_ON_NOTIFY_LOG; . "$ROOT/lib/common.sh"; notify "silent notice test" )
check "notify records to notices.log, not a desktop popup" bash -c "grep -q 'silent notice test' '$CARRY_ON_HOME/notices.log'"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
