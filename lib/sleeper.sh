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

SLICE="${CARRY_ON_SLICE:-60}"
# Fallback wait steps (seconds) when no reset time is known: 15m, 30m, then hourly.
FALLBACK_STEPS="${CARRY_ON_FALLBACK_STEPS:-900 1800 3600}"
attempt=0
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

each_pending() { # each_pending CALLBACK  (callback FILE; skips vanished files)
  local f
  for f in "$PENDING_DIR"/*.json; do
    [ -f "$f" ] || continue
    "$1" "$f"
  done
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

daily_count() { cat "$DAILY_DIR/$(date +%Y-%m-%d)" 2>/dev/null || echo 0; }
daily_increment() { echo $(( $(daily_count) + 1 )) > "$DAILY_DIR/$(date +%Y-%m-%d)"; }

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
    bypassPermissions) pmode="acceptEdits" ;;
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

  if [ "$(daily_count)" -ge "$(cfg_daily_cap)" ]; then
    history_append daily_capped "$id" "$cwd"
    notify "carry-on: daily resume cap ($(cfg_daily_cap)) reached — session ${id:0:8} left resumable, not auto-resumed"
    notified=$((notified + 1))
    rm -f "$f"
    return
  fi

  ts=$(now_epoch)
  out="$LOGS_DIR/${id}-${ts}.log"
  # Stamp the window handover before the run: the gap from here to any next
  # limit death is how long the fresh window lasted — chain-decay reads it.
  chain_mark_resume "$id"
  if (cd "$cwd" && "$CLAUDE" --resume "$id" -p "$prompt" --permission-mode "$pmode") > "$out" 2>&1; then
    resumed=$((resumed + 1)); history_append resumed "$id" "$cwd"
    chain_increment "$id"; daily_increment
    rm -f "$f"
  else
    # Transient failures (crash, network, a per-model bucket the probe's
    # small model doesn't share) get one bounded retry on the fallback
    # schedule before the pending is declared lost.
    if [ "$retries" -lt 1 ]; then
      jq -c '.retries += 1 | .reset_epoch = null' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      history_append resume_retry "$id" "$cwd"
    else
      failed=$((failed + 1)); history_append resume_failed "$id" "$cwd"
      chain_increment "$id"
      rm -f "$f"
    fi
  fi
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
