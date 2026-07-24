# carry-on — design

Auto-resume Claude Code sessions after a usage-limit reset. A Claude Code
plugin: when a turn dies on a rate limit, carry-on catches the native
`StopFailure` hook event, waits out the window, probe-confirms the reset, and
resumes the same session headlessly — no daemon, no polling, no keystroke
injection.

Ratified with the user 2026-07-21: scope = any session including interactive;
default = auto-resume with a continue prompt (notify-only configurable);
ships as a plugin in the `houssem-plugins` marketplace; name chosen for
wait-then-resume semantics (bypass-sounding names rejected).

## Why it exists

Overnight/unattended agent work dies at the 5-hour or weekly limit and stays dead
until a human returns. Prior art solves it pre-hook-era: resident daemons,
probe-polling loops, tmux pane-text watching, keystroke injection with
ownership leases (unsnooze), transcript-mtime heuristics (Windows
auto-resume). Claude Code now ships the signal natively:

> `StopFailure` — "Runs instead of Stop when the turn ends due to an API
> error … Use this to log failures, send alerts, or take recovery actions."
> Matcher: error type, including `rate_limit`. Payload: `session_id`, `cwd`,
> `permission_mode`, `error`, `error_details`, `last_assistant_message`.

Hook-native deletes the entire hazardous surface: exact session identity for
free, no resident process, nothing typing into terminals.

| | unsnooze | Windows auto-resume | pane watchers | **carry-on** |
|---|---|---|---|---|
| Detection | daemon watches panes/GUI | probe polling | tmux text regex | native hook, event-driven |
| Identity | pane leases + ledger | newest-transcript heuristic | the watched pane | `session_id` from the payload |
| Resume | keystroke injection | headless `--resume` | types "continue" | headless `--resume` |
| Runtime | Node ≥20 + npm daemon | PowerShell task | Go TUI | bash+jq, sleeper only while waiting |
| Install | npm + wizard | setup.bat | manual | `/plugin install` |

Retirement clause: Anthropic feature requests #35744/#62788 ask for native
auto-resume. If it ships, carry-on retires gracefully — hook-native is the
smallest sunk cost in the space.

## Architecture

Repo root = plugin (standard Claude Code plugin + marketplace layout):

- `.claude-plugin/plugin.json` — registers hooks: `StopFailure` (matcher
  `rate_limit`) → catcher; `SessionStart` → reporter.
- `hooks/stop-failure.sh` — **catcher**: guards → parse reset time → write
  pending record → spawn sleeper (lockfile, one for all) → notify.
- `lib/sleeper.sh` — **waker**, the only long-lived process, exists only
  while a wait is pending: epoch-sliced sleep → probe-confirm → resume each
  pending session → notify → exit.
- `hooks/session-start.sh` — **reporter**: always prints the state banner
  (`CARRY-ON ACTIVE — mode: resume …` / `DISABLED`); plus a context line
  when this cwd's sessions were carried on while the user was away.
- `bin/carry-on` — CLI: `status · cancel [id|all] · on · off · config ·
  log [id] · run -- <claude args>` (wrapper fallback + CI use).
- `commands/*.md` — slash commands wrapping the CLI.

State under `~/.claude/carry-on/`: `config` (KEY=VALUE), `pending/<id>.json`,
`logs/`, `sleeper.lock`, `history.jsonl` (append-only; feeds status + the
reporter).

## Behavior contracts

**Catcher guards, in order:** disabled → exit · cwd matches deny glob →
exit · `permission_mode == "plan"` → exit · chain ≥ `max_chain` (default 3)
→ mark exhausted, notify once, exit.

**Reset-time parser:** tolerant over a fixture corpus ("resets 3:45pm",
"resets at 11pm", "will reset at HH:MM", ISO stamps, and the no-timestamp
variant observed live); no match → stepped fallback schedule (15m, 30m, then
hourly) — never a guess that burns the fresh window.

**Probe-confirm:** `claude -p "Reply with exactly: OK" --model haiku
--max-turns 1`. A still-limited probe fails free and often carries a fresh
reset time → re-sleep. Only a successful probe triggers resumes.

**Resume:** `cd <cwd> && claude --resume <id> -p "<resume_prompt>"
--permission-mode <recorded>`; `bypassPermissions` is never replayed
(downgraded to acceptEdits + noted). Output logged; history appended;
pending cleared. Default prompt: "The previous turn was cut off by a
usage-limit reset, now lifted. Re-read your last message and continue exactly
where you left off; do not restart completed work."

**Chain law:** a resumed run that dies on the limit again re-enters the
catcher with chain+1; at the cap it becomes notify-only. Loop-proof.

**Weekly limits:** waits cap at `max_wait` (default 7d); beyond → expire +
notify.

**Honest-cost stance (README):** auto-resume spends the fresh window
unattended; switching to notify-only is one line
(`carry-on config mode notify`).

## Config

`enabled` (true) · `mode` (resume|notify) · `resume_prompt` ·
`max_chain` (3) · `max_wait` (7d) · `deny` (colon-separated cwd globs).

## Risks (verify before code, results recorded here)

| # | Risk | Probe | Result |
|---|---|---|---|
| 1 | StopFailure may not fire in headless `-p` sessions | user-settings logger hook + `claude -p --model <bogus>` (`model_not_found` is the same event, free) | **CONFIRMED FIRES** (2026-07-21): logged `{"hook_event_name":"StopFailure","error":"model_not_found",session_id,cwd}` from a headless run. The `run` wrapper fallback was dropped from v1 as dead weight. |
| 2 | plugin.json matcher syntax for StopFailure | register + `/hooks` inspection / debug log | Defense-in-depth: the catcher guards on `error=="rate_limit"` itself, so behavior is correct even if the matcher fails to narrow; registration visually confirmed at first install (SessionStart banner + `/hooks`). |
| 3 | Reset-message formats vary | fixture corpus incl. live-observed no-timestamp variant | parser defaults safe |
| 4 | `--resume` while the dead TUI still holds the session | document: stale TUI after carry-on resume; re-resume to see the continued transcript | accepted |

## Testing

`test.sh` (shim-based, red-green): parser corpus · catcher guards
(off/deny/plan/chain) · full cycle against a fake `claude` on PATH
(limit-then-OK shim) asserting the exact resume argv · cancel/status ·
config defaults. Real hook-path e2e via a `model_not_found` scratch run —
no real limit burned. shellcheck clean.

## Non-goals (v1)

Other CLIs · Windows (pointed at the existing Windows tool) · tmux/pane
revival or terminal typing (never) · weekly-limit special-casing beyond the
wait cap.
