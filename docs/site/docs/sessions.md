# Sessions

`vrg-vm session` is the front door to the VM. It launches Claude Code with an
**explicitly named session** so you can close your terminal, reboot your laptop,
or rebuild the VM and pick up exactly where you left off — by naming the session
you want, never by hunting for session IDs.

This guide explains the model and shows the workflows: creating a named session,
reconnecting to one by name, running several agents at once, recovering after a
reboot, and starting clean without losing history.

## The mental model

The VM exists to sandbox Claude Code, so `vrg-vm session` **launches Claude by
default** — not a shell. Every session has a two-part name:

```text
<label>:<workspace-relative-path>
```

For example, working on epic #213 in `my-project`:

```text
epic-213-explicit-sessions:my-project
```

- **label** — the human, functional name for *what this session is for*. Bind it
  to a purpose: an epic (`epic-<N>-<slug>`) or an ad-hoc problem
  (`adhoc-<slug>`). The label is a clean slug; if it lacks an `epic-`/`adhoc-`
  prefix you get a **warning, not a rejection** — start with a bare slug and
  rename once the epic number exists.
- **workspace path** — the repo you started in, relative to your projects root.
  It anchors the session's `CLAUDE.md`/memory bootstrap and tells you *where* you
  are.

The name shows up in Claude's UI, so at a glance you know what each window is for
and which repo it belongs to.

!!! note "Reconnect is by exact name"
    You address a session **explicitly by its name** — there is no auto-resume
    guess, no slot number, and no "most recent" default. Because the system never
    guesses which session you meant, it can never guess *wrong*.

A session is in one of two states:

| State | Meaning |
|---|---|
| **active** | a live Claude client is attached right now |
| **idle** | the session exists (its transcript is on disk) but nothing is attached |

There is no "archived" state. Every transcript stays on disk and stays
reconnectable by its exact name; long-idle sessions are simply **hidden from the
default listing** by a recency filter (see [Listing and
reconnecting](#listing-and-reconnecting)), never moved or relabeled.

## Two verbs: create and attach

Creating a new session and reconnecting to an existing one are **distinct verbs**,
which makes both typo-safe:

| Verb | Flag | Rule |
|---|---|---|
| **Create** | `--label <name>` | the name **must not already exist** |
| **Attach** | `--resume <name>` | the name **must already exist** |

### Create a named session

```bash
vrg-vm session --label epic-213-explicit-sessions my-project
```

This launches a new session named `epic-213-explicit-sessions:my-project`. The
**workspace argument is required** on create — it's the repo, relative to your
projects root, that the session bootstraps from (its `CLAUDE.md`). Tab-complete it
from your projects directory; use `.` to start at the projects root.

If a **visible session already holds that name**, create **errors** rather than
silently shadowing it — it points you to `--resume` the existing one or pick
another label. A label with a non-`epic-`/`adhoc-` prefix only **warns**; a
structurally invalid slug (empty, or containing a `:` or whitespace) is rejected.

### Attach to an existing session

```bash
vrg-vm session --resume epic-213-explicit-sessions:my-project
```

`--resume` resolves the **exact name** to its session and reconnects. It does not
take a workspace argument — the workspace (and the memory slug that follows from
it) is **derived from the resolved session**, so a resumed session always keeps
its original repo context.

Reconnect is deliberately strict:

- A name that resolves to **no visible session errors** ("no session named X —
  create it with `--label`") instead of spawning an empty session.
- A name that somehow resolves to **two co-equal live sessions fails loud** — it
  never silently picks one.

### No verb: list and guide

Running `vrg-vm session <workspace>` with **neither verb** does not launch
anything. It lists the workspace's sessions, most-recent first, and names the two
verbs:

```text
Sessions for this workspace (most recent first):
  * epic-213-explicit-sessions:my-project
    adhoc-triage-flake:my-project

Name the session you want — choose one verb:
  --label <label>   start a new session named <label>:<workspace>
  --resume <name>   attach to an existing session by its exact name
```

(`*` marks an active session.) This replaces the old bare-command auto-resume: the
command now guides you to name what you want rather than guessing.

## Choosing the model

Set the model per session, or configure a default so you never type it:

```bash
vrg-vm session --label epic-213-x --model opus my-project
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

Give each agent its own purpose-named session — that is all it takes to run
several against the same repo at once:

```bash
vrg-vm session --label epic-213-frontend my-project
vrg-vm session --label adhoc-triage-flake my-project
```

Two windows, two distinct names, two independent transcripts. Reconnect to
either by its exact name; there is no slot to track.

## Listing and reconnecting

```bash
vrg-vm list --sessions
```

```text
NAME                                    STATE     LAST ACTIVE
──────────────────────────────────────  ───────── ────────────
adhoc-triage-flake:my-project           active    2h
epic-213-explicit-sessions:my-project   idle      3d
```

It enumerates sessions across all your identity VMs, with how long since each was
active. By default it shows only sessions active within **`session_recent_days`**
(default **7**); older sessions are hidden from the listing but still exist and
still reconnect by exact name. Filter and widen:

| Flag | Shows |
|---|---|
| *(default)* | active + idle, within `session_recent_days` |
| `--active` / `--idle` | just that state |
| `--all` | every session regardless of age |

```toml
session_recent_days = 7   # display window for `list --sessions` (default 7)
```

`session_recent_days` cascades like `model` (identity → top-level → built-in) and
must be at least 1. It is a **pure display filter** — nothing is moved, renamed,
or aged out of existence; `--all` simply drops the window.

This is the recovery tool. After closing a terminal, rebooting, or a
`vrg-vm rebuild`, your sessions are still there — transcripts persist on the host
and survive VM rebuilds — so you can see what exists and reconnect deliberately by
name.

!!! note "A legacy name still resolves"
    A session created under the old `identity:slot:workspace` scheme (or one
    carrying an old `archived@…` marker) renders as an **opaque string** and still
    reconnects by its exact name. The old naming behavior is gone, but nothing
    stops resolving.

## Starting fresh on purpose

```bash
vrg-vm session --fresh --label epic-213-x my-project
```

`--fresh` pairs with `--label`. If a visible session already holds that name, it
is **retired via a supported rename** — renamed to `<name>~<timestamp>` — and a
brand-new session is created under the clean name. The retired session **keeps its
full history** and stays reconnectable by its suffixed name; nothing is ever
deleted. Use it whenever you want a clean slate under a name you're already using.

Because retiring is a rename (never a deletion), old transcripts remain a record
of *how* decisions were reached — a navigable history keyed by purpose. "Never
delete" is the point, not hoarding.

## The fork guardrail

Claude Code has no session locking — resuming the same session in two terminals
silently interleaves both conversations into one transcript. So the wrapper
**refuses to attach a second live client to an active session**. That's a safety
feature, not a limitation.

When you want to branch off a busy session, fork it — this maps to Claude's
supported `--fork-session`, giving you an independent copy to experiment in
without disturbing the original:

```bash
vrg-vm session --fork my-project
```

## `/clear` vs. a fresh session

Claude's in-session `/clear` resets the *active context* but the conversation
history stays attached to the session and can be pulled back in. A **fresh
session** is a stronger guarantee: a brand-new session with zero prior history.

- Use **`/clear`** to free up context mid-task while staying in the same session.
- Use **`--fresh --label`** for a genuine clean slate — new history, with the old
  session retired (renamed, never deleted).

## Renaming a session

Rename a session you're **in** with Claude's supported `/rename` — the natural way
to promote a bare `adhoc-<slug>` to `epic-<N>-<slug>` once the epic number exists.

## Escape hatches

Run something other than Claude with a `--` override:

```bash
vrg-vm session my-project -- bash                 # a shell in the VM
vrg-vm session --label epic-213-x my-project -- claude --model opus  # extra Claude flags
```

A non-`claude` command (like `bash`) runs raw. A `claude` override still goes
through the naming/resume logic, with your extra flags appended.

## Examples at a glance

```bash
# Create a purpose-named session
vrg-vm session --label epic-213-explicit-sessions my-project

# A second agent on the same repo, under its own name
vrg-vm session --label adhoc-triage-flake my-project

# See everything and reconnect after a reboot
vrg-vm list --sessions
vrg-vm session --resume epic-213-explicit-sessions:my-project

# Reveal sessions older than the recency window
vrg-vm list --sessions --all

# Clean slate under a name you're already using (old one retired, never deleted)
vrg-vm session --fresh --label epic-213-explicit-sessions my-project

# Fork a busy session to experiment without disturbing it
vrg-vm session --fork my-project

# Pick the model
vrg-vm session --label epic-213-x --model opus my-project

# Escape hatch: a raw shell
vrg-vm session my-project -- bash
```

## See also

- [Getting Started](getting-started.md) — configure an identity and create the VM
- [Troubleshooting](operations/troubleshooting.md) — when a session won't start
