#!/bin/bash
# Generic statusline dispatcher — a stable entry point for Claude Code's single
# statusLine slot. Point settings.json at this once; then every tool that wants
# a badge drops one executable fragment in statusline.d/ (run in filename order,
# NN- prefix = priority) instead of fighting over the one statusLine command.
# Each fragment gets the Claude Code statusline JSON on stdin and prints its
# badge or nothing; one that errors or is silent is skipped, so a broken badge
# never blanks the line. Add a badge = drop a file, remove it = delete the file,
# and nothing edits what it does not own.
#
# Not carry-on-specific: any tool may reuse it. carry-on installs it only when
# you have no statusLine yet — it never replaces one you already run.
set -u
input=$(cat)
dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline.d"
sep=''
for frag in "$dir"/*.sh; do
  [ -f "$frag" ] || continue
  out=$(bash "$frag" <<<"$input" 2>/dev/null) || continue
  [ -n "$out" ] || continue
  printf '%s%s' "$sep" "$out"
  sep=' '
done
printf '\n'
