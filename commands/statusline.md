---
description: Wire the always-visible carry-on statusline badge
---

Set up the carry-on statusline badge (`[CARRY-ON]`, becoming `[CARRY-ON ●N]`
while N sessions wait to wake). Steps:

1. Copy `"${CLAUDE_PLUGIN_ROOT}/hooks/statusline.sh"` to
   `~/.claude/hooks/carry-on-statusline.sh` (create the directory if needed,
   keep it executable). The stable copy survives plugin updates.
2. Read `~/.claude/settings.json` and look at `statusLine`:
   - **Not set:** set it to
     `{"type": "command", "command": "bash \"$HOME/.claude/hooks/carry-on-statusline.sh\""}`.
   - **Points at a script file:** append to that script, before its final
     newline print:

     ```bash
     carry_on_badge=$(bash "$HOME/.claude/hooks/carry-on-statusline.sh" 2>/dev/null)
     [ -n "$carry_on_badge" ] && printf ' %s' "$carry_on_badge"
     ```
   - **Some other inline command:** show the user the snippet above and ask
     where to put it; never overwrite a statusline you don't understand.
3. Validate `jq . ~/.claude/settings.json` still parses, then tell the user
   the badge appears on the next statusline refresh.
