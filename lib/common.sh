#!/bin/bash
# Shared state, config, and helpers for carry-on. Sourced by hooks, the
# sleeper, and the CLI — keep it dependency-free beyond bash + jq.

CARRY_ON_HOME="${CARRY_ON_HOME:-$HOME/.claude/carry-on}"
PENDING_DIR="$CARRY_ON_HOME/pending"
LOGS_DIR="$CARRY_ON_HOME/logs"
CHAINS_DIR="$CARRY_ON_HOME/chains"
LASTSEEN_DIR="$CARRY_ON_HOME/lastseen"
DAILY_DIR="$CARRY_ON_HOME/daily"
# A session carry-on will NOT resume — because its policy says so, or because
# resuming it would cost more than it is worth — leaves a signal here instead,
# for an orchestrator to start a FRESH successor in the same cwd. One JSON file
# per session id; nothing in carry-on ever consumes them.
# shellcheck disable=SC2034
CHAINME_DIR="$CARRY_ON_HOME/chain-me"
# Per-session resume policy (resume|chain|notify|off), one word per file.
# shellcheck disable=SC2034
MODES_DIR="$CARRY_ON_HOME/modes"
# Append-only JSONL mapping a resumed session's old pid to the new one, for
# supervisors that watch pids. See resume_log_append.
# shellcheck disable=SC2034
RESUME_LOG="$CARRY_ON_HOME/resumes.jsonl"
# Wake-stagger reservation: the epoch of the next free launch slot, plus the
# lock that makes claiming one atomic across processes. See stagger_claim.
# shellcheck disable=SC2034
STAGGER_FILE="$CARRY_ON_HOME/wake-slot"
# shellcheck disable=SC2034
STAGGER_LOCK="$CARRY_ON_HOME/wake-slot.lock"
# shellcheck disable=SC2034  # consumed by the SessionStart reporter
SESSIONS_DIR="$CARRY_ON_HOME/sessions"
# Badge lifecycle markers (per session id), consumed by the statusline + reporter:
#   resuming/<id> — a headless resume is running RIGHT NOW (set/cleared by the sleeper)
#   resumed/<id>  — resumed successfully; the still-open TUI should reattach to
#                   see the continued transcript (cleared by SessionStart on reattach)
# shellcheck disable=SC2034
RESUMING_DIR="$CARRY_ON_HOME/resuming"
# shellcheck disable=SC2034
RESUMED_DIR="$CARRY_ON_HOME/resumed"
HISTORY_FILE="$CARRY_ON_HOME/history.jsonl"
CONFIG_FILE="$CARRY_ON_HOME/config"
# shellcheck disable=SC2034  # consumed by the scripts that source this file
LOCK_DIR="$CARRY_ON_HOME/sleeper.lock"

# Claude Code config dir + the statusline wiring under it. The badge is a
# "fragment" dropped into statusline.d/, which a dispatcher (the user's
# statusLine command points at it) runs alongside every other fragment — a
# drop-in dir so tools that each want a badge never fight over Claude Code's
# single statusLine slot. These paths are read by the CLI and the SessionStart
# hook, not by common.sh itself.
# shellcheck disable=SC2034
CLAUDE_CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# shellcheck disable=SC2034
STATUSLINE_D="$CLAUDE_CFG_DIR/statusline.d"
# shellcheck disable=SC2034
STATUSLINE_BADGE="$CLAUDE_CFG_DIR/hooks/carry-on-statusline.sh"
STATUSLINE_FRAGMENT="$STATUSLINE_D/60-carry-on.sh"
# shellcheck disable=SC2034
STATUSLINE_DISPATCH="$CLAUDE_CFG_DIR/hooks/statusline-dispatch.sh"
SETTINGS_FILE="$CLAUDE_CFG_DIR/settings.json"

ensure_dirs() {
  mkdir -p "$PENDING_DIR" "$LOGS_DIR" "$CHAINS_DIR" "$LASTSEEN_DIR" "$DAILY_DIR" \
    "$SESSIONS_DIR" "$RESUMING_DIR" "$RESUMED_DIR" "$CHAINME_DIR" "$MODES_DIR"
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

  # Lock held. Our sleeper, still running → nothing to do.
  local pid
  pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if sleeper_alive "$pid"; then
    return 0
  fi
  # Stale: dead pid, or no pid ever appeared (spawn failed) and the lock is
  # old enough that a healthy sleeper would have written one. Steal
  # atomically via mv so two concurrent stealers can't both proceed.
  local spawned
  spawned=$(read_int "$LOCK_DIR/spawned_at")
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
#
# An environment variable of the same name outranks the file: `CARRY_ON_MODE`,
# `CARRY_ON_WAKE_GAP`, `CARRY_ON_GATE_IDLE`… That is how a fleet gives one
# spawned session a policy of its own without racing every other session for
# the single shared config file, and how the test suite pins a value a test
# fixture would otherwise truncate away.
config_get() { # config_get KEY DEFAULT
  local val env_name
  env_name="CARRY_ON_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  val="${!env_name-}"
  [ -n "$val" ] || val=$(grep -E "^$1=" "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
  printf '%s' "${val:-$2}"
}

# A whole number, or the fallback when the value in hand is anything else. An
# empty string flows into `[ "$n" -ge … ]`, which THROWS and takes a branch
# nobody chose, and into jq's --argjson, which rejects it and silently skips the
# write that was the whole point of the call — so every number crossing a
# boundary (a file, the config, a JSON field) passes through here first.
int_or() { # int_or VALUE DEFAULT
  case "$1" in "" | *[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

# A count read back from disk. These files are documented as user-readable, and
# `echo N > file` is not atomic — a kill, a reboot or a full disk can leave one
# zero-length or torn.
read_int() { # read_int FILE [DEFAULT]
  int_or "$(cat "$1" 2>/dev/null || true)" "${2:-0}"
}

# The same reading applied to config, which is a user-edited file of strings.
# A non-numeric cap made its comparison throw and come back FALSE — silently
# UNLIMITED, the exact opposite of what a cap is for. Every numeric key gets the
# documented default rather than the failure-open branch.
config_int() { # config_int KEY DEFAULT
  int_or "$(config_get "$1" "$2")" "$2"
}

# Is PID our sleeper? Liveness alone does not answer that, and every caller here
# needs the stronger claim. The lock dir and its pid file outlive a reboot on
# disk, and the OS recycles pids: once an unrelated process lands on that number,
# `kill -0` says "healthy sleeper" and every recovery path returns having done
# nothing, so a pending stranded by the reboot is never resumed, never notified
# and never expired — expire_stale runs only inside the sleeper that never
# started. `cancel` failed harder still: it signalled that pid AND its children.
sleeper_alive() { # sleeper_alive PID
  [ -n "${1:-}" ] || return 1
  kill -0 "$1" 2>/dev/null || return 1
  ps -o command= -p "$1" 2>/dev/null | grep -q 'sleeper\.sh'
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
cfg_max_chain()     { config_int max_chain 3; }
cfg_max_wait()      { config_int max_wait 604800; }   # 7 days
cfg_deny()          { config_get deny ""; }
cfg_probe_model()   { config_get probe_model haiku; }
cfg_daily_cap()     { config_int daily_cap 12; }
# Gap (seconds) after which a fresh limit hit is treated as healthy usage that
# ran a full window rather than a runaway resume loop — it clears the chain.
# Only rapid re-deaths (a fresh window burned through faster than this)
# accumulate toward max_chain. Default 1h.
cfg_chain_decay()   { config_get chain_decay 3600; }
# How to resume a session that ran in default (prompt-per-edit) mode:
# acceptEdits resumes it with edits auto-approved (useful, but an unattended
# escalation the README discloses); skip degrades it to notify-only.
cfg_resume_default_mode() { config_get resume_default_mode acceptEdits; }
# How to resume a session that ran in bypassPermissions. Default `bypass`
# replays the original mode — continuity of the posture the session was already
# running, so an unattended resume can actually run git/tests/CLI. Set
# `acceptEdits` to downgrade instead: safer (no auto-approval of arbitrary
# commands) but the resume then can't run non-edit tools either.
cfg_resume_bypass_mode() { config_get resume_bypass_mode bypass; }
# ── cache economy (see lib/cache-economy.sh) ──────────────────────────────
# Seconds between consecutive wakes at one reset. Six sessions waking together
# re-prime six cold transcripts in the same instant; spacing them keeps the
# window's first minutes for work. 0 disables the stagger.
cfg_wake_gap()   { config_int wake_gap 180; }
# Gate thresholds. Transcript size is the primary signal — re-prime cost is
# proportional to it — and only counts when paired with evidence the prompt
# cache is actually cold: idle past its TTL, or an age no window survives.
# Any 0 disables that signal; gate_transcript_bytes=0 disables the gate.
cfg_gate_bytes() { config_int gate_transcript_bytes 2097152; }   # 2 MB
cfg_gate_idle()  { config_int gate_idle 3600; }                  # prompt-cache TTL
cfg_gate_age()   { config_int gate_age 21600; }                  # one window + slack
cfg_resume_prompt() {
  config_get resume_prompt "Resume work. Your previous turn was interrupted by a usage-limit reset, which has now lifted. Re-read your last message and the task you were on, then continue from the next incomplete step. Do not restart work already finished and do not wait for reconfirmation — carry on to completion."
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

# carry-on posts NO desktop notifications by design: the statusline badge is
# the live signal, and reattaching a resumed session shows the continued work.
# This records each notice as a timestamped prose line beside the structured
# history (`tail` it any time) and honors the test capture seam. It never
# shells out to a desktop notifier.
notify() { # notify MESSAGE
  local msg="$1"
  if [ -n "${CARRY_ON_NOTIFY_LOG:-}" ]; then
    printf '%s\n' "$msg" >> "$CARRY_ON_NOTIFY_LOG"
    return
  fi
  ensure_dirs
  printf '%s\t%s\n' "$(now_epoch)" "$msg" >> "$CARRY_ON_HOME/notices.log"
}

claude_bin() {
  if [ -n "${CLAUDE_BIN:-}" ]; then printf '%s' "$CLAUDE_BIN"; return; fi
  command -v claude 2>/dev/null || printf '%s' "$HOME/.local/bin/claude"
}

# The resume policy in force for a session about to be caught, most specific
# source first:
#   1. the session's own mode  (carry-on mode <m> <session-id>)
#   2. a `.carry-on` file in the project — one word, which is what a fleet drops
#      beside a worker it spawns
#   3. the global `mode` config
# A fleet wants auto-resume for exactly ONE session per project (the
# orchestrator); a worker's death is the dispatch chain's job, not carry-on's.
#   resume — auto-resume (the default)
#   chain  — never resume; signal an orchestrator to start a fresh successor
#   notify — record the reset, leave the resume to a human
#   off    — do not even track this session
# An unreadable or unknown value reads as `resume`: the policy file is a way to
# hold back the safety net, never a way to break it.
session_mode() { # session_mode SESSION_ID CWD
  local m=""
  [ -n "${1:-}" ] && m=$(head -1 "$MODES_DIR/$1" 2>/dev/null | tr -d '[:space:]')
  [ -n "$m" ] || { [ -n "${2:-}" ] && m=$(head -1 "$2/.carry-on" 2>/dev/null | tr -d '[:space:]'); }
  [ -n "$m" ] || m=$(cfg_mode)
  case "$m" in resume | chain | notify | off) printf '%s' "$m" ;; *) printf 'resume' ;; esac
}

# The dying session's own process. Hooks run as a grandchild of it (claude spawns
# a shell, the shell runs the hook), so $PPID is usually that wrapper shell — a
# number no supervisor watching `claude` processes would recognise. Walk up to
# the nearest ancestor that IS claude; fall back to $PPID when the walk finds
# none, which is still better than nothing for the resume log.
session_pid() {
  local p="$PPID" n=0
  while [ "$n" -lt 6 ] && [ -n "$p" ] && [ "$p" -gt 1 ]; do
    case "$(ps -o comm= -p "$p" 2>/dev/null)" in *claude*) printf '%s' "$p"; return 0 ;; esac
    p=$(int_or "$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')" 0)
    n=$((n + 1))
  done
  printf '%s' "$PPID"
}

# A resume moves a live session from one process to another, and an external
# supervisor that watches pids sees only the first half: the pid it knew is gone,
# so it reports a death that never happened. This append-only log is the mapping
# — a supervisor checks it before believing a pid's disappearance.
resume_log_append() { # resume_log_append SESSION_ID OLD_PID NEW_PID
  ensure_dirs
  jq -cn --arg id "$1" \
    --argjson old "$(int_or "${2:-}" 0)" --argjson new "$(int_or "${3:-}" 0)" \
    --argjson ts "$(now_epoch)" \
    '{resumed_at: $ts, session_id: $id, old_pid: $old, new_pid: $new}' >> "$RESUME_LOG"
}

chain_count() { # chain_count SESSION_ID
  read_int "$CHAINS_DIR/$1"
}

chain_increment() { # chain_increment SESSION_ID
  ensure_dirs
  echo $(( $(chain_count "$1") + 1 )) > "$CHAINS_DIR/$1"
}

# When a resume hands a session its fresh window, stamp the time. The gap
# between this stamp and the next limit death is how long that window lasted —
# the signal chain-decay uses to tell healthy usage from a resume loop.
chain_last_resume() { cat "$CHAINS_DIR/$1.at" 2>/dev/null || echo 0; }
chain_mark_resume() { ensure_dirs; now_epoch > "$CHAINS_DIR/$1.at"; }
chain_reset()       { ensure_dirs; echo 0 > "$CHAINS_DIR/$1"; }

# Strip quotes and expand $HOME / $CLAUDE_CONFIG_DIR in a statusLine token, so a
# path pulled from settings.json can be tested on disk. Best-effort: an exotic
# expansion it does not know degrades to a non-existent path (→ "not wired"),
# never to a wrong positive.
_expand_config_path() { # _expand_config_path TOKEN
  local t="$1"
  t=${t//\"/}; t=${t//\'/}
  t=${t//\$\{HOME\}/$HOME}; t=${t//\$HOME/$HOME}
  t=${t//\$\{CLAUDE_CONFIG_DIR\}/$CLAUDE_CFG_DIR}; t=${t//\$CLAUDE_CONFIG_DIR/$CLAUDE_CFG_DIR}
  printf '%s' "$t"
}

# Is carry-on's badge reachable from the ACTIVE statusLine command? True when
# that command names our badge script, iterates the statusline.d drop-in dir
# (with our fragment present), or names a script that — one level down — does
# either. Keys off the CURRENT entry point only: a stale chain in a file
# settings.json no longer points at reads correctly as un-wired. Heuristic but
# safe — a command it cannot resolve degrades to "not wired", at worst one extra
# re-offer line, never a wrong badge.
statusline_wired() {
  [ -f "$SETTINGS_FILE" ] || return 1
  local cmd tok rt
  cmd=$(jq -r '.statusLine.command // empty' "$SETTINGS_FILE" 2>/dev/null) || return 1
  [ -n "$cmd" ] || return 1
  case "$cmd" in
    *carry-on-statusline.sh*) return 0 ;;
    *statusline.d*) [ -f "$STATUSLINE_FRAGMENT" ] && return 0 ;;
  esac
  for tok in $cmd; do
    rt=$(_expand_config_path "$tok")
    [ -f "$rt" ] || continue
    grep -qs 'carry-on-statusline\.sh' "$rt" && return 0
    grep -qs 'statusline\.d' "$rt" && [ -f "$STATUSLINE_FRAGMENT" ] && return 0
  done
  return 1
}
