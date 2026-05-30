# Stale-Session Lifecycle Design

**Issues:**
- [vergil-vm #82 — Design: stale-session lifecycle for vrg-vm session](https://github.com/vergil-project/vergil-vm/issues/82)
- [vergil-tooling #1323 — Stale-session lifecycle: --fresh, age-based resume cutoff, and pruning](https://github.com/vergil-project/vergil-tooling/issues/1323)

**Date:** 2026-05-30

**Status:** Design approved; ready for implementation planning.

**Builds on:** [Deterministic session naming](./2026-05-29-deterministic-session-naming-design.md)
(vergil-tooling #1309, merged). That work made sessions named, persistent, and
auto-resuming. This design addresses what happens to them **over time**.

## Problem

The auto-resume convenience has a sharp edge. Two problems:

1. **Stale-context pollution.** Re-running `vrg-vm session <repo>` resumes the
   lowest idle slot — even if that session was last touched weeks ago. The model
   then reasons from old, possibly superseded context, and an LLM is poor at
   recognizing its own context as out of date. For unrelated new work a clean
   start is usually better; today the default silently does the opposite.
2. **Unbounded accumulation.** Transcripts persist forever; nothing surfaces a
   session's age or reclaims a name.

Reconnecting typically follows an event — laptop reboot, VM rebuild — which is
exactly when treating the VM as ephemeral is most valuable, and exactly when
silently resuming an old thread is least wanted.

## Goals

- Make session **age visible** and let staleness gate auto-resume.
- Give a first-class **fresh start** that reclaims a name without losing history.
- **Archive, never delete.** Old transcripts are a goldmine (the *journey* to a
  decision, not just the decision) and will feed a future Mem Palace
  integration. No transcript is ever removed in this iteration.

## Non-goals (deferred)

- Pruning / expiry / garbage collection of any kind.
- A manual archive verb (`--archive`). Archiving is only a side-effect of
  `--fresh` / the stale prompt. Add later only if a need appears.
- Mem Palace indexing of the archive.

Deferring cleanup is deliberate: disk is cheap relative to the value of the data,
and pruning policy is a harder problem best informed by the Mem Palace work.

## Background: how naming and "rename" actually work

(Confirmed by inspecting live transcripts.)

- A transcript is `~/.claude/projects/<slug>/<sessionId>.jsonl`; the filename is
  the session id.
- The **name lives inside the transcript** as append-only entries:
  `{"type":"agent-name","agentName":"<name>","sessionId":"<id>"}`. **Last one
  wins.**
- The live roster is VM-local `~/.claude/sessions/<pid>.json`
  (`pid`, `sessionId`, `cwd`, `status`, `procStart`, `name`, `updatedAt`).

So a Claude `/rename` is nothing more than **appending one `agent-name` line**.
The session id never changes. This is the mechanism the archive design relies on.

## Session states

- **active** — a live roster entry whose `pid` is alive.
- **idle** — a transcript exists, no live client attached.
- **archived** — a transcript whose current name carries the `archived@` marker
  (see below). Excluded from active name resolution.

### Age ("last active")

- **active:** the roster's `updatedAt`.
- **idle/archived:** the **timestamp of the last entry in the transcript**, with
  the file mtime as a fallback if no timestamp is present.

## `/clear` vs. fresh — why this operates at the session level

Claude's `/clear` resets the *active context* but does **not** delete the
transcript; the history persists and can be pulled back (by resume or search).
A fresh session is a stronger guarantee: a **new session id with zero attached
history**. This feature therefore operates at the session level rather than
leaning on `/clear`.

| | Effect | History |
|---|---|---|
| `/clear` (Claude, in-session) | resets working context | stays with the session, reachable |
| `--fresh` (this design) | new session id, reclaims the name | old session **archived**, not deleted |

## Default launch behavior — `vrg-vm session <repo>`

1. Resolve the lowest idle slot (unchanged from naming design).
2. If its last-active age is **within `session_stale_days`** → resume silently.
3. If it is **older than the threshold** → warn and prompt (interactive only):

   ```
   Slot 01 for vergil-project/vergil-vm was last active 12 days ago.
   [r]esume / [f]resh / [c]ancel?
   ```

- **Non-interactive / no TTY** (scripted): do **not** prompt — resume (the
  non-destructive default) unless `--fresh` or `--slot` was given explicitly.
  Staleness protection is an interactive affordance; scripts stay deterministic.
- **Explicit `--slot N`**: deliberate intent → **no stale prompt**. The prompt
  only guards the automatic lowest-idle pick.

## `--fresh` and archive-via-relabel

`--fresh` (or choosing `[f]resh` at the stale prompt) on target slot
`vergil:01:<repo>`:

1. Confirm the slot's session is **cold** (no live roster entry) — guaranteed no
   concurrent writer to its transcript.
2. **Append one `agent-name` entry** to that transcript, relabeling it:
   ```
   archived@2026-05-30T14:23:07Z@vergil:01:vergil-project/vergil-vm
   ```
   Full second-resolution UTC timestamp so repeated `--fresh` on the same slot
   never collides. The original name is embedded for display.
3. The active name `vergil:01:<repo>` is now unclaimed → create a new session
   with `-n vergil:01:<repo>` (fresh id, zero history).

Nothing is deleted; the old conversation stays searchable and resumable by id.
This is exactly what Claude's `/rename` does (append an `agent-name` line),
applied to a cold transcript.

**Archived-name recognition.** The strict slot parser (`<id>:<NN>:<path>`)
naturally rejects the `archived@…` form, so archived sessions are excluded from
active/idle slot resolution. The resolver detects the `archived@` prefix
explicitly to route them to the archived listing.

**Empirical pre-check (before implementation):** confirm Claude Code tolerates an
externally-appended `agent-name` entry and honors last-wins on resume. Expected
to pass (same entry type Claude writes); verify against a throwaway transcript
copy in the VM.

## `vrg-vm list --sessions`

- **Default:** active + idle only (archives are noise).
- **Columns:** `IDENTITY · SLOT · WORKSPACE · STATE · LAST ACTIVE`.
- **Filters:** `--active`, `--idle`, `--archived`, `--all`. The archived view
  shows the original name, archived timestamp, and age, and a session is
  resumable from there by id.

## Configuration

New key in `identities.toml`, cascading exactly like `model` / `vergil`:

```toml
session_stale_days = 7          # ecosystem default

[identities.vergil]
# session_stale_days = 14       # optional per-identity override
```

Resolution: per-identity → top-level → built-in default **7**.

## Architecture / touchpoints

All in vergil-tooling (the resolver and command surface from the naming work);
pure logic stays in `lib/session.py`, thin mockable I/O in the resolver.

- **`lib/session.py`** — add an `archived` classification and a
  `last_active`/age field on slots; `list_rows` gains state filtering; `select()`
  learns the stale cutoff and the `--fresh` path (archive-then-create decision).
- **`bin/vrg_vm_resolve.py`** — read transcript timestamps for age; implement the
  relabel-append (archive); the TTY-gated stale prompt; emit age + state in
  `--list-json`.
- **`bin/vrg_vm.py`** — `--fresh` flag; `list --sessions` filter flags
  (`--active/--idle/--archived/--all`) and the age/state columns; plumb
  `session_stale_days` (with a `resolve_*` helper like `resolve_model`).
- **`lib/identity.py`** — `session_stale_days` on `Identity` + `IdentityConfig`,
  parsed top-level and per-identity, plus `resolve_session_stale_days`.

100% coverage retained; prompt/TTY and transcript-append paths factored as thin
I/O around pure, unit-tested logic.

## Scope boundaries

- **In scope:** age model, stale prompt + `session_stale_days`, `--fresh` with
  archive-via-relabel, `list --sessions` states/filters/age column.
- **Out of scope (named, not built):** pruning/expiry/GC, manual `--archive`
  verb, Mem Palace indexing — all enabled later by the fact that we archive
  rather than delete.

## Repositories affected

| Repository | Change |
|---|---|
| vergil-tooling | `session.py`, `vrg_vm_resolve.py`, `vrg_vm.py`, `identity.py` |
| vergil-vm | This design doc; docs-guide update (vergil-vm #81) |
