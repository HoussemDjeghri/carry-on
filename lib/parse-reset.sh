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

_epoch_iso() { # _epoch_iso "YYYY-MM-DDTHH:MM[:SS]"
  local iso="$1"
  date -j -f "%Y-%m-%dT%H:%M:%S" "${iso:0:19}" +%s 2>/dev/null \
    || date -j -f "%Y-%m-%dT%H:%M" "${iso:0:16}" +%s 2>/dev/null \
    || date -d "$iso" +%s 2>/dev/null
}

parse_reset_epoch() { # parse_reset_epoch TEXT
  local text="$1" lower h m ampm epoch now
  lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
  now=$(date +%s)

  # ISO timestamp anywhere in the text.
  local iso
  iso=$(printf '%s' "$text" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?' | head -1)
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
  ampm=$(printf '%s' "$match" | grep -oE '(am|pm)$' || true)

  case "$ampm" in
    pm) [ "$h" -lt 12 ] && h=$((h + 12)) ;;
    am) [ "$h" -eq 12 ] && h=0 ;;
    *)  # No am/pm and a 1-12 hour is ambiguous; 13-23 is unambiguous 24h.
        # For ambiguous hours, pick the NEXT occurrence of either reading —
        # conservative: treat as given, next-occurrence rule below fixes past times.
        : ;;
  esac

  epoch=$(_epoch_today_at "$(printf '%02d' "$h")" "$m")
  [ -z "$epoch" ] && return 0
  # A clock time already behind us means tomorrow's occurrence.
  [ "$epoch" -le "$now" ] && epoch=$((epoch + 86400))
  printf '%s' "$epoch"
}
