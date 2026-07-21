#!/bin/bash
# The waker. Spawned detached by the catcher; the only long-lived carry-on
# process, and it lives only while a wait is pending. Sleeps to the earliest
# known reset, probe-confirms the window actually lifted (a limited probe
# fails free), then resumes every pending session and exits.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=parse-reset.sh
. "$ROOT/lib/parse-reset.sh"

ensure_dirs
mkdir "$LOCK_DIR" 2>/dev/null || true
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

SLICE="${CARRY_ON_SLICE:-60}"
# Fallback wait steps (seconds) when no reset time is known: 15m, 30m, then hourly.
FALLBACK_STEPS="${CARRY_ON_FALLBACK_STEPS:-900 1800 3600}"
attempt=0

pending_files() { ls "$PENDING_DIR"/*.json 2>/dev/null; }

expire_stale() {
  local max_wait now f caught
  max_wait=$(cfg_max_wait)
  now=$(now_epoch)
  for f in $(pending_files); do
    caught=$(jq -r '.caught_at' "$f")
    if [ $((now - caught)) -gt "$max_wait" ]; then
      local id; id=$(jq -r '.session_id' "$f")
      history_append expired "$id" "$(jq -r '.cwd' "$f")"
      notify "carry-on: session ${id:0:8} waited past the cap without a reset — expired. carry-on status"
      rm -f "$f"
    fi
  done
}

next_wake() {
  # Earliest known reset among pending files; empty when none carries one.
  jq -r 'select(.reset_epoch != null) | .reset_epoch' "$PENDING_DIR"/*.json 2>/dev/null | sort -n | head -1
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
  # carries a fresh reset time. Prints that output; return code = probe result.
  "$(claude_bin)" -p "Reply with exactly: OK" --model "$(cfg_probe_model)" --max-turns 1 2>&1
}

resume_all() {
  local f id cwd pmode prompt out rc ts
  prompt=$(cfg_resume_prompt)
  local resumed=0 failed=0
  for f in $(ls -tr "$PENDING_DIR"/*.json 2>/dev/null); do
    id=$(jq -r '.session_id' "$f")
    cwd=$(jq -r '.cwd' "$f")
    pmode=$(jq -r '.permission_mode' "$f")
    # bypassPermissions is never replayed into an unattended run.
    [ "$pmode" = "bypassPermissions" ] && pmode="acceptEdits"
    [ "$pmode" = "default" ] && pmode="acceptEdits"
    ts=$(now_epoch)
    if [ "$(cfg_mode)" = "notify" ]; then
      history_append reset_notified "$id" "$cwd"
      notify "carry-on: limit reset — session ${id:0:8} in $(basename "$cwd") is resumable (mode=notify, not auto-resumed)"
      rm -f "$f"
      continue
    fi
    out="$LOGS_DIR/${id}-${ts}.log"
    if (cd "$cwd" 2>/dev/null && "$(claude_bin)" --resume "$id" -p "$prompt" --permission-mode "$pmode") > "$out" 2>&1; then
      rc=0; resumed=$((resumed + 1)); history_append resumed "$id" "$cwd"
    else
      rc=$?; failed=$((failed + 1)); history_append resume_failed "$id" "$cwd"
    fi
    chain_increment "$id"
    rm -f "$f"
  done
  if [ "$resumed" -gt 0 ] || [ "$failed" -gt 0 ]; then
    notify "carry-on: resumed $resumed session(s)$([ "$failed" -gt 0 ] && printf ', %s failed' "$failed") — carry-on status"
  fi
}

while true; do
  expire_stale
  [ -z "$(pending_files)" ] && exit 0

  wake=$(next_wake)
  now=$(now_epoch)
  if [ -z "$wake" ] || [ "$wake" -le "$now" ]; then
    wake=$((now + $(fallback_step)))
  fi

  # Sleep in slices against the wall clock — survives laptop sleep, where a
  # single long `sleep` would oversleep or undersleep the reset.
  while [ "$(now_epoch)" -lt "$wake" ]; do
    [ -z "$(pending_files)" ] && exit 0   # everything cancelled mid-wait
    sleep "$SLICE"
  done

  probe_out=$(probe) && {
    resume_all
    continue   # new pendings may have arrived during resumes
  }

  # Probe still limited: reschedule, preferring a reset time the probe itself
  # just told us.
  attempt=$((attempt + 1))
  fresh=$(parse_reset_epoch "$probe_out")
  if [ -n "$fresh" ]; then
    for f in $(pending_files); do
      jq -c --argjson r "$fresh" '.reset_epoch = $r' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done
  else
    for f in $(pending_files); do
      jq -c '.reset_epoch = null' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done
  fi
done
