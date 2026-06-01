# Sessions

`vrg-vm session` is the front door to the VM. It launches Claude Code with a
**deterministic, named session** so you can close your terminal, reboot your
laptop, or rebuild the VM and pick up exactly where you left off — without
hunting for session IDs.

This guide explains the model and shows the workflows: resuming, running several
agents at once, recovering after a reboot, and keeping old context from polluting
new work.

## The mental model

The VM exists to sandbox Claude Code, so `vrg-vm session` **launches Claude by
default** — not a shell. Every session gets a structured name:

```text
<identity>:<slot>:<workspace-relative-path>
```

For example, working in `my-project` as the `vergil` identity:

```text
vergil:01:my-project
```

- **identity** — which identity you're running as (the `--identity`, or your
  `default_identity`). It tells you *who* you are in this window.
- **slot** — a two-digit number (`01`–`99`) distinguishing multiple concurrent
  sessions for the same identity and workspace.
- **workspace path** — the repo you started in, relative to your projects root.
  It tells you *where* you are.

The name shows up in Claude's UI, so at a glance you know which identity and repo
each window belongs to.

A session is in one of three states:

| State | Meaning |
|---|---|
| **active** | a live Claude client is attached right now |
| **idle** | the session exists (its transcript is on disk) but nothing is attached |
| **archived** | set aside, out of the active namespace, but preserved and reconnectable |

## Everyday use

```bash
vrg-vm session my-project
```

The **workspace argument is required** — it's the repo, relative to your projects
root, that the session bootstraps from (its `CLAUDE.md`). Tab-complete it from
your projects directory. Use `.` to start at the projects root.

Re-running the same command **resumes your most recent session** for that repo,
or starts a fresh one if none exists. "Pick up where I left off" is just running
the command again — no flags, no session hunting.

!!! note "Most-recent, not lowest-numbered"
    If you have several sessions for a repo, the default resumes the one you
    used **most recently**, not the lowest slot number. The slot number is just
    an identifier.

## Choosing the model

Set the model per session, or configure a default so you never type it:

```bash
vrg-vm session --model opus my-project
```

In `identities.toml`, `model` cascades (CLI flag → identity → top-level default):

```toml
model = "opus"                # ecosystem default for every identity

[identities.vergil]
# model = "claude-opus-4-8"   # optional per-identity override / pin
```

The value passes straight to Claude's `--model`, so an alias (`opus`) or a pinned
id (`claude-opus-4-8`) both work.

## Running several agents on one repo

Slots let you run more than one agent against the same identity + repo — say two
windows on separate patches. Just run the command again; if your current session
is busy, the next invocation starts a new slot automatically:

```bash
vrg-vm session my-project        # slot 01
vrg-vm session my-project        # slot 02 (01 is busy)
```

Target a specific slot explicitly:

```bash
vrg-vm session --slot 02 my-project
```

An explicit `--slot` is surgical: it resumes (or creates) exactly that slot, with
no staleness prompt and no auto-archiving of siblings.

## Listing and reconnecting

```bash
vrg-vm list --sessions
```

```text
IDENTITY         SLOT   WORKSPACE                            STATE     LAST ACTIVE
──────────────── ────── ──────────────────────────────────── ───────── ────────────
vergil           01     my-project                           active    2h
vergil           02     vergil-project/vergil-tooling        idle      3d
```

It enumerates sessions across all your identity VMs, with how long since each was
active. Filter by state:

| Flag | Shows |
|---|---|
| *(default)* | active + idle |
| `--active` / `--idle` | just that state |
| `--archived` | archived sessions (original name, archived time, age) |
| `--all` | everything, including archived |

This is the recovery tool. After closing a terminal, rebooting, or a
`vrg-vm rebuild`, your sessions are still there — transcripts persist on the host
and survive VM rebuilds — so you can see what existed and reconnect deliberately.

## Staleness: keeping old context out of new work

Resuming a long-idle session drags weeks-old context back into the model, and
stale context quietly pollutes current work — the model can't reliably tell which
of its own context is out of date. So sessions age through three bands, governed
by two configurable thresholds:

| Band | Age (idle) | What happens |
|---|---|---|
| **fresh** | `< session_stale_days` (default **7**) | silently resumed |
| **warn** | 7–14 days | you're prompted |
| **stale** | `≥ session_archive_days` (default **14**) | auto-archived, you start fresh |

In the **warn** band you get a prompt:

```text
Slot 02 for my-project was last active 9 days ago.
[r]esume / [f]resh / [c]ancel?
```

In the **stale** band, the session is auto-archived at connection time (with a
note) and you start clean — so you're never nagged about ancient sessions you've
clearly abandoned, and a long enough absence simply gives you a clean slate.

```toml
session_stale_days   = 7    # warn above this
session_archive_days = 14   # auto-archive above this (0 disables)
```

Both cascade like `model` (identity → top-level → built-in). Set
`session_archive_days = 0` to turn auto-archiving off entirely.

!!! note "Two different staleness thresholds"
    **VM** staleness (default 3 days) prompts you to *rebuild the VM*.
    **Session** staleness (7/14 days) governs *resuming a conversation*. They're
    unrelated.

### Starting fresh on purpose

```bash
vrg-vm session --fresh my-project
```

`--fresh` archives the current session for that slot and starts a brand-new one
under the same name. Use it whenever you want a clean slate without waiting for
the staleness threshold.

### Archived, never deleted

Archiving never throws anything away. The old conversation is preserved and
relabeled out of the active namespace; you can find it with
`vrg-vm list --sessions --archived` and reconnect to it. Old transcripts are a
record of *how* decisions were reached, so they're kept, not pruned.

## The fork guardrail

Claude Code has no session locking — resuming the same session in two terminals
silently interleaves both conversations into one transcript. So the wrapper
refuses to attach a second live client to an active session. That's a safety
feature, not a limitation.

When you want to branch off a busy session, fork it into a new slot:

```bash
vrg-vm session --slot 01 --fork my-project
```

## `/clear` vs. a fresh session

Claude's in-session `/clear` resets the *active context* but the conversation
history stays attached to the session and can be pulled back in. A **fresh
session** is a stronger guarantee: a brand-new session with zero prior history.

- Use **`/clear`** to free up context mid-task while staying in the same session.
- Use **`--fresh`** (or accept the stale prompt's `[f]resh`) for a genuine clean
  slate — new history, old one archived.

## Escape hatches

Run something other than Claude with a `--` override:

```bash
vrg-vm session my-project -- bash               # a shell in the VM
vrg-vm session my-project -- claude --model opus  # extra Claude flags
```

A non-`claude` command (like `bash`) runs raw. A `claude` override still goes
through the naming/resume logic, with your extra flags appended.

## Examples at a glance

```bash
# Start or resume your most-recent session for a repo
vrg-vm session my-project

# A second agent on the same repo
vrg-vm session my-project

# See everything and reconnect after a reboot
vrg-vm list --sessions
vrg-vm session --slot 02 my-project

# Browse and reconnect to archived sessions
vrg-vm list --sessions --archived

# Clean slate, archiving the old session
vrg-vm session --fresh my-project

# Fork a busy session to experiment without disturbing it
vrg-vm session --slot 01 --fork my-project

# Pick the model
vrg-vm session --model opus my-project

# Escape hatch: a raw shell
vrg-vm session my-project -- bash
```

## See also

- [Getting Started](getting-started.md) — configure an identity and create the VM
- [Troubleshooting](operations/troubleshooting.md) — when a session won't start
