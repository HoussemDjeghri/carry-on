---
description: Set this project's (or one session's) carry-on resume policy
argument-hint: [resume|chain|notify|off] [session-id]
---

Run `"${CLAUDE_PLUGIN_ROOT}/bin/carry-on" mode $ARGUMENTS` with the Bash tool
and show the user its output.

With no arguments it prints the policy in force for the current directory. With
a value it writes `.carry-on` in the current project (add a session id to pin
one session instead):

- `resume` — auto-resume after a limit reset (the default).
- `chain` — never resume this session. On a limit hit carry-on writes a
  **chain-me signal** to `~/.claude/carry-on/chain-me/<id>.json` so an
  orchestrator can start a FRESH session in the same directory. This is what a
  fleet wants for its workers: resuming a session that has been idle for hours
  re-primes its whole transcript as cache-creation tokens, which costs far more
  than a fresh start.
- `notify` — record the reset, leave the resume to a human.
- `off` — do not track this project's sessions at all.

`.carry-on` is a file in the user's project — mention that it was created, in
case they want it in `.gitignore` (or committed, if the whole team wants the
policy).
