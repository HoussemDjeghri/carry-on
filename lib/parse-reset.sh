#!/bin/bash
# Reset-time extraction from usage-limit error text.
#
# parse_reset_epoch "TEXT" -> prints the next epoch matching the stated
# reset time, or nothing when the text carries no recognizable time (some
# limit messages have none — callers must fall back to a retry schedule,
# never guess).
#
# Recognized shapes, case-insensitive, first match wins:
#   "resets 3:45pm" · "resets at 11pm" · "will reset at 15:00" ·
#   "resets 3 pm" · ISO "2026-07-21T15:00" (with optional :SS and zone)
# A clock time with no date means "the next time that clock reads H:MM" —
# today if still ahead, else tomorrow.

# Portable "epoch for today at H:M" (BSD date on macOS, GNU elsewhere).
_epoch_today_at() { # _epoch_today_at HOUR MINUTE
  local d
  d=$(date +%Y-%m-%d)
  date -j -f "%Y-%m-%d %H:%M" "$d $1:$2" +%s 2>/dev/null \
    || date -d "$d $1:$2" +%s 2>/dev/null
}

_epoch_iso() { # _epoch_iso "YYYY-MM-DDTHH:MM[:SS][Z|±HH[:]MM]"
  local iso="$1" zone="" base epoch offset sign zh zm
  zone=$(printf '%s' "$iso" | grep -oE '(Z|[+-][0-9]{2}:?[0-9]{2})$' || true)
  base=${iso%"$zone"}
  [ ${#base} -eq 16 ] && base="$base:00"
  if [ -n "$zone" ]; then
    # Zoned timestamp: interpret the clock fields as UTC, then shift by the
    # stated offset. Dropping the zone would mis-sleep by the UTC offset.
    epoch=$(date -ju -f "%Y-%m-%dT%H:%M:%S" "${base:0:19}" +%s 2>/dev/null \
      || date -ud "${base:0:19}" +%s 2>/dev/null)
    [ -z "$epoch" ] && return 0
    if [ "$zone" != "Z" ]; then
      sign=${zone:0:1}; zh=$((10#${zone:1:2})); zm=$(printf '%s' "$zone" | grep -oE '[0-9]{2}$')
      offset=$(( zh * 3600 + 10#$zm * 60 ))
      if [ "$sign" = "+" ]; then epoch=$((epoch - offset)); else epoch=$((epoch + offset)); fi
    fi
    printf '%s' "$epoch"
    return 0
  fi
  date -j -f "%Y-%m-%dT%H:%M:%S" "${base:0:19}" +%s 2>/dev/null \
    || date -d "$base" +%s 2>/dev/null
}

parse_reset_epoch() { # parse_reset_epoch TEXT
  local text="$1" lower h m ampm epoch now
  lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
  now=$(date +%s)

  # ISO timestamp anywhere in the text (zone captured — it matters).
  local iso
  iso=$(printf '%s' "$text" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?(Z|[+-][0-9]{2}:?[0-9]{2})?' | head -1)
  if [ -n "$iso" ]; then
    epoch=$(_epoch_iso "$iso")
    [ -n "$epoch" ] && { printf '%s' "$epoch"; return 0; }
  fi

  # "reset(s)/will reset [at] H[:MM] [am|pm]"  or 24h "at HH:MM".
  local match
  match=$(printf '%s' "$lower" | grep -oE 'reset[s]?( at)? [0-9]{1,2}(:[0-9]{2})? ?(am|pm)?' | head -1)
  [ -z "$match" ] && return 0

  h=$(printf '%s' "$match" | grep -oE '[0-9]{1,2}(:[0-9]{2})?' | head -1 | cut -d: -f1)
  m=$(printf '%s' "$match" | grep -oE ':[0-9]{2}' | head -1 | tr -d :)
  m=${m:-00}
  # Force base 10: "09" would otherwise be read as invalid octal by both
  # $(( )) and printf %02d, corrupting the hour or aborting the parse.
  h=$((10#$h)); m=$((10#$m))
  ampm=$(printf '%s' "$match" | grep -oE '(am|pm)$' || true)

  case "$ampm" in
    pm) [ "$h" -lt 12 ] && h=$((h + 12)) ;;
    am) [ "$h" -eq 12 ] && h=0 ;;
    *)  # No am/pm and a 1-12 hour is ambiguous; 13-23 is unambiguous 24h.
        # For ambiguous hours, pick the NEXT occurrence of either reading —
        # conservative: treat as given, next-occurrence rule below fixes past times.
        : ;;
  esac

  epoch=$(_epoch_today_at "$(printf '%02d' "$h")" "$(printf '%02d' "$m")")
  [ -z "$epoch" ] && return 0
  if [ "$epoch" -le "$now" ]; then
    if [ $((now - epoch)) -le 300 ]; then
      # The stated minute just passed (hooks fire seconds late): the reset
      # is imminent, not tomorrow — a +86400 here would oversleep a day.
      epoch=$((now + 60))
    else
      epoch=$((epoch + 86400))
    fi
  fi
  printf '%s' "$epoch"
}

# Does this text look like a USAGE LIMIT, as opposed to any other failure?
#
# A probe's exit status alone cannot answer that: `claude -p` exits nonzero for a
# dropped connection, a 500, or a bad flag just as readily as for a limit. The
# waker treats "was limited, now is not" as proof a new window opened, so without
# this discriminator one network blip refunds the whole resume budget — the cap
# becomes "N per transient error" instead of "N per window".
#
# A reset time is the strongest signal, but plenty of real limit messages carry
# none ("Run /usage-credits to continue"), so the wording is checked too.
looks_limited() { # looks_limited TEXT
  [ -n "$(parse_reset_epoch "$1")" ] && return 0
  printf '%s' "$1" | grep -qiE 'usage limit|rate limit|limit reached|reached your [a-z ]*limit|hit your [a-z ]*limit|usage-credits'
}
