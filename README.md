<div align="center">

<h1>carry-on</h1>

<p><em>Your session hits the usage limit at 2am. carry-on resumes it when the window resets.</em></p>
<p><strong>Hook-native. No daemon. No polling. Nothing typing into your terminal.</strong></p>

<p>
  <img alt="license MIT" src="https://img.shields.io/badge/license-MIT-D97757">
  <img alt="version 0.2.0" src="https://img.shields.io/badge/version-0.2.0-191919">
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
| `[● CARRY-ON — chained · start fresh]` | deliberately not resumed — [too cold to be worth it, or policy](#cache-economy-why-cold-resumes-are-expensive) |

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
4. **Resume.** For each pending session, newest catch first:
   `claude --resume <id> -p "<continue prompt>"` from its original
   directory, with its original permission mode. Wakes are spaced (`wake_gap`,
   default 3 min) so one reset isn't a herd, and a session too fat and too cold
   to be worth reviving is [chained instead](#cache-economy-why-cold-resumes-are-expensive).
   Output is logged, history recorded, the badge flips to `resumed · reload`.
   The sleeper exits.

Next time you open a session in that project, or reattach the resumed one,
carry-on tells you what happened overnight:

```
carry-on: session f34907ab in this project was resumed after a limit reset — carry-on log f34907ab
```

## Cache economy: why cold resumes are expensive

A resume is not free, and its price is not the work it does.

Claude's prompt cache expires after roughly an hour. Every limit wait is longer
than that, so a resumed session re-primes its **entire transcript** as
cache-creation tokens on its very first turn, before any work happens. A fresh
`claude` boot costs 40–90k tokens. A 21-hour-old session with a fat transcript
was measured writing **1.1M cache tokens in two minutes** on wake — reviving it
cost about ten times what starting a new session in the same directory would
have. And when a fleet's sessions all wait on the same reset, they all wake on
the same second: two measured resets burned 4.6M and 2.4M tokens on cache
writes alone, exhausting the fresh window in ~15 minutes.

carry-on's core value is unchanged — a lean session resumed minutes after the
reset keeps all its context for almost nothing. Three brakes protect it from
the other end, all decided **from the filesystem, before anything talks to the
API**. That timing is the whole point: the re-prime happens on the resumed
session's first turn, so a rule the session reads *after* waking arrives after
the bill.

**1. Wakes are spaced.** Sessions freed by one reset launch `wake_gap` apart
(default 3 min), newest catch first. Nothing is dropped — the herd is spread.

**2. Cold and fat sessions are not resumed.** Before each wake carry-on stats
the session's transcript. Resuming is skipped when it is **larger than
`gate_transcript_bytes`** (default 2 MB) **and** demonstrably cold — idle past
`gate_idle` (default 1h, the cache TTL) or older than `gate_age` (default 6h).

**Read that default honestly: in practice it is a size gate.** Idle is measured
from the moment the limit caught the session to the moment carry-on would
resume it — and *every* limit wait is longer than the one-hour cache TTL, which
is the whole reason this feature exists. So the cold test is nearly always
satisfied, and the shipped default amounts to **"a transcript over 2 MB is not
auto-resumed"**. That is deliberate: past the TTL the cache is gone whatever the
session was doing, and size is what the re-prime bill is proportional to. Size
is the dial you actually tune. Raise `gate_transcript_bytes` if you want fatter
sessions revived anyway, or set it to `0` to switch the gate off entirely.

Instead of resuming, carry-on writes a **chain-me signal**:

```json
// ~/.claude/carry-on/chain-me/<session-id>.json
{ "session_id": "…", "cwd": "/path/to/project",
  "reason": "transcript 3407872B > 2097152B, idle 14400s > 3600s",
  "caught_at": 1754300000, "written_at": 1754314400, "wake": { … } }
```

An orchestrator (a fleet watchdog, a conductor) watches that directory and
starts a **fresh** session in the same `cwd` — cheaper, and with a prompt cache
that is actually warm. The wake is consumed so it never fires later, and the
reason is in `carry-on status`, the history, and the notices. Set
`gate_transcript_bytes` to `0` to switch the gate off.

**3. Fleets can say up front which sessions may be resumed.** A fleet usually
wants auto-resume for exactly *one* session per project — the orchestrator —
because a worker's death is the dispatch chain's job:

```
carry-on mode chain          # this project: never resume, always chain-me
carry-on mode resume         # …and drop `.carry-on` beside the orchestrator
carry-on mode off <id>       # or pin one session
```

The policy lives in a one-word `.carry-on` file in the project (per-session
pins live under `~/.claude/carry-on/modes/`), and every config key also accepts
an environment override — `CARRY_ON_MODE=chain`, `CARRY_ON_WAKE_GAP=60` — so a
spawner can give one session a policy without racing the shared config file.
The policy is read **when the limit is caught**, so set it before a session
dies; changing it afterwards does not retarget a wake already queued (drop that
one with `carry-on cancel <id>`).

**Interop.** A resume moves a live session to a new process, and a supervisor
watching pids sees only the first half: the pid it knew is gone. carry-on
appends the mapping to `~/.claude/carry-on/resumes.jsonl`
(`{resumed_at, session_id, old_pid, new_pid}`) — check it before reporting a
death.

A gated session is **not** a resume: it spends no chain step and gets no
window-handover stamp, so [chain decay](#trust--safety) sees exactly the state
it would have seen had nothing happened.

## Commands

| Command | What it does |
|---|---|
| `/carry-on:status` (or `carry-on status`) | Pending wakes, chain-me signals, recent history |
| `/carry-on:cancel <id\|all>` | Drop pending wake(s) |
| `/carry-on:on` / `/carry-on:off` | Enable / disable catching |
| `/carry-on:mode [m] [id]` | Per-project or per-session policy: `resume` \| `chain` \| `notify` \| `off` |
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
  going. A global cap (default 12, `daily_cap`) still bounds unattended spend
  across ALL sessions — counted per **window**, not per calendar day. It starts
  over when a new window can be PROVEN: a reset time the limit message carried
  has passed, or a probe went from limited to open. Where neither is ever
  available it starts over anyway once nothing has cleared it for longer than a
  full window, so a spent budget can never bind forever. A day whose budget is already spent must never strand a
  window that has reopened. When the cap does bind, it binds on the STALEST
  pending: sessions are served newest-catch first.
- **Bounded by what a resume is worth.** A session too fat to revive cheaply is
  not revived at all — see [cache
  economy](#cache-economy-why-cold-resumes-are-expensive). In practice that
  means transcripts over 2 MB; a lean session is never gated, however long it
  waited. Raise `gate_transcript_bytes`, or set it to `0`, if you would rather
  pay the re-prime.
- **Deny list.** `carry-on config deny "$HOME/sensitive*:$HOME/other*"`
  keeps chosen projects out entirely.
- All state is plain files under `~/.claude/carry-on/` — read them any time.
  Uninstalling the plugin keeps your history; delete the directory to wipe.

## Config

`carry-on config` shows current values. Keys: `enabled` · `mode`
(resume|chain|notify) · `resume_prompt` · `max_chain` (3, rapid re-deaths before
notify-only) · `chain_decay` (seconds, default 1h — gap that clears the
chain) · `max_wait` (seconds, default 7 days) · `probe_model` (haiku) ·
`daily_cap` (12 resumes per limit window, all sessions) ·
`resume_default_mode` (acceptEdits|skip) ·
`resume_bypass_mode` (bypass|acceptEdits — default bypass replays the original
session's bypass for continuity; acceptEdits downgrades it, see the trust note) ·
`wake_gap` (seconds between wakes at one reset, default 180; 0 disables) ·
`gate_transcript_bytes` (2 MB; 0 disables the [cache-economy
gate](#cache-economy-why-cold-resumes-are-expensive)) ·
`gate_idle` (seconds, default 1h) · `gate_age` (seconds, default 6h) ·
`deny`
(colon-separated globs).

Every key also reads from the environment, which outranks the file:
`CARRY_ON_MODE`, `CARRY_ON_WAKE_GAP`, `CARRY_ON_GATE_IDLE`, and so on. Per
project (or per session), `carry-on mode` writes a `.carry-on` policy file
instead.

## Limits of scope

Claude Code only (the hook is the whole point). macOS/Linux bash; Windows
users: see the existing Windows auto-resume tools. If Claude Code ships
native auto-resume ([#35744](https://github.com/anthropics/claude-code/issues/35744),
[#62788](https://github.com/anthropics/claude-code/issues/62788)), retire
this plugin with a smile — until then, carry on.

---

<p align="center">MIT — see <a href="LICENSE">LICENSE</a> · run <code>./test.sh</code> before a PR</p>
