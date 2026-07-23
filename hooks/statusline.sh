#!/bin/bash
# carry-on — statusline badge script for Claude Code
# Per-session badge, one of:
#   [● CARRY-ON]                       armed and idle
#   [● CARRY-ON — waiting for reset]   THIS session hit the limit, queued to wake
#   [● CARRY-ON — resuming…]           a headless resume of THIS session is running now
#   [● CARRY-ON — resumed · reload]    resumed; reattach (claude --resume) to see the work
# Nothing when disabled or in a session carry-on never armed. Session-scoped:
# the SessionStart hook drops a per-session marker; no marker means no badge
# (plugin off, or a session from another setup).
#
# Wiring: `/carry-on:statusline` drops this as a fragment in ~/.claude/statusline.d/
# (run by a dispatcher your statusLine points at) so it coexists with other
# tools' badges instead of fighting over Claude Code's single statusLine slot.
# It reads the statusline JSON on stdin for the session id. Standalone use:
#   "statusLine": { "type": "command", "command": "bash /path/to/carry-on-statusline.sh" }
# The stable copy at ~/.claude/hooks/carry-on-statusline.sh survives plugin updates.
#
# Runs on every statusline refresh: no jq, no sourcing. Renders only fixed
# strings — never state-file or stdin content — and the session id is
# charset-limited before it touches a path, so nothing hostile reaches the
# terminal or the filesystem.
set -u
STATE="${CARRY_ON_HOME:-$HOME/.claude/carry-on}"
[ -d "$STATE" ] || exit 0
grep -qs '^enabled=false' "$STATE/config" && exit 0

sid=$(head -c 4096 2>/dev/null | tr -d '\n' | sed -n 's/.*"session_id" *: *"\([A-Za-z0-9._-]*\)".*/\1/p')
[ -n "$sid" ] && [ -f "$STATE/sessions/$sid" ] || exit 0

if [ -f "$STATE/resuming/$sid" ]; then
  printf '\033[38;5;108m[● CARRY-ON — resuming…]\033[0m'
elif [ -f "$STATE/resumed/$sid" ]; then
  printf '\033[38;5;108m[● CARRY-ON — resumed · reload]\033[0m'
elif [ -f "$STATE/pending/$sid.json" ]; then
  printf '\033[38;5;108m[● CARRY-ON — waiting for reset]\033[0m'
else
  printf '\033[38;5;108m[● CARRY-ON]\033[0m'
fi
