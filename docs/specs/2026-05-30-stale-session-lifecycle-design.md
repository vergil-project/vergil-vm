# Stale-Session Lifecycle Design

> **⚠️ SUPERSEDED by epic [vergil-project/.github#230 — Explicit, purpose-named
> sessions](https://github.com/vergil-project/.github/issues/230).**
>
> The entire staleness/archive apparatus this design introduced — the
> `archived@` marker, the fresh/warn/stale age bands, auto-archiving, and the
> `session_stale_days` / `session_archive_days` thresholds — has been
> **deleted**. It existed only to protect the auto-resume-most-recent guess;
> making reconnect explicit by exact name removed the guess and with it the need
> for the apparatus. Staleness is now a pure **recency display-filter** on
> `list --sessions` (`session_recent_days`, default 7), and `--fresh` retires a
> prior same-named session via a supported rename (never deletes). Retained here
> as **historical record** — see [`sessions.md`](../site/docs/sessions.md) for
> the current model.

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
- **idle/archived:** the timestamp of the last **timestamped** entry in the
  transcript, found by **tail-reading** (seek to end, read backward in chunks) —
  O(1)-ish regardless of file size, since age is computed on every launch (sweep
  + selection) and every `list`. `agent-name` entries carry **no** `timestamp`,
  so the scan skips back past them (and past our own archive relabel) to the last
  real activity. File mtime is a last-resort fallback only if no timestamped
  entry exists at all — mtime alone is **not** trusted, because the projects dir
  is a virtiofs-backed symlink whose mtimes have proven unreliable here.

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

Two thresholds split idle sessions into three age bands (age = last-active):

| Band | Age | Behavior |
|---|---|---|
| **fresh** | `< session_stale_days` (default 7) | silent resume |
| **warn** | `session_stale_days ≤ age < session_archive_days` | warn + prompt |
| **stale** | `≥ session_archive_days` (default 14) | auto-archive, dropped from candidates |

**Connection-time flow** (resolver, after building this repo+identity's slots):

1. **Auto-archive sweep.** Relabel-archive every **cold** idle slot for *this*
   repo+identity in the **stale** band, printing one note each:
   `auto-archiving slot 03 (idle 24 days)…`. Strictly scoped to the target
   repo+identity; never touches other repos or any slot with a live client.
2. **Select** among what remains, ordered most-recently-active first:
   - latest idle in **fresh** band → resume silently;
   - latest idle in **warn** band → warn + prompt (interactive only):
     ```
     Slot 02 for vergil-project/vergil-vm was last active 9 days ago.
     [r]esume / [f]resh / [c]ancel?
     ```
   - nothing left (all swept, or none existed) → create the lowest free slot.

Notes:

- **Most-recent, not lowest-numbered.** The idle pick is ordered by last-active
  descending — you resume your latest work; the slot *number* is just an id.
- **A long absence starts fresh.** If even your most-recent session is in the
  stale band it auto-archives and you start fresh, no prompt (long gap = clean
  slate by default).
- **Non-interactive / no TTY** (scripted): the sweep still runs (it's a note, not
  a prompt), but the warn band does **not** prompt — it resumes (non-destructive
  default) unless `--fresh`/`--slot` was given. Scripts stay deterministic.
- **Explicit `--slot N`**: surgical — **no auto-archive sweep and no prompt**;
  resume or create exactly that slot.
- **Off switch.** `session_archive_days = 0` disables the sweep (warn-only).
- **Known behavior (accepted):** resuming a warn-band session and exiting without
  doing anything writes no new timestamped entry, so the session stays in the
  warn band and prompts again next launch. Rare and harmless; we accept it rather
  than add a "touch on resume" mechanism.

## `--fresh` and archive-via-relabel

`--fresh` (or choosing `[f]resh` at the stale prompt) on target slot
`vergil:01:<repo>`:

1. Confirm the slot's session is **cold** (no live roster entry) — guaranteed no
   concurrent writer to its transcript.

   > **Cold-safety invariant.** "Cold" is judged from the *local* VM roster, which
   > is sound only because a session name is `<identity>:…` and each identity maps
   > to exactly one `vm_instance` — so `vergil:01:<repo>` can only ever be live in
   > the vergil VM, which is where this resolver runs. If that 1:1 identity↔VM
   > mapping ever changes (e.g. sharing a VM across identities), this check must be
   > revisited before any relabel, or we could rewrite a live transcript.
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

**Archived-name recognition (corrected — verified 2026-05-30).** `parse_name`
does **not** naturally reject the `archived@…` form. The archived label embeds an
ISO timestamp (colons in `14:23:07`) and the original name (`:NN:`), both of
which collide with the `:` delimiter, so `parse_name` mis-parses an archived
label into a bogus active slot (e.g. slot 23). Therefore:

- `parse_name` **must explicitly return `None` for any name starting with the
  `archived@` prefix, before the `:`-split.** Exclusion must not rely on the
  strict format or on an identity mismatch.
- A separate `parse_archived(name) -> (timestamp, original_name)` helper feeds
  the archived listing. It splits with `name.split("@", 2)` →
  `["archived", "<timestamp>", "<original-name>"]`, which stays robust even if a
  workspace path itself contains `@` (the ISO timestamp has none, and the
  original name is just the remainder).

With prefix-first detection the rest of the label is opaque to the slot parser,
so the timestamp format is free; keep the readable ISO form
(`archived@2026-05-30T14:23:07Z@<original-name>`).

**Empirical check (DONE — 2026-05-30, in-VM against v2.0.76).** Confirmed:
(1) Claude resolves the current name as the **last** `agent-name` (live roster
`name` == last transcript `agent-name`); (2) appending an `agent-name` line is
safe and our `_last_agent_name`/`name_by_session` honor last-wins;
(3) after relabel, `build_slots` frees the active name. The mis-parse above was
the one correction surfaced.

**Fallback.** If a future Claude version ever rejects externally-appended
`agent-name` entries, fall back to a **sidecar archive manifest** (a separate
file listing archived session ids that the resolver excludes from active
resolution) — same behavior, archive state tracked out-of-band instead of in the
transcript.

## `vrg-vm list --sessions`

- **Default:** active + idle only (archives are noise).
- **Columns:** `IDENTITY · SLOT · WORKSPACE · STATE · LAST ACTIVE`.
- **Filters:** `--active`, `--idle`, `--archived`, `--all`. The archived view
  shows the original name, archived timestamp, and age, and a session is
  resumable from there by id.

## Configuration

Two keys in `identities.toml`, cascading exactly like `model` / `vergil`
(per-identity → top-level → built-in default):

```toml
session_stale_days   = 7    # warn above this (default 7)
session_archive_days = 14   # auto-archive above this (default 14; 0 disables)

[identities.vergil]
# session_stale_days   = 3
# session_archive_days = 30
```

Validation: `session_archive_days` must be `0` (disabled) or strictly greater
than `session_stale_days`.

## Architecture / touchpoints

All in vergil-tooling (the resolver and command surface from the naming work);
pure logic stays in `lib/session.py`, thin mockable I/O in the resolver.

- **`lib/session.py`** — `parse_name` gains an explicit `archived@`-prefix guard
  (return `None` before the `:`-split) plus a `parse_archived` helper; add an
  `archived` classification and a `last_active`/age field on slots; `list_rows`
  gains state filtering; `select()` learns the three age bands, the
  most-recently-active idle ordering, the auto-archive sweep decision (which cold
  idle slots are in the stale band), and the `--fresh` path (archive-then-create
  decision).
- **`bin/vrg_vm_resolve.py`** — read transcript timestamps for age; implement the
  relabel-append (archive); the TTY-gated stale prompt; emit age + state in
  `--list-json`.
- **`bin/vrg_vm.py`** — `--fresh` flag; `list --sessions` filter flags
  (`--active/--idle/--archived/--all`) and the age/state columns; plumb
  `session_stale_days` (with a `resolve_*` helper like `resolve_model`).
- **`lib/identity.py`** — `session_stale_days` and `session_archive_days` on
  `Identity` + `IdentityConfig`, parsed top-level and per-identity, with
  `resolve_session_stale_days` / `resolve_session_archive_days` and validation
  (`archive_days == 0` or `> stale_days`).

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
