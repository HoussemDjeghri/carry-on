<div align="center">

<h1>carry-on</h1>

<p><em>Your session hits the usage limit at 2am. carry-on resumes it when the window resets.</em></p>
<p><strong>Hook-native. No daemon. No polling. Nothing typing into your terminal.</strong></p>

<p>
  <img alt="license MIT" src="https://img.shields.io/badge/license-MIT-D97757">
  <img alt="version 0.1.2" src="https://img.shields.io/badge/version-0.1.2-191919">
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

That banner is a log line — it scrolls away. On first session carry-on
offers to wire an **always-visible statusline badge** that tracks the
session through the whole cycle:

| Badge | Meaning |
|---|---|
| `[● CARRY-ON]` | armed and idle |
| `[● CARRY-ON — waiting for reset]` | this session hit the limit, queued to wake |
| `[● CARRY-ON — resuming…]` | a headless resume of this session is running now |
| `[● CARRY-ON — resumed · reload]` | resumed — reattach to see the continued work |

The badge is per-session — it shows only where carry-on is armed, nothing
in other sessions. Because a headless resume writes to the session's
transcript rather than into your open (limit-blocked) tab, the tab keeps
showing stale state; the `resumed · reload` badge is your cue to reattach
(`claude --resume <id>`), and on reattach carry-on confirms in one line that
this session was carried on.

**It plays nice with other statusline tools.** Accept the offer, or run
`/carry-on:statusline` anytime. Claude Code exposes a *single* `statusLine`
command, so badges from different tools otherwise fight over it — every new
setup appends to or overwrites the last, and one eventually wins. carry-on
wires itself as a **drop-in fragment** instead: it installs a small badge
script and drops `~/.claude/statusline.d/60-carry-on.sh`, run by a dispatcher
your `statusLine` points at. Every tool that adopts the pattern owns one file
— add a badge by dropping a file, remove it by deleting the file, nothing
edits what it doesn't own. No statusline yet? carry-on installs the dispatcher.
Already run one? It **never overwrites it** — it adds the fragment when your
statusline is a dispatcher, or asks how to join when it isn't.

The one collision a drop-in dir can't prevent is another tool *replacing* your
`statusLine` command wholesale — that drops every badge at once, not just
carry-on's. So carry-on **self-heals**: each session it checks whether its
badge is still wired, and if something un-wired it, says so once and offers to
re-wire. A silent break becomes a one-session recovery.

**No desktop notifications, by design.** carry-on never pops a desktop alert.
The always-visible badge is the live signal, and reattaching a resumed session
shows the continued work. (macOS can't post a NotificationCenter alert without
the Script Editor "Show" button or an installed helper, and a detached resume
has no terminal to notify through anyway — a badge you already trust beats a
popup we'd have to caveat.) Every catch, wait, and resume is still recorded to
`~/.claude/carry-on/notices.log` and the structured history behind
`carry-on status`, so nothing is lost — it just doesn't interrupt you.

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
   recorded, the badge flips to `resumed · reload`. The sleeper exits.

Next time you open a session in that project, or reattach the resumed one,
carry-on tells you what happened overnight:

```
carry-on: session f34907ab in this project was resumed after a limit reset — carry-on log f34907ab
```

## Commands

| Command | What it does |
|---|---|
| `/carry-on:status` (or `carry-on status`) | Pending wakes + recent history |
| `/carry-on:cancel <id\|all>` | Drop pending wake(s) |
| `/carry-on:on` / `/carry-on:off` | Enable / disable catching |
| `/carry-on:statusline` | Wire the always-visible statusline badge |
| `carry-on config mode notify` | Record-only: no auto-resume, signalled via the badge + `carry-on status` |
| `carry-on log [id-prefix]` | Tail a resume's output log |

## Honest-cost note

**Auto-resume spends your fresh usage window while you're away.** That is
the point — but it should be a choice. Switch to record-only with one line:

```
carry-on config mode notify
```

Then instead of an automatic resume, the window-reset is recorded to
`carry-on status` and the badge holds `waiting for reset` until you resume
that session yourself.

## Trust & safety

- **Nothing resident.** No daemon; the sleeper exists only between a limit
  death and its resume, then exits. Uninstall leaves nothing running.
- **Never types into terminals.** Resumes are headless `claude --resume`
  child processes; your panes are never touched.
- **Permission posture, stated precisely.** A resumed session **inherits the
  original session's permission mode** — continuity of what you were running. A
  `bypassPermissions` session resumes at `bypassPermissions`; an `acceptEdits`
  session at `acceptEdits`. Plan-mode sessions are never auto-resumed — that's a
  human mid-decision. A **default-mode** session (prompts before each edit) is
  resumed at `acceptEdits` so it can work unattended — a disclosed step up; set
  `carry-on config resume_default_mode skip` for notify-only instead.
- **Inheriting bypass is the loaded gun — know what the default does.** If the
  session that hit the limit ran `bypassPermissions`, its resume runs at bypass
  too: the revived run **auto-approves every action with no human present**
  (arbitrary Bash, deletes, network, `git push`), on your account, spending your
  window. That's faithful continuity — the session already had bypass on — but
  it is *more* exposed than an attended bypass session because nobody is
  watching. Restrain it with `carry-on config deny "<globs>"` (projects it must
  never touch), the `daily_cap` / chain caps, or downgrade every bypass resume
  to edits-only with `carry-on config resume_bypass_mode acceptEdits` (safer,
  but the resume then can't run git/tests/CLI).
- **Endures many resets, still loop-proof.** A long unattended run that hits
  the limit again and again is carried on across *every* reset — the chain
  counter only trips to notify-only on **rapid** re-deaths, a fresh window
  burned through inside `chain_decay` (default 1h). That's the signature of a
  resume loop; healthy usage spaced hours apart clears the counter and keeps
  going. A global daily cap (default 12 resumes/day, `daily_cap`) still bounds
  total unattended spend across ALL sessions.
- **Deny list.** `carry-on config deny "$HOME/sensitive*:$HOME/other*"`
  keeps chosen projects out entirely.
- All state is plain files under `~/.claude/carry-on/` — read them any time.
  Uninstalling the plugin keeps your history; delete the directory to wipe.

## Config

`carry-on config` shows current values. Keys: `enabled` · `mode`
(resume|notify) · `resume_prompt` · `max_chain` (3, rapid re-deaths before
notify-only) · `chain_decay` (seconds, default 1h — gap that clears the
chain) · `max_wait` (seconds, default 7 days) · `probe_model` (haiku) ·
`daily_cap` (12) · `resume_default_mode` (acceptEdits|skip) ·
`resume_bypass_mode` (bypass|acceptEdits — default bypass replays the original
session's bypass for continuity; acceptEdits downgrades it, see the trust note) ·
`deny`
(colon-separated globs).

## Limits of scope

Claude Code only (the hook is the whole point). macOS/Linux bash; Windows
users: see the existing Windows auto-resume tools. If Claude Code ships
native auto-resume ([#35744](https://github.com/anthropics/claude-code/issues/35744),
[#62788](https://github.com/anthropics/claude-code/issues/62788)), retire
this plugin with a smile — until then, carry on.

---

<p align="center">MIT — see <a href="LICENSE">LICENSE</a> · run <code>./test.sh</code> before a PR</p>
