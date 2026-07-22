#!/bin/bash
# carry-on — statusline badge script for Claude Code
# Prints "[● CARRY-ON]" when auto-resume is armed in THIS session,
# "[● CARRY-ON — waiting for reset]" when THIS session hit the limit and is
# queued to wake, and nothing when disabled or in a session carry-on never
# armed. Session-scoped: the SessionStart hook drops a per-session marker;
# no marker means no badge (plugin off, or a session from another setup).
#
# Usage in ~/.claude/settings.json:
#   "statusLine": { "type": "command", "command": "bash /path/to/carry-on-statusline.sh" }
# or chain from an existing statusline script — forward its stdin, the badge
# needs the session id Claude Code pipes in:
#   carry_on_badge=$(printf '%s' "$input" | bash "$HOME/.claude/hooks/carry-on-statusline.sh" 2>/dev/null)
#   [ -n "$carry_on_badge" ] && printf ' %s' "$carry_on_badge"
#
# Plugin users: Claude offers to set this up on first session (it copies this
# file to ~/.claude/hooks/carry-on-statusline.sh so the badge survives plugin
# updates); /carry-on:statusline does the same on demand.
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

if [ -f "$STATE/pending/$sid.json" ]; then
  printf '\033[38;5;108m[● CARRY-ON — waiting for reset]\033[0m'
else
  printf '\033[38;5;108m[● CARRY-ON]\033[0m'
fi
