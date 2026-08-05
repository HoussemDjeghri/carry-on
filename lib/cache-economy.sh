#!/bin/bash
# Cache economy: stop a wake from costing more than the work it resumes.
#
# Resuming a session re-primes its ENTIRE transcript as cache-creation tokens on
# the resumed session's FIRST turn — the prompt cache is gone once a session has
# been idle past its ~1h TTL, which every limit wait is. A fleet that woke six
# cold sessions at one reset burned 4.6M cache-write tokens before doing any
# work, and the worst single session wrote 1.1M in two minutes. A fresh `claude`
# boot costs 40–90k, so reviving a cold, fat session is ~10x the price of
# starting a new one in the same directory.
#
# Two brakes, both decided from the FILESYSTEM ALONE, before anything talks to
# the API — that timing is the whole design. The re-prime happens on the resumed
# session's first turn, so a rule the session reads *after* waking arrives after
# the bill. Nothing here spends a token: it stats a file, reads the wake record,
# and decides.
#
#   stagger_claim — space the wakes at one reset so they are not a herd
#   gate_verdict  — a transcript too fat AND too cold is not resumed at all
#   write_chain_me — the signal that asks an orchestrator for a fresh successor
#
# Sourced by the sleeper (all three) and the catcher (chain-me, for mode=chain).
# Needs lib/common.sh (paths, config) sourced first; pulls in parse-reset.sh
# itself for ISO timestamps.
# shellcheck source=parse-reset.sh
. "$(dirname "${BASH_SOURCE[0]}")/parse-reset.sh"

# Where Claude Code keeps a session's transcript. Projects are filed under a
# munged cwd, so globbing for the session id is both exact and free of any
# assumption about the munging rules — and it keeps working for a project
# directory that was renamed after the session started.
transcript_path() { # transcript_path SESSION_ID
  local f
  for f in "$CLAUDE_CFG_DIR"/projects/*/"$1".jsonl; do
    [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# `wc -c`, not `stat`: one spelling on both platforms. The GNU/BSD stat pair
# needs a probe order to be safe, because `-f` means "filesystem status" to GNU
# stat and would put a whole report on stdout before any fallback ran.
file_size() { # file_size PATH  (0 when it cannot be read)
  int_or "$(wc -c < "$1" 2>/dev/null | tr -d ' ')" 0
}

# When the session began, from the first timestamped line of its transcript.
# The opening lines are metadata (mode, permission mode, session wiring) and
# carry no timestamp, so this reads a bounded head rather than line 1 — and a
# transcript that yields none leaves the age UNKNOWN (0), which drops the age
# signal from the gate instead of inventing a value for it.
transcript_started_at() { # transcript_started_at PATH
  local iso epoch
  iso=$(head -50 "$1" 2>/dev/null | jq -r 'select(.timestamp != null) | .timestamp' 2>/dev/null | head -1)
  [ -n "$iso" ] || { printf 0; return 0; }
  epoch=$(_epoch_iso "$iso")
  int_or "$epoch" 0
}

# Is resuming this session worth what it costs? Prints nothing when it is (the
# caller resumes); otherwise prints the reason, naming every threshold that
# tripped and its value, for the log and the chain-me signal.
#
# Size alone never gates: a fat transcript that is still warm is exactly the
# case carry-on exists for — a session resumed five minutes after the reset
# re-primes almost nothing and keeps all its context. Size has to be paired with
# evidence the cache is cold: idle past its TTL, or an age no single window
# survives. Conservative by construction, and a lean session is untouchable.
gate_verdict() { # gate_verdict TRANSCRIPT_BYTES IDLE_SECONDS AGE_SECONDS
  local bytes="$1" idle="$2" age="$3" max_bytes max_idle max_age cold=""
  max_bytes=$(cfg_gate_bytes)
  max_idle=$(cfg_gate_idle)
  max_age=$(cfg_gate_age)

  [ "$max_bytes" -gt 0 ] || return 0            # gate disabled outright
  [ "$bytes" -gt "$max_bytes" ] || return 0

  if [ "$max_idle" -gt 0 ] && [ "$idle" -gt "$max_idle" ]; then
    cold="idle ${idle}s > ${max_idle}s"
  fi
  if [ "$max_age" -gt 0 ] && [ "$age" -gt "$max_age" ]; then
    cold="${cold:+$cold, }age ${age}s > ${max_age}s"
  fi
  [ -n "$cold" ] || return 0                    # fat but warm — resume it

  printf 'transcript %sB > %sB, %s' "$bytes" "$max_bytes" "$cold"
}

# The chain-me signal: this session will NOT be resumed, and a fresh successor
# in the same cwd should take the work over. Written for an external
# orchestrator (a fleet watchdog, a conductor) that watches the directory —
# carry-on itself never reads these back. Atomic, so a reader polling the
# directory can never see half a file.
write_chain_me() { # write_chain_me SESSION_ID CWD REASON CAUGHT_AT WAKE_JSON
  ensure_dirs
  local tmp="$CHAINME_DIR/.$1.tmp.$$"
  jq -cn --arg id "$1" --arg cwd "$2" --arg reason "$3" \
    --argjson caught "$(int_or "${4:-}" 0)" \
    --argjson wake "${5:-null}" \
    --argjson ts "$(now_epoch)" \
    '{session_id: $id, cwd: $cwd, reason: $reason, caught_at: $caught,
      written_at: $ts, wake: $wake}' \
    > "$tmp" && mv "$tmp" "$CHAINME_DIR/$1.json"
}

# Reserve this process's place in the wake queue; prints the epoch at which it
# may launch. The first claimant gets NOW, each later one lands a gap further
# out — so a reset lifting on six pendings is six spaced wakes, not six
# simultaneous cold re-primes racing for the same fresh window.
#
# The reservation is a read-modify-write on a file that independent processes
# share: hooks and sleepers are separate processes, and a stolen lock can leave
# two sleepers alive for a slice. Doing it under a lock is what stops both of
# them concluding "I'm first". The lock covers the write only, never the wait —
# each claimant then sleeps on its OWN reserved time.
stagger_claim() {
  local gap now next slot
  gap=$(cfg_wake_gap)
  now=$(now_epoch)
  if [ "$gap" -le 0 ]; then printf '%s' "$now"; return 0; fi

  ensure_dirs
  # Could not take the lock: launch now, unstaggered, and leave the shared file
  # ALONE. Racing the read-modify-write unprotected is worse than losing the
  # spacing — every giver-up reads the same value and writes the same slot back,
  # so a queue of them collapses onto one instant AND leaves the file describing
  # a reservation none of them respected, which mis-staggers the claimants that
  # come after. Losing the gap for one wake is a missed optimisation; corrupting
  # the queue is the herd, restored.
  _stagger_lock || { printf '%s' "$now"; return 0; }

  next=$(read_int "$STAGGER_FILE")
  # A reservation further out than a day was written by a forward clock jump,
  # not by a queue: trust it and every wake parks for a day. Ordinary spacing
  # is minutes.
  if [ "$next" -le "$now" ] || [ "$next" -gt $((now + 86400)) ]; then
    slot="$now"
  else
    slot="$next"
  fi
  printf '%s' $((slot + gap)) > "$STAGGER_FILE.tmp.$$" &&
    mv "$STAGGER_FILE.tmp.$$" "$STAGGER_FILE"
  rm -f "$STAGGER_LOCK"

  printf '%s' "$slot"
}

# Mutual exclusion for the reservation above.
#
# The lock is a FILE created under `noclobber`, i.e. with O_EXCL, holding the
# claimant's pid — created and owned in one atomic step. A mkdir-then-write
# lock cannot do that: between the mkdir and the write it is an ownerless lock,
# and a waiter that looks in exactly then sees no owner and steals from a
# holder that is very much alive.
#
# Only a holder that is GONE is stolen from. "Slow" and "dead" are different
# answers, and stealing from a slow holder hands two claimants the same instant
# — precisely the herd this feature exists to remove. Six processes forking at
# once on a loaded machine is the normal case here, not the corner. A lock past
# a minute goes regardless: this critical section is two reads and a write, so
# a minute means the holder died and its pid has since been recycled onto some
# unrelated live process.
#
# And it gives up rather than spinning forever. This lock guards an
# OPTIMISATION; a resume that never happens because a lock file could not be
# taken would be far worse than two sessions sharing one wake slot. Returns 1
# when it gave up, and the caller proceeds unserialised.
_stagger_lock() {
  local i=0 holder
  until (set -o noclobber; printf '%s' "$$" > "$STAGGER_LOCK") 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 100 ] && return 1
    if [ $((i % 50)) -eq 0 ]; then
      holder=$(cat "$STAGGER_LOCK" 2>/dev/null || true)
      if [ -z "$holder" ] || ! kill -0 "$holder" 2>/dev/null ||
        [ -n "$(find "$STAGGER_LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        rm -rf "$STAGGER_LOCK"   # -rf: an 0.2.x-era lock could be a directory
      fi
    fi
    sleep 0.1
  done
  return 0
}
