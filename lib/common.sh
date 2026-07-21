#!/bin/bash
# Shared state, config, and helpers for carry-on. Sourced by hooks, the
# sleeper, and the CLI — keep it dependency-free beyond bash + jq.

CARRY_ON_HOME="${CARRY_ON_HOME:-$HOME/.claude/carry-on}"
PENDING_DIR="$CARRY_ON_HOME/pending"
LOGS_DIR="$CARRY_ON_HOME/logs"
CHAINS_DIR="$CARRY_ON_HOME/chains"
LASTSEEN_DIR="$CARRY_ON_HOME/lastseen"
DAILY_DIR="$CARRY_ON_HOME/daily"
HISTORY_FILE="$CARRY_ON_HOME/history.jsonl"
CONFIG_FILE="$CARRY_ON_HOME/config"
# shellcheck disable=SC2034  # consumed by the scripts that source this file
LOCK_DIR="$CARRY_ON_HOME/sleeper.lock"

ensure_dirs() {
  mkdir -p "$PENDING_DIR" "$LOGS_DIR" "$CHAINS_DIR" "$LASTSEEN_DIR" "$DAILY_DIR"
}

pending_exists() {
  local f
  for f in "$PENDING_DIR"/*.json; do [ -e "$f" ] && return 0; done
  return 1
}

# Ensure exactly one sleeper is running when pendings exist. Callable from
# the catcher, the SessionStart reporter, and the CLI — the reporter/CLI
# calls are what recover pendings stranded by a reboot or a crashed sleeper.
# Portable detach: setsid where it exists (Linux); plain nohup elsewhere
# (macOS ships no setsid — a hard-learned platform fact).
ensure_sleeper() { # ensure_sleeper PLUGIN_ROOT
  local root="$1"
  pending_exists || return 0

  _spawn() {
    if command -v setsid >/dev/null 2>&1; then
      setsid nohup "$root/lib/sleeper.sh" >> "$CARRY_ON_HOME/sleeper.log" 2>&1 &
    else
      nohup "$root/lib/sleeper.sh" >> "$CARRY_ON_HOME/sleeper.log" 2>&1 &
    fi
  }

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    now_epoch > "$LOCK_DIR/spawned_at"
    _spawn
    return 0
  fi

  # Lock held. Alive sleeper (fresh pid) → nothing to do.
  local pid
  pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  # Stale: dead pid, or no pid ever appeared (spawn failed) and the lock is
  # old enough that a healthy sleeper would have written one. Steal
  # atomically via mv so two concurrent stealers can't both proceed.
  local spawned
  spawned=$(cat "$LOCK_DIR/spawned_at" 2>/dev/null || echo 0)
  if [ -n "$pid" ] || [ $(( $(now_epoch) - spawned )) -gt 60 ]; then
    if mv "$LOCK_DIR" "$LOCK_DIR.stale.$$" 2>/dev/null; then
      rm -rf "$LOCK_DIR.stale.$$"
      if mkdir "$LOCK_DIR" 2>/dev/null; then
        now_epoch > "$LOCK_DIR/spawned_at"
        _spawn
      fi
    fi
  fi
}

# Config is KEY=VALUE lines, read with grep — never sourced, so a config
# file can't execute code.
config_get() { # config_get KEY DEFAULT
  local val
  val=$(grep -E "^$1=" "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
  printf '%s' "${val:-$2}"
}

config_set() { # config_set KEY VALUE
  ensure_dirs
  touch "$CONFIG_FILE"
  local value="${2//$'\n'/ }"   # a newline in a value must not become a config line
  local tmp="$CONFIG_FILE.tmp.$$"
  grep -vE "^$1=" "$CONFIG_FILE" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$1" "$value" >> "$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

cfg_enabled()       { config_get enabled true; }
cfg_mode()          { config_get mode resume; }
cfg_max_chain()     { config_get max_chain 3; }
cfg_max_wait()      { config_get max_wait 604800; }   # 7 days
cfg_deny()          { config_get deny ""; }
cfg_probe_model()   { config_get probe_model haiku; }
cfg_daily_cap()     { config_get daily_cap 12; }
# How to resume a session that ran in default (prompt-per-edit) mode:
# acceptEdits resumes it with edits auto-approved (useful, but an unattended
# escalation the README discloses); skip degrades it to notify-only.
cfg_resume_default_mode() { config_get resume_default_mode acceptEdits; }
cfg_resume_prompt() {
  config_get resume_prompt "The previous turn was cut off by a usage-limit reset, now lifted. Re-read your last message and continue exactly where you left off; do not restart completed work."
}

now_epoch() { date +%s; }

# Portable epoch -> "HH:MM" formatter (BSD date on macOS, GNU elsewhere).
fmt_time() { # fmt_time EPOCH
  date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M 2>/dev/null
}

history_append() { # history_append EVENT SESSION_ID [EXTRA_JSON_OBJECT]
  ensure_dirs
  jq -cn --arg ev "$1" --arg id "$2" --arg cwd "${3:-}" --argjson ts "$(now_epoch)" \
    '{ts: $ts, event: $ev, session_id: $id, cwd: $cwd}' >> "$HISTORY_FILE"
}

# Desktop notification, best effort; silent when no notifier exists.
notify() { # notify MESSAGE
  local msg="$1"
  if [ -n "${CARRY_ON_NOTIFY_LOG:-}" ]; then
    printf '%s\n' "$msg" >> "$CARRY_ON_NOTIFY_LOG"
  elif command -v osascript >/dev/null 2>&1; then
    # Escape backslashes before quotes, or \" in the input would unescape.
    msg=${msg//\\/\\\\}; msg=${msg//\"/\\\"}
    osascript -e "display notification \"$msg\" with title \"carry-on\"" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "carry-on" "$msg" >/dev/null 2>&1 || true
  fi
}

claude_bin() {
  if [ -n "${CLAUDE_BIN:-}" ]; then printf '%s' "$CLAUDE_BIN"; return; fi
  command -v claude 2>/dev/null || printf '%s' "$HOME/.local/bin/claude"
}

chain_count() { # chain_count SESSION_ID
  cat "$CHAINS_DIR/$1" 2>/dev/null || echo 0
}

chain_increment() { # chain_increment SESSION_ID
  ensure_dirs
  echo $(( $(chain_count "$1") + 1 )) > "$CHAINS_DIR/$1"
}
