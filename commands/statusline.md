---
description: Wire the always-visible carry-on statusline badge
---

Wire the carry-on statusline badge. Run:

`"${CLAUDE_PLUGIN_ROOT}/bin/carry-on" statusline`

It installs the badge as a **drop-in fragment** (`~/.claude/statusline.d/60-carry-on.sh`)
and wires it without ever overwriting another tool's statusline. Then:

- **Exit 0** — done. Relay its confirmation line to the user; the badge appears
  on the next statusline refresh.
- **Output starts with `NEEDS-CHOICE`** (followed by a tab and the user's current
  statusline command) — the user already runs their own statusline that does not
  include the badge, and carry-on will not overwrite it. Show them that command
  and offer two ways to add the badge:

  1. **Convert to the drop-in dispatcher (recommended — collision-proof).** So no
     future statusline setup can strand any badge:
     - Copy `${CLAUDE_PLUGIN_ROOT}/hooks/statusline-dispatch.sh` to
       `~/.claude/hooks/statusline-dispatch.sh`.
     - Move their current behavior into a fragment `~/.claude/statusline.d/10-mine.sh`
       — a small script that runs their old command with the statusline JSON on
       stdin (their badge keeps its place; the `10-` prefix renders it first).
     - Point `settings.json` `.statusLine.command` at
       `bash "$HOME/.claude/hooks/statusline-dispatch.sh"`.

  2. **Chain (quick, less robust).** If their command runs a script file, append
     to that script, before its final print:

     ```bash
     carry_on=$(bash "$HOME/.claude/hooks/carry-on-statusline.sh" <<<"$input" 2>/dev/null)
     [ -n "$carry_on" ] && printf ' %s' "$carry_on"
     ```

  Never overwrite a statusline command you don't understand — ask first.

After wiring, confirm `jq . ~/.claude/settings.json` still parses.
