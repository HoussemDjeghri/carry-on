# Changelog

Notable changes per release. Dates are release dates; the suite result quoted
is the one the release was cut on.

## 0.3.0 — cache economy

A wake is not free. A session idle past the prompt cache's ~1h TTL re-primes
its **entire transcript** as cache-creation tokens on its first turn, so
reviving a cold, fat session costs about ten fresh boots — and a fleet waking
five or six of them on the same second burned 4.6M tokens before doing any
work. Three brakes, all decided from the filesystem before anything talks to
the API.

### Added

- **Staggered wakes.** Sessions freed by one reset now launch `wake_gap`
  apart (default 180s), most-recently-caught first. The slot is reserved
  under a lock in a shared file, so two processes can never both conclude
  they are first. `wake_gap=0` restores the old back-to-back behaviour.
- **Cache-economy gate.** Before each wake, carry-on stats the session's
  transcript and refuses to resume one that is both large
  (`gate_transcript_bytes`, default 2 MB) and demonstrably cold — idle past
  `gate_idle` (default 1h) or older than `gate_age` (default 6h).
  **In practice this is a size gate**: idle is measured from the catch to the
  wake, and every limit wait exceeds the one-hour cache TTL, so the cold test is
  nearly always satisfied. Read the default as "a transcript over 2 MB is not
  auto-resumed". `gate_transcript_bytes=0` disables it.
- **Chain-me signals.** A session the gate refuses (or a policy declines) gets
  `~/.claude/carry-on/chain-me/<session-id>.json` — `session_id`, `cwd`,
  `reason` with the tripped thresholds and their values, `caught_at`,
  `written_at`, and the original wake record — so an orchestrator can start a
  FRESH session in that directory instead. carry-on never reads these back.
  They are listed by `carry-on status`.
- **Per-session / per-project resume policy.** `carry-on mode
  resume|chain|notify|off` writes a one-word `.carry-on` file in the project,
  or pins a single session (`carry-on mode chain <session-id>`). A fleet can
  now give auto-resume to exactly one session per project and chain the rest.
  New `/carry-on:mode` command.
- **Environment overrides for every config key.** `CARRY_ON_MODE`,
  `CARRY_ON_WAKE_GAP`, `CARRY_ON_GATE_IDLE`… outrank the config file, so a
  spawner can hand one session a policy without racing the shared file.
- **Machine-readable resume log** at `~/.claude/carry-on/resumes.jsonl`
  (`{resumed_at, session_id, old_pid, new_pid}`, append-only). A supervisor
  watching pids saw a resumed session's old pid die and reported a death that
  never happened; this is the mapping to check first.
- Pending records now also carry `pid`. Additive — every previously documented
  field is unchanged.

### Notes

- A gated session is **not** a resume: no chain step is spent and no
  window-handover stamp is written, so chain-decay sees exactly the state it
  would have seen had nothing happened.
- Absent config, a single-session user notices nothing except that a fat
  session left cold for hours no longer auto-resumes — and `carry-on status`,
  the history and the notices all say why.
- The external CLI contract is unchanged: `carry-on cancel <session_id>` and
  globbing `~/.claude/carry-on/pending/*.json` both work as before.

suite: passed 201, failed 0

## 0.2.0 — the cap counts windows, not days

The resume cap counts per limit window rather than per calendar day. A session
brought back by hand retires its own pending. A session running as a background
agent is retired with a notice instead of retried.

Plus: pid identity before trust or signal, torn-file and non-numeric-config
guards on every counter and cap, a resume re-caught by a fresh limit left
alone, and no stdin handed to the resume child.

suite: passed 153, failed 0

## 0.1.x

Initial releases: `StopFailure`-hook catch, detached sleeper with probe-confirmed
wake, headless `--resume`, session-scoped statusline badge as a drop-in
fragment, chain caps with decay. See the git history.
