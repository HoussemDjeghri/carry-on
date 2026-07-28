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
trap 'rm -rf "$LOCK_DIR"' TERM INT

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
  known=$(jq -r 'select(.reset_epoch != null) | .reset_epoch' "$PENDING_DIR"/*.json 2>/dev/null | sort -n | head -1)
  has_null=$(jq -r 'select(.reset_epoch == null) | "y"' "$PENDING_DIR"/*.json 2>/dev/null | head -1)
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

# Every number read back from disk is untrusted: these files are documented as
# user-readable, and a kill or a reboot can leave one truncated mid-write. A
# non-integer counts as zero rather than making `[` throw "integer expression
# expected" and take a branch nobody chose — an empty window marker used to
# disable crediting permanently and silently that way.
read_int() { # read_int FILE
  local n
  n=$(cat "$1" 2>/dev/null || echo 0)
  case "$n" in "" | *[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

spend_count() { read_int "$SPEND_FILE"; }
spend_increment() { echo $(( $(spend_count) + 1 )) > "$SPEND_FILE"; }

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
  [ -n "$boundary" ] || return 0
  seen=$(read_int "$WINDOW_FILE")
  # A marker in the FUTURE cannot describe a boundary that has already passed —
  # a forward clock jump wrote it. Distrust it, rather than blocking every
  # credit until it elapses for real (up to a week, for a weekly reset).
  [ "$seen" -gt "$now" ] && seen=0
  [ "$boundary" -gt "$seen" ] || return 0
  printf '%s' "$boundary" > "$WINDOW_FILE"
  echo 0 > "$SPEND_FILE"
}

resumed=0; failed=0; notified=0

resume_one() { # resume_one PENDING_FILE
  local f="$1" id cwd pmode prompt out ts retries notify_only
  id=$(jq -r '.session_id // empty' "$f" 2>/dev/null)
  [ -n "$id" ] || { rm -f "$f"; return; }
  cwd=$(jq -r '.cwd // empty' "$f")
  pmode=$(jq -r '.permission_mode // "default"' "$f")
  retries=$(jq -r '.retries // 0' "$f")
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

  if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
    history_append resume_failed "$id" "$cwd"
    rm -f "$f"
    return
  fi

  if [ "$(spend_count)" -ge "$(cfg_daily_cap)" ]; then
    history_append daily_capped "$id" "$cwd"
    notify "carry-on: resume cap ($(cfg_daily_cap)) reached — session ${id:0:8} left resumable, not auto-resumed"
    notified=$((notified + 1))
    rm -f "$f"
    return
  fi

  ts=$(now_epoch)
  out="$LOGS_DIR/${id}-${ts}.log"
  # Stamp the window handover before the run: the gap from here to any next
  # limit death is how long the fresh window lasted — chain-decay reads it.
  chain_mark_resume "$id"
  # Badge signal: this session is resuming RIGHT NOW. The still-open (limit-
  # blocked) TUI shows "resuming…" live; cleared after the run either way.
  : > "$RESUMING_DIR/$id"
  if (cd "$cwd" && "$CLAUDE" --resume "$id" -p "$prompt" --permission-mode "$pmode") > "$out" 2>&1; then
    resumed=$((resumed + 1)); history_append resumed "$id" "$cwd"
    chain_increment "$id"; spend_increment
    # The continued transcript is now on disk. Flag the still-open TUI to
    # reattach and see it; SessionStart clears this when the user reattaches.
    : > "$RESUMED_DIR/$id"
    rm -f "$f"
  else
    # Transient failures (crash, network, a per-model bucket the probe's
    # small model doesn't share) get one bounded retry on the fallback
    # schedule before the pending is declared lost.
    if [ "$retries" -lt 1 ]; then
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
  limited=1
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
