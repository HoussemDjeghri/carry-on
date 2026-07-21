<div align="center">

<h1>carry-on</h1>

<p><em>Your session hits the usage limit at 2am. carry-on resumes it when the window resets.</em></p>
<p><strong>Hook-native. No daemon. No polling. Nothing typing into your terminal.</strong></p>

<p>
  <img alt="license MIT" src="https://img.shields.io/badge/license-MIT-D97757">
  <img alt="version 0.1.0" src="https://img.shields.io/badge/version-0.1.0-191919">
  <img alt="dependencies: bash and jq" src="https://img.shields.io/badge/deps-bash%20%2B%20jq-D4A27F">
  <img alt="no daemon" src="https://img.shields.io/badge/no-daemon-555">
</p>

</div>

---

Long-running agent work dies at the 5-hour or weekly usage limit — mid-task,
holding all its context — and stays dead until you come back. carry-on
catches the death the moment it happens, waits out the window, confirms the
reset with a free probe, and resumes **the same session** headlessly:

```
CARRY-ON ACTIVE — mode: resume

  22:41  session f34907ab hit the usage limit — will resume ~03:00
  03:02  probe confirmed the window reset
  03:02  resumed f34907ab in ~/code/my-app — carried on where it left off
```

## Why it's different

Claude Code now fires a native **`StopFailure` hook** at the exact moment a
turn dies on a rate limit — with the session id, working directory, and error
text in the payload. Every earlier tool in this space predates that hook and
reverse-engineers detection instead:

| | resident daemon + pane watching | probe-polling loops | keystroke injection into tmux | **carry-on** |
|---|:---:|:---:|:---:|:---:|
| How it detects | watches your terminals | asks "are we limited?" on a timer | reads pane text | **the hook fires at the death** |
| Session identity | pane ownership leases | newest-transcript guess | the watched pane | **exact id from the payload** |
| What runs while healthy | a daemon | a polling loop | a watcher | **nothing** |
| Resume | types keys into a pane | headless `--resume` | types "continue" | headless `--resume` |
| Install | npm global + wizard | scheduled task | manual | **`/plugin install`** |

A tool that *can't* type into the wrong terminal beats one that proves it
probably won't. The only long-lived thing carry-on ever runs is a sleeper
process that exists **only while a wait is pending** — then exits.

## Install

Requires [jq](https://jqlang.github.io/jq/) (`brew install jq` / `apt install jq`).

```
/plugin marketplace add HoussemDjeghri/plugins
/plugin install carry-on@houssem-plugins
```

Restart your sessions so the hooks register. Every session then shows:

```
CARRY-ON ACTIVE — mode: resume (auto-resumes this session when a usage limit resets; 'carry-on off' to disable)
```

## How it works

1. **Catch.** A turn dies on `rate_limit` → the `StopFailure` hook hands
   carry-on the session id, cwd, permission mode, and error text. Guards run
   (disabled? denied project? plan-mode session? resume-chain cap?), then a
   pending record is written and one detached sleeper is spawned.
2. **Wait.** The sleeper sleeps to the reset time parsed from the error text
   — or on a stepped schedule when the message carries none. Wall-clock
   sliced, so laptop sleep doesn't break the math. Waits cap at 7 days.
3. **Confirm.** A one-turn probe on the small model checks the window
   actually lifted — a still-limited probe fails **free** and usually carries
   a fresh reset time to re-sleep on. The new window is never burned on a
   guess.
4. **Resume.** For each pending session:
   `claude --resume <id> -p "<continue prompt>"` from its original
   directory, with its original permission mode. Output is logged, history
   recorded, desktop notification sent. The sleeper exits.

Next time you open a session in that project, carry-on tells you what
happened overnight:

```
carry-on: session f34907ab in this project was resumed after a limit reset — carry-on log f34907ab
```

## Commands

| Command | What it does |
|---|---|
| `/carry-on:status` (or `carry-on status`) | Pending wakes + recent history |
| `/carry-on:cancel <id\|all>` | Drop pending wake(s) |
| `/carry-on:on` / `/carry-on:off` | Enable / disable catching |
| `carry-on config mode notify` | Switch to notify-only (no auto-resume) |
| `carry-on log [id-prefix]` | Tail a resume's output log |

## Honest-cost note

**Auto-resume spends your fresh usage window while you're away.** That is
the point — but it should be a choice. Switch to notifications-only with one
line:

```
carry-on config mode notify
```

You'll get "the window reset, session X is resumable" instead of an
automatic resume.

## Trust & safety

- **Nothing resident.** No daemon; the sleeper exists only between a limit
  death and its resume, then exits. Uninstall leaves nothing running.
- **Never types into terminals.** Resumes are headless `claude --resume`
  child processes; your panes are never touched.
- **Never escalates permissions.** A session that ran with
  `bypassPermissions` is resumed at `acceptEdits`, not bypass. Plan-mode
  sessions are never auto-resumed — that's a human mid-decision.
- **Loop-proof.** A resumed session that hits the limit again is re-caught
  with a chain counter; after 3 resumes it goes notify-only.
- **Deny list.** `carry-on config deny "$HOME/sensitive*:$HOME/other*"`
  keeps chosen projects out entirely.
- All state is plain files under `~/.claude/carry-on/` — read them any time.
  Uninstalling the plugin keeps your history; delete the directory to wipe.

## Config

`carry-on config` shows current values. Keys: `enabled` · `mode`
(resume|notify) · `resume_prompt` · `max_chain` (3) · `max_wait` (seconds,
default 7 days) · `probe_model` (haiku) · `deny` (colon-separated globs).

## Limits of scope

Claude Code only (the hook is the whole point). macOS/Linux bash; Windows
users: see the existing Windows auto-resume tools. If Claude Code ships
native auto-resume ([#35744](https://github.com/anthropics/claude-code/issues/35744),
[#62788](https://github.com/anthropics/claude-code/issues/62788)), retire
this plugin with a smile — until then, carry on.

---

<p align="center">MIT — see <a href="LICENSE">LICENSE</a> · run <code>./test.sh</code> before a PR</p>
