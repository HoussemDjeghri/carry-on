#!/bin/bash
# The waker. Spawned detached via ensure_sleeper; the only long-lived
# carry-on process, and it lives only while a wait is pending. Sleeps to the
# earliest relevant reset, probe-confirms the window actually lifted (a
# limited probe fails free), then works through every pending session.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=parse-reset.sh
. "$ROOT/lib/parse-reset.sh"
# shellcheck source=cache-economy.sh
. "$ROOT/lib/cache-economy.sh"

ensure_dirs
mkdir "$LOCK_DIR" 2>/dev/null || true
echo $$ > "$LOCK_DIR/pid"
# Any "resuming" marker still here is stale from a crashed run — this fresh
# sleeper is the only one that resumes, so clear them before it starts.
rm -f "$RESUMING_DIR"/* 2>/dev/null || true

SLICE="${CARRY_ON_SLICE:-60}"
# Fallback wait steps (seconds) when no reset time is known: 15m, 30m, then hourly.
FALLBACK_STEPS="${CARRY_ON_FALLBACK_STEPS:-900 1800 3600}"
attempt=0
limited=0   # did a probe in this sleeper's life come back still limited?
CLAUDE="$(claude_bin)"   # resolve once; the detached env may drift over days

# Exit is deliberate-only: drop the lock, then re-check — if a catcher added
# a pending in the gap between our last look and the lock removal, take the
# lock back and keep serving instead of stranding it.
finish() {
  rm -rf "$LOCK_DIR"
  if pending_exists && mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    return 1   # caller loops again
  fi
  exit 0
}
# EXIT, not merely unlock. Dropping the lock and looping on left a sleeper still
# serving pendings with its claim released, so ensure_sleeper was free to start a
# second one beside it. `carry-on cancel` only appeared to kill it because it also
# removed the pendings, which made the loop self-exit a slice later.
#
# The in-flight resume goes with us. `wait` is INTERRUPTIBLE by a trapped signal,
# unlike the foreground command this used to be — bash used to defer the handler
# until the resume finished. So a terminated sleeper would now leave a headless
# resume running unsupervised with its pending still on disk, and the next hook
# to call ensure_sleeper would start a SECOND resume of the same session, two
# writers on one transcript. The pending is deliberately left alone: the session
# was not resumed, and a later sleeper should still go back for it.
RESUME_CHILD=""
RESUME_ID=""
#
# The lock goes LAST, after the child is actually gone. The lock is the only
# thing stopping ensure_sleeper from starting a second sleeper, and the pending
# is deliberately left on disk — so releasing it while the killed child was
# still winding down let a fresh sleeper pick that same pending up and launch a
# second resume beside a process still writing the transcript. That is the
# two-writers failure this handler exists to prevent, reintroduced by ordering.
_terminate() {
  local i=0
  if [ -n "$RESUME_CHILD" ]; then
    kill "$RESUME_CHILD" 2>/dev/null || true
    # Bounded: a child that ignores TERM must not strand the lock forever
    # either. Five seconds, then the claim is released regardless.
    while [ "$i" -lt 50 ] && kill -0 "$RESUME_CHILD" 2>/dev/null; do
      sleep 0.1
      i=$((i + 1))
    done
    [ -n "$RESUME_ID" ] && rm -f "$RESUMING_DIR/$RESUME_ID"
  fi
  rm -rf "$LOCK_DIR"
  exit 143
}
trap _terminate TERM INT

# Newest catch first. When the cap binds it has to bind on the STALEST pending,
# and glob order spends it on whichever session id sorts first instead — a
# backlog of 22 pendings once ate a whole cap that way while the session that
# mattered was capped. Listing before calling also makes it safe for a callback
# to delete its own file, which every callback here does.
each_pending() { # each_pending CALLBACK  (callback FILE; skips vanished files)
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] && "$1" "$f"
  done < <(
    for f in "$PENDING_DIR"/*.json; do
      [ -f "$f" ] || continue
      printf '%s\t%s\n' "$(jq -r '.caught_at // 0' "$f" 2>/dev/null || echo 0)" "$f"
    done | sort -rn -k1,1 | cut -f2-
  )
}

expire_stale() {
  local max_wait now
  max_wait=$(cfg_max_wait)
  now=$(now_epoch)
  _expire_one() {
    local caught id
    caught=$(jq -r '.caught_at // 0' "$1" 2>/dev/null) || { rm -f "$1"; return; }
    if [ $((now - caught)) -gt "$max_wait" ]; then
      id=$(jq -r '.session_id' "$1")
      history_append expired "$id" "$(jq -r '.cwd' "$1")"
      notify "carry-on: session ${id:0:8} waited past the cap without a reset — expired. carry-on status"
      rm -f "$1"
    fi
  }
  each_pending _expire_one
}

# Earliest wake that serves EVERY pending: the minimum known reset epoch —
# but when any pending has no known reset, the fallback schedule must also
# fire, or unknown-reset sessions starve behind a far-future known one.
next_wake() {
  local known has_null now
  now=$(now_epoch)
  # Only FUTURE resets can shorten a wait. A reset that has already passed used
  # to come back as the minimum, and the slice loop below — which re-reads this
  # every slice and moves `wake` earlier whenever it can — latched onto that past
  # value and ended the sleep after one slice. That turns the back-off into a
  # billed probe every SLICE seconds instead of every 15-60 minutes, for as long
  # as such a pending lives. A pending whose reset has passed is not urgent; it
  # is waiting on the fallback schedule like any other.
  known=$(jq -r --argjson n "$now" \
    'select(.reset_epoch != null and .reset_epoch > $n) | .reset_epoch' \
    "$PENDING_DIR"/*.json 2>/dev/null | sort -n | head -1)
  # A PASSED reset arms the fallback exactly like an unknown one. It can never be
  # the wake time (above), so if it did not count as unscheduled here it was in
  # NEITHER set — parked behind any other pending's future reset, which for a
  # weekly one means days, within reach of expire_stale. That is the retry path's
  # normal state: a bounded retry re-queues a pending whose reset is now behind us.
  has_null=$(jq -r --argjson n "$now" \
    'select(.reset_epoch == null or .reset_epoch <= $n) | "y"' \
    "$PENDING_DIR"/*.json 2>/dev/null | head -1)
  if [ -n "$has_null" ]; then
    local fb=$((now + $(fallback_step)))
    if [ -n "$known" ] && [ "$known" -lt "$fb" ]; then printf '%s' "$known"; else printf '%s' "$fb"; fi
  else
    printf '%s' "${known:-}"
  fi
}

fallback_step() {
  local i=0 step=3600
  for s in $FALLBACK_STEPS; do
    step=$s
    [ "$i" -ge "$attempt" ] && break
    i=$((i + 1))
  done
  printf '%s' "$step"
}

probe() {
  # A still-limited probe exits nonzero and costs nothing; its output often
  # carries a fresh reset time. Prints that output; return code = result.
  "$CLAUDE" -p "Reply with exactly: OK" --model "$(cfg_probe_model)" --max-turns 1 2>&1
}

# Spend is counted per WINDOW, so it lives in ONE file that only a window credit
# clears. Keying it to the calendar date left a second refund nobody asked for:
# a window opening at 22:00 got its whole cap back at 00:05, still inside the
# same paid window, making the cap "per window OR per day, whichever comes first".
SPEND_FILE="$DAILY_DIR/count"
WINDOW_FILE="$DAILY_DIR/window"
# WHEN THIS BUDGET STARTED ACCUMULATING — deliberately not WINDOW_FILE, which
# holds the credited BOUNDARY. They are different quantities, and sharing one
# file made the staleness floor measure the wrong one: a boundary credited after
# the machine slept through the reset is hours old, so the budget was born
# already stale and the very next sleeper refunded the whole cap. That is the
# headline scenario — hit the limit overnight, wake to a reset that passed hours
# ago.
SPEND_AT_FILE="$DAILY_DIR/spend_started"
SPEND_TTL=$((5 * 3600 + 3600))  # the 5-hour window plus an hour of slack
CLOCK_SKEW=300                  # clock noise that is not a jump

# `read_int` and the config sanitiser both live in lib/common.sh now: the same
# torn-file and non-numeric-config hazards reach the chain counter and the chain
# cap, which are read in the hooks, and a guard that protects only the two files
# it was written for is not a guard on the class.
spend_count() { read_int "$SPEND_FILE"; }
resume_cap() { cfg_daily_cap; }
spend_increment() {
  # Stamp when this budget STARTED accumulating if nothing has yet, so a counter
  # that no credit ever clears is still recognisable as stale rather than
  # binding forever. See the staleness floor in window_credit.
  [ "$(read_int "$SPEND_AT_FILE")" -gt 0 ] || printf '%s' "$(now_epoch)" > "$SPEND_AT_FILE"
  echo $(( $(spend_count) + 1 )) > "$SPEND_FILE"
}

# The cap bounds resumes per unit of PAID capacity, and capacity renews at every
# limit reset — not at midnight. A spent budget must not strand a window that
# has already reopened: twelve resumes spent by early afternoon once left a
# reset two hours later entirely unused, with live sessions pending inside it.
# So the counter starts over the first time we can PROVE a new window began.
# Two proofs, both real:
#   - a reset time a pending RECORDED that is now behind us, and
#   - a probe that succeeds after one failed — the account was limited and is
#     not any more, which is the only evidence available at all when the limit
#     message carried no parseable reset time (a documented case).
# Never `now` on its own: that would credit on every probe and retire the cap.
window_credit() { # window_credit [OBSERVED_EPOCH]
  local now boundary seen observed="${1:-}"
  now=$(now_epoch)
  boundary=$(jq -r --argjson n "$now" \
    'select(.reset_epoch != null and .reset_epoch <= $n) | .reset_epoch' \
    "$PENDING_DIR"/*.json 2>/dev/null | sort -n | tail -1)
  if [ -n "$observed" ] && { [ -z "$boundary" ] || [ "$observed" -gt "$boundary" ]; }; then
    boundary="$observed"
  fi
  seen=$(read_int "$WINDOW_FILE")
  # A marker beyond NOW cannot describe a boundary that has already passed — a
  # forward clock jump wrote it. Distrust it, rather than blocking every credit
  # until it elapses for real (up to a week, for a weekly reset). The tolerance
  # keeps ordinary clock skew from counting as a jump. The trade is known and
  # bounded: a backward clock step also makes the boundary that wrote the marker
  # creditable once more, which costs one cap — far less than a week of lockout.
  [ "$seen" -gt $((now + CLOCK_SKEW)) ] && seen=0
  # Staleness floor. A credit is the counter's ONLY writer, so where no boundary
  # is ever provable the cap binds permanently and every later session is capped
  # and DELETED, silently and forever. That state is reachable: a limit message
  # carrying no reset time, plus a fresh sleeper whose first probe succeeds
  # because the small probe model was never limited, leaves neither proof
  # available. A budget nothing has cleared for longer than a window is stale,
  # not spent.
  #
  # It measures the SPEND stamp, never the credited boundary. Measuring the
  # boundary asks "how old is the window we last credited", which is hours old by
  # construction whenever the machine slept through a reset — the budget would be
  # born stale and refunded within seconds of being spent. Reading the spend stamp
  # is also why this survives a distrusted marker: zeroing `seen` above no longer
  # takes the floor's own guard with it.
  local started
  started=$(read_int "$SPEND_AT_FILE")
  if [ -z "$boundary" ] && [ "$started" -gt 0 ] && [ "$(spend_count)" -gt 0 ] &&
    [ $((now - started)) -gt "$SPEND_TTL" ]; then
    boundary="$now"
  fi
  [ -n "$boundary" ] || return 0
  [ "$boundary" -gt "$seen" ] || return 0
  printf '%s' "$boundary" > "$WINDOW_FILE"
  echo 0 > "$SPEND_FILE"
  : > "$SPEND_AT_FILE"   # the next spend starts a new accounting clock
}

resumed=0; failed=0; notified=0

resume_one() { # resume_one PENDING_FILE
  local f="$1" id cwd pmode prompt out ts retries notify_only caught_before caught_now
  local old_pid tpath bytes started now idle age reason slot child
  id=$(jq -r '.session_id // empty' "$f" 2>/dev/null)
  [ -n "$id" ] || { rm -f "$f"; return; }
  cwd=$(jq -r '.cwd // empty' "$f")
  pmode=$(jq -r '.permission_mode // "default"' "$f")
  # Sanitised like its siblings below: it is compared with -lt, which THROWS on
  # a torn or hand-edited pending and takes a branch nobody chose.
  retries=$(int_or "$(jq -r '.retries // 0' "$f")" 0)
  old_pid=$(int_or "$(jq -r '.pid // 0' "$f")" 0)
  # Remembered so the failure branch can tell "our run failed" from "the child
  # was caught by a fresh limit and re-queued while we ran". See there.
  # Sanitised, because the gate below does arithmetic with it: a torn or absent
  # field must read as 0 (idle unknown), not throw mid-decision.
  caught_before=$(int_or "$(jq -r '.caught_at // 0' "$f" 2>/dev/null)" 0)
  notify_only=$(jq -r '.notify_only // false' "$f")
  prompt=$(cfg_resume_prompt)

  if [ "$(cfg_mode)" = "notify" ] || [ "$notify_only" = "true" ]; then
    history_append reset_notified "$id" "$cwd"
    notify "carry-on: limit reset — session ${id:0:8} in $(basename "$cwd") is resumable (not auto-resumed)"
    notified=$((notified + 1))
    rm -f "$f"
    return
  fi

  # Permission posture on resume:
  #   bypassPermissions is never replayed into an unattended run.
  #   default-mode sessions resume per resume_default_mode — acceptEdits
  #   (useful, disclosed escalation) or skip (notify instead).
  case "$pmode" in
    bypassPermissions)
      # Replayed as-is by default — continuity of the posture the session was
      # already running. Set resume_bypass_mode=acceptEdits to downgrade to a
      # safer unattended run (which then can't run git/tests/CLI either).
      if [ "$(cfg_resume_bypass_mode)" = "acceptEdits" ]; then pmode="acceptEdits"; fi
      ;;
    default)
      if [ "$(cfg_resume_default_mode)" = "skip" ]; then
        history_append reset_notified "$id" "$cwd"
        notify "carry-on: limit reset — session ${id:0:8} ran in default mode; not auto-resumed (resume_default_mode=skip)"
        notified=$((notified + 1))
        rm -f "$f"
        return
      fi
      pmode="acceptEdits"
      ;;
  esac

  # Count it as failed, which is what makes the end-of-pass summary fire. Every
  # other terminal path tells the user something — expired, capped, notify-only,
  # retries exhausted — but a pending whose project directory was renamed or
  # deleted was dropped in silence, visible only in the history tail. Deleting a
  # finished worktree is ordinary; losing the queued session with it should not
  # be something you have to go looking for.
  if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
    failed=$((failed + 1))
    history_append resume_failed "$id" "$cwd"
    rm -f "$f"
    return
  fi

  # Cache-economy gate. Reviving a cold, fat session re-primes its whole
  # transcript as cache-creation tokens on the resumed session's first turn —
  # roughly ten fresh boots' worth for a session that has been sitting for
  # hours. Decided here, from the filesystem, because by the time the resumed
  # session could read a rule about it the tokens are already spent.
  #
  # A gated session is NOT a resume, so nothing about the chain moves: no
  # window handover is stamped and no chain step is spent. It never happened,
  # and the next real limit death sees exactly the chain state it would have.
  now=$(now_epoch)
  if tpath=$(transcript_path "$id"); then
    bytes=$(file_size "$tpath")
    started=$(transcript_started_at "$tpath")
    # Unknown reads as 0 — a missing stamp must drop its signal, never present
    # itself as "idle since the epoch" and gate a session on nothing.
    idle=0
    age=0
    [ "$caught_before" -gt 0 ] && idle=$((now - caught_before))
    [ "$started" -gt 0 ] && age=$((now - started))
    reason=$(gate_verdict "$bytes" "$idle" "$age")
    if [ -n "$reason" ]; then
      # Recheck the claim, exactly as the launch below does. Deciding not to
      # resume takes a multi-megabyte read and a dozen subprocesses, and
      # SessionStart retires a pending the instant the user brings that session
      # back by hand. A reattach landing in that gap would have us telling an
      # orchestrator to start a FRESH successor for a session the user is at
      # that moment typing in — and nothing ever cleans a chain-me signal up,
      # so the wrong advice would outlive the mistake by a month.
      [ -f "$f" ] || return
      write_chain_me "$id" "$cwd" "$reason" "$caught_before" "$(cat "$f")"
      history_append chain_me "$id" "$cwd"
      notify "carry-on: session ${id:0:8} not resumed — $reason. Chain-me signal written for a fresh successor in $(basename "$cwd"): $CHAINME_DIR/$id.json"
      notified=$((notified + 1))
      rm -f "$f"
      return
    fi
  fi

  if [ "$(spend_count)" -ge "$(resume_cap)" ]; then
    history_append daily_capped "$id" "$cwd"
    notify "carry-on: resume cap ($(resume_cap)) reached — session ${id:0:8} left resumable, not auto-resumed"
    notified=$((notified + 1))
    rm -f "$f"
    return
  fi

  # Space this wake from the last one. Five sessions freed by one reset used to
  # start their cold re-primes in the same instant, so the window's first
  # minutes went entirely on cache writes; now they land wake_gap apart. The
  # slot is reserved atomically, so a second sleeper — one can exist for a slice
  # after a stolen lock — can never claim the same instant. Claimed here, after
  # every path that decides NOT to resume, so a skipped session never spends a
  # slot the next one is then made to wait for.
  # Sliced against the wall clock, never one long sleep, for the same three
  # reasons the main loop is: a single `sleep` oversleeps a laptop suspend, a
  # trapped signal cannot interrupt a foreground command (so `carry-on cancel`
  # would hang for the whole remaining gap — up to wake_gap, by default three
  # minutes), and the pending file IS the claim, which SessionStart deletes the
  # moment the user brings the session back by hand. Rechecking every slice
  # means a session that came back mid-wait is dropped here rather than being
  # stamped as having been handed a fresh window.
  slot=$(stagger_claim)
  while [ "$(now_epoch)" -lt "$slot" ]; do
    [ -f "$f" ] || return
    sleep 1
  done

  ts=$(now_epoch)
  out="$LOGS_DIR/${id}-${ts}.log"
  # Stamp the window handover before the run: the gap from here to any next
  # limit death is how long the fresh window lasted — chain-decay reads it.
  chain_mark_resume "$id"
  # Badge signal: this session is resuming RIGHT NOW. The still-open (limit-
  # blocked) TUI shows "resuming…" live; cleared after the run either way.
  : > "$RESUMING_DIR/$id"
  # The pending file IS the claim on this session, and SessionStart deletes it
  # the moment the user brings the session back by hand. The queue snapshot is
  # rechecked before this callback runs, but the reads above still sit between
  # that check and the launch. Recheck after the marker exists, so the two
  # sides cannot both decide they own the session: whoever acts second sees the
  # other's flag. Resuming here would type into a session being used.
  if [ ! -f "$f" ]; then rm -f "$RESUMING_DIR/$id"; return; fi
  # stdin is CLOSED for the resume. each_pending feeds the loop from a process
  # substitution, so the rest of the pending queue is this shell's stdin — and
  # `claude -p` reads piped stdin, so the child consumed the remaining file paths
  # as user input and ended the pass after one session. The rest then waited for
  # a fresh billed probe each, and a resume holding bypass permissions was handed
  # absolute paths it never asked for. The CLI's own warning names this redirect.
  #
  # Launched in the background and waited on, purely so the child's pid is
  # knowable: a supervisor watching processes sees the session's ORIGINAL pid
  # die while the session lives on under this one, and reports a death that
  # never happened. resume_log_append records the mapping.
  (cd "$cwd" && exec "$CLAUDE" --resume "$id" -p "$prompt" --permission-mode "$pmode") \
    > "$out" 2>&1 < /dev/null &
  # Published for the TERM/INT handler, which cannot see a local. Assigned
  # straight from `$!` rather than through a local first: every statement
  # between the fork and this line is a window in which a TERM finds no pid to
  # kill and the resume escapes supervision entirely. See _terminate.
  RESUME_CHILD=$!; RESUME_ID="$id"
  child="$RESUME_CHILD"
  if wait "$child"; then
    # Settle FIRST, report second. The pending file is the claim, and a TERM
    # landing inside the bookkeeping below used to leave a session recorded as
    # resumed with its claim still on disk — so the next sleeper would resume an
    # already-continued transcript, two writers on one session. Clearing the
    # handler's pid in the same breath: the child is reaped, so there is nothing
    # left for it to kill, and the number would soon name some unrelated process.
    rm -f "$f"
    RESUME_CHILD=""; RESUME_ID=""
    # Any chain-me signal for this session is now WRONG: it told an orchestrator
    # to start a fresh successor, and the session itself just carried on. Left
    # behind it would sit in `carry-on status` for a month and put the badge
    # back to "chained · start fresh" the next time the user reattached.
    rm -f "$CHAINME_DIR/$id.json"
    resumed=$((resumed + 1)); history_append resumed "$id" "$cwd"
    resume_log_append "$id" "$old_pid" "$child"
    chain_increment "$id"; spend_increment
    # The continued transcript is now on disk. Flag the still-open TUI to
    # reattach and see it; SessionStart clears this when the user reattaches.
    : > "$RESUMED_DIR/$id"
  else
    RESUME_CHILD=""; RESUME_ID=""
    # Transient failures (crash, network, a per-model bucket the probe's
    # small model doesn't share) get one bounded retry on the fallback
    # schedule before the pending is declared lost.
    # A headless resume runs the user's hooks, so a child that died on a FRESH
    # usage limit has ALREADY re-queued this session through the catcher — with
    # the new window's reset time and a retry budget of its own. Our `retries`
    # was read before the run and describes a pending that no longer exists.
    # Acting on it bumps the new catch's counter, and once that budget looks
    # spent it DELETES the fresh pending outright: the headless run is gone, the
    # only record that the session is waiting on a reset is gone with it, and the
    # badge drops back to plain armed with nothing queued. The session's progress
    # is on disk in its transcript, but nothing will ever go back for it.
    #
    # This is the ordinary path for a long chain, not a corner: the whole point
    # of a resume is to run until the window closes again.
    caught_now=$(int_or "$(jq -r '.caught_at // 0' "$f" 2>/dev/null)" 0)
    if [ ! -f "$f" ]; then
      : # cancelled mid-run; nothing of ours left to settle
    elif [ "$caught_now" != "$caught_before" ]; then
      history_append resume_requeued "$id" "$cwd"
    elif grep -qE '^Error: Session .* is currently running as a background agent' "$out" 2>/dev/null; then
      # A session the CLI is running as a background agent refuses `--resume`
      # outright: it is already attached to a live process. That is a permanent
      # answer, not a transient one, so the retry ladder below just spends the
      # fallback schedule — a quarter of an hour of waiting — to be told the same
      # thing twice. The CLI suggests --fork-session; we deliberately do not,
      # because a fork is a COPY: the resume would succeed into a transcript the
      # user is not looking at, and the session they are waiting on would sit
      # untouched while carry-on reported it resumed. Retire the claim and say
      # why; the session itself is intact and reachable with `claude agents`.
      #
      # Matched on the CLI's error LINE, not on the phrase. This log holds the
      # resumed session's own output, and a session can discuss background agents
      # — a bare phrase match would retire a pending that deserved its retry.
      notified=$((notified + 1))
      history_append resume_unattachable "$id" "$cwd"
      notify "carry-on: session ${id:0:8} runs as a background agent — cannot be resumed; attach it with 'claude agents'"
      rm -f "$f"
    elif [ "$retries" -lt 1 ]; then
      # Keep reset_epoch. It is this pending's only record of which window it
      # belongs to, and a retry that erases it can never have the cap credited
      # on its behalf — it gets capped and DELETED on the retry pass, so the
      # one bounded retry silently becomes no retry. Timing is unaffected: a
      # reset already in the past sends next_wake to the fallback schedule.
      jq -c '.retries += 1' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      history_append resume_retry "$id" "$cwd"
    else
      failed=$((failed + 1)); history_append resume_failed "$id" "$cwd"
      chain_increment "$id"
      rm -f "$f"
    fi
  fi
  rm -f "$RESUMING_DIR/$id"
}

while true; do
  expire_stale
  pending_exists || { finish || continue; }

  wake=$(next_wake)
  now=$(now_epoch)
  if [ -z "$wake" ] || [ "$wake" -le "$now" ]; then
    wake=$((now + $(fallback_step)))
  fi

  # Sleep in slices against the wall clock — survives laptop sleep, where a
  # single long `sleep` would miss the reset. Each slice re-reads the wake
  # time: a new pending with an EARLIER reset must shorten the wait, or the
  # 5-hour window starves behind a weekly one.
  while [ "$(now_epoch)" -lt "$wake" ]; do
    pending_exists || break
    sleep "$SLICE"
    nw=$(next_wake)
    [ -n "$nw" ] && [ "$nw" -lt "$wake" ] && wake=$nw
  done
  pending_exists || { finish || continue; }

  if probe_out=$(probe); then
    # A probe that succeeds after one failed IS a window boundary, observed
    # first-hand: the account was limited a moment ago and is not now. It is
    # the only proof available when the limit message named no reset time.
    if [ "$limited" -eq 1 ]; then window_credit "$(now_epoch)"; else window_credit; fi
    limited=0
    resumed=0; failed=0; notified=0
    each_pending resume_one
    total=$((resumed + failed + notified))
    if [ "$total" -gt 0 ] && { [ "$resumed" -gt 0 ] || [ "$failed" -gt 0 ]; }; then
      msg="carry-on: resumed $resumed session(s)"
      [ "$failed" -gt 0 ] && msg="$msg, $failed failed"
      notify "$msg — carry-on status"
    fi
    attempt=0   # a fresh wait generation starts its schedule from the top
    continue    # retries or brand-new pendings may still be queued
  fi

  # Probe still limited: reschedule, preferring a reset time the probe just
  # told us — but never move an already-earlier pending later.
  attempt=$((attempt + 1))
  # Only a LIMIT arms the observed-boundary path. A probe exits nonzero for a
  # dropped connection or a 500 just as readily, and treating that as "we were
  # limited" would let one network blip refund the whole cap — twelve more
  # resumes per transient error, on a probe series that runs for up to max_wait.
  looks_limited "$probe_out" && limited=1
  fresh=$(parse_reset_epoch "$probe_out")
  if [ -n "$fresh" ]; then
    _refresh_one() {
      jq -c --argjson r "$fresh" \
        'if .reset_epoch == null or .reset_epoch > $r then .reset_epoch = $r else . end' \
        "$1" > "$1.tmp" && mv "$1.tmp" "$1"
    }
    each_pending _refresh_one
  fi
done
