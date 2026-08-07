# Deterministic Session Naming Design

> **⚠️ SUPERSEDED by epic [vergil-project/.github#230 — Explicit, purpose-named
> sessions](https://github.com/vergil-project/.github/issues/230).**
>
> This design's `identity:slot:workspace` naming, `--slot` selection, and
> auto-resume-most-recent default have all been **replaced**. Sessions are now
> named `label:workspace` (identity dropped); creation is explicit
> (`--label`), reconnect is by exact name (`--resume`), and `--slot` /
> auto-resume are removed. Retained here as **historical record** — see
> [`sessions.md`](../site/docs/sessions.md) for the current model.

**Issues:**
- [vergil-vm #73 — Deterministic session naming from identity and project path](https://github.com/vergil-project/vergil-vm/issues/73)
- [vergil-tooling #1292 — vrg-vm session: default command to claude, identity to vergil](https://github.com/vergil-project/vergil-tooling/issues/1292)

**Date:** 2026-05-29

**Status:** Design **finalized**. The prerequisite mount fixes have landed and
session-state detection was re-inspected live in the corrected environment
(2026-05-29, post-rebuild); all open items are resolved. Ready to implement
(plan-of-work step 5).

## Problem

`vrg-vm session <workspace>` currently drops you into a `bash --login` shell
inside the VM. Two gaps follow from that:

1. **Wrong default.** The VM exists to sandbox Claude Code. Defaulting to a
   shell invites "looking under the covers" instead of doing the intended
   work. The right action should be the default.
2. **No session continuity or visual identity.** There is no deterministic
   session name, so restarting the wrapper cannot automatically resume where
   you left off, and nothing on screen tells you *who* you are (which
   identity) or *where* you are (which repo) in a given Claude window.

We also want to support the real workflow of running **more than one** Claude
agent against the same identity and repo at once (e.g. two windows cranking on
separate small patches in the same repo).

## Goals

- `vrg-vm session <workspace>` launches Claude Code by default.
- Each session gets a **deterministic, structured name** encoding identity,
  a numbered slot, and the project-relative path.
- Re-running the same command **automatically resumes** the right session, or
  creates the next one, without manual `/rename` or session hunting.
- Support **multiple concurrent slots** per identity+repo, addressed by number.
- Never silently corrupt a session by attaching two live clients to it.
- Provide a way to **list** existing sessions for reconnection and recovery
  (e.g. after a host reboot).

## Naming scheme

```
<identity>:<slot>:<workspace-relative-path>
```

Examples:

```
vergil-user:01:vergil-project/vergil-tooling
vergil-user:02:vergil-project/vergil-tooling
vergil-admin:01:vergil-project/vergil-actions
```

- **Delimiter:** colon (`:`). Colons do not appear in identity names or in
  workspace paths, so the three fields parse unambiguously even though dashes
  and slashes are common inside the fields themselves.
- **`<identity>`:** the resolved identity name — the value of `--identity`, or
  `default_identity` from `identities.toml`. Treated as an opaque string. The
  forthcoming user/admin/audit identity split (separate vergil-tooling design)
  simply produces different identity strings here; this design needs no
  knowledge of identity *modes*.
- **`<slot>`:** a zero-padded two-digit number starting at `01`
  (`01`–`99`). Distinguishes multiple concurrent sessions for the same
  identity + workspace.
- **`<workspace-relative-path>`:** the workspace argument resolved relative to
  the identity's `projects_dir`. Slashes are preserved
  (e.g. `clients/acme`).

The name is set with Claude Code's `-n/--name` flag on creation and is stored
inside the conversation transcript as an `agent-name` entry; it is a pure
label, independent of Claude's actual working directory.

## Command surface

`vrg-vm session` (implemented in `vrg_vm.py`, vergil-tooling) changes as
follows:

- **`<workspace>` becomes required.** You must say where, relative to your
  project root, you want to start. The recommended workflow is to `cd` into
  your projects root on the host and tab-complete the workspace argument. This
  preserves the deliberate affinity between a Claude session and the repo it
  bootstraps from (the repo's `CLAUDE.md`), while still allowing the agent to
  read and operate across the other mounted repos. Use `.` to start at the
  projects root explicitly (its path component is then `.`); this is allowed
  but not the expected usage.
- **Default command becomes `claude`** (per #1292), launched with the
  deterministic name and resume logic below.
- **`--slot N`** selects an explicit slot (see selection rules).
- **`--fork`** forks a copy of the targeted slot's conversation
  (`claude --fork-session`) instead of resuming it — the escape hatch when a
  slot is active.
- **Explicit command override** is preserved:
  `vrg-vm session <ws> -- bash` for a shell,
  `vrg-vm session <ws> -- claude --model opus` to pass extra args to Claude.
- **`--identity`** remains optional, defaulting to `default_identity`.

### Slot selection rules

State of a slot is one of:

- **nonexistent** — no named session matches `<identity>:<NN>:<path>`.
- **idle** — the named session exists but no live client is attached.
- **active** — the named session exists and a live Claude client is currently
  attached to it.

**No `--slot` given (the common case):**

1. If one or more **idle** slots exist for this identity+path → **resume the
   lowest-numbered idle slot.**
2. Otherwise (no slots exist, or every existing slot is active) → **create the
   lowest free slot number** (`01` if none exist; `02` if `01` is active; etc.).

This makes the everyday "pick up where I left off" case a no-op resume, while
running the command again against a busy session automatically spawns the next
agent rather than colliding.

**`--slot N` given (explicit):**

- N nonexistent → **create** slot N.
- N idle → **resume** slot N.
- N active → **refuse with an error**, pointing the user at `--fork`. (See
  rationale.) `--slot 0` is rejected; slots start at `01`.

### Why refuse to attach to an active slot

Claude Code has **no session locking**. Per the official docs, resuming the
same session in two terminals causes messages from both to *interleave into
one transcript* — silently. There is no takeover, no auto-fork, no warning.
Therefore the wrapper must be the guardrail: the default selection logic never
resumes an active slot, and an explicit `--slot N` targeting an active slot is
refused with a clear error and the `--fork` suggestion.

## Session-state detection

Detection runs **inside the VM**, against the VM-local session store the VM's
Claude actually uses. It joins two sources:

1. **Named-session map** — scan the conversation transcripts under
   `~/.claude/projects/*/*.jsonl` for the last `agent-name` entry per file.
   Each such entry has the shape
   `{"type":"agent-name","agentName":"<name>","sessionId":"<id>"}`; the last one
   in a file wins. This yields `name → sessionId` for every session that has a
   transcript (idle or active). Transcripts live in the shared, host-backed
   `projects` directory, so they survive rebuilds.
2. **Live roster** — read the **VM-local** `~/.claude/sessions/*.json`. Each
   file is named `<pid>.json` and records `pid`, `sessionId`, `cwd`, `status`
   (`idle`/`busy`), `procStart`, and the session `name`. Validate liveness
   against the process table (`ps`), using `procStart` to reject PID reuse.

Classification per candidate name:

- **active** — its `sessionId` has a roster file whose `pid` is live.
- **idle** — its `sessionId` has a transcript but no live roster entry (no
  roster file, or a stale one whose `pid` is dead).
- **nonexistent** — neither a transcript nor a roster entry.

> **Resolved (live re-inspection, 2026-05-29, post-rebuild).** The earlier open
> items are closed by keeping the roster **VM-local** (see Prerequisite):
>
> - **PID ambiguity — gone.** Every `pid` in a VM-local roster is owned by that
>   VM, so the in-VM `ps`/`procStart` liveness check is always valid.
> - **Filename collision — gone.** Each VM has its own `sessions` directory, so
>   no host and VM process can collide on the same `<pid>.json` filename.
> - **Platform tagging — unnecessary.** The host reads each identity VM's roster
>   over `limactl shell <vm> -- …` and runs the liveness check in that same
>   in-VM call, so ownership is implicit in which VM answered.
>
> Bonus confirmed live: the roster JSON already carries `name`, so
> active-session detection can read it straight from the roster. Transcript
> parsing remains required only for **idle** sessions, which have no roster
> file.

## Listing sessions

Add session listing to the existing VM-listing command rather than a new
near-homophone subcommand. `vrg-vm session` (launch, singular) and a
hypothetical `vrg-vm sessions` (list, plural) differ by one character and are
easy to typo into each other, so:

```
vrg-vm list --sessions
```

groups with the existing `vrg-vm list` (which lists VMs) and reads
unambiguously. It enumerates named sessions with identity, slot, workspace,
and active/idle state:

```
$ vrg-vm list --sessions
IDENTITY     SLOT  WORKSPACE                 STATE
vergil-user  01    vergil-project/vergil-vm  active
vergil-user  02    vergil-project/tooling    idle
vergil-admin 01    vergil-project/actions    idle
```

This directly serves environment recovery: after a host reboot or VM rebuild
you can see what existed and reconnect deliberately. (Scope detail to settle
in implementation: whether the listing covers only the current/target VM or
queries all identity VMs.)

## Architecture

- **Host side** (`vrg_vm.py` `_cmd_session`): resolve identity, resolve the
  workspace path relative to `projects_dir`, parse `--slot`/`--fork`, then exec
  into the VM.
- **In-VM resolver** (shipped as part of vergil-tooling, which is already
  installed inside the VM): performs the session-state detection above, applies
  the slot-selection rules, and execs `claude` with either
  `-n <name>` (create) or `--resume <sessionId>` (resume) — resuming by
  session ID rather than by name search makes resolution deterministic. The
  resolver runs inside the VM because that is where the session store lives.

Two approaches were considered for the resolver: inline shell built on the
host side, versus a proper helper run inside the VM. The in-VM helper wins —
detection requires reading the VM's session store and process table, which are
only correct from inside the VM, and vergil-tooling is already present there.

## Prerequisite — `.claude` mount fix (DONE)

Discovered during design: the VM's Claude did **not** persist its session
history across `vrg-vm rebuild`, because the `.claude` subdirectories landed at
the wrong path. `lima.py` built the mounts on the **host** (`Path.home()` =
`/Users/pmoore`) with `mountPoint == location`, but inside the VM `HOME` is
`/home/pmoore.guest`, so the VM's Claude read/wrote its **own local**
`~/.claude` on the (ephemeral) VM disk.

**What shipped:**

- **`projects` and `skills` → symlinked** into the host-backed mounts
  (`~/.claude/projects -> /Users/pmoore/.claude/projects`, and likewise
  `skills`). Transcripts and skills are now shared and survive rebuilds.
  (vergil-tooling #1296 / released #1297.)
- **`sessions` → kept VM-local** — a real directory, **not** symlinked.
  (vergil-tooling #1301 / released #1302.) The launcher also self-heals a
  pre-existing `sessions` symlink left by #1296.

**Why `sessions` is deliberately *not* shared:** Claude writes the live roster
atomically — a temp file in VM-local `/tmp` followed by `rename()` onto the
target. With `sessions/` symlinked onto the virtiofs mount that became a
cross-filesystem rename and failed with `EXDEV (Invalid cross-device link)` —
silently, leaving **no roster file at all**. Transcripts are unaffected because
they are append writes, not atomic renames. Keeping `sessions` VM-local makes
the roster write succeed and, as a bonus, gives detection a clean per-VM
ownership model (see Session-state detection). Verified live post-rebuild: the
running session's `sessions/<pid>.json` is present and well-formed.

Path preservation of the **projects code mount** (`/Users/pmoore/dev/projects`)
is correct and unaffected — transcript directory slugs encode the
path-preserved `cwd`, so they line up between host and VM regardless.

> Incidental: the first post-fix rebuild also surfaced an unrelated
> `systemd-logind` 100% CPU busy-loop that wedged provisioning (vergil-vm #74);
> it was fixed in the agent template (`mode: boot` logind drop-in) before this
> work could be verified live.

## Plan of work (sequenced)

1. ✅ **Commit this design.**
2. ✅ **Fix the mounts** (vergil-tooling #1296/#1297, #1301/#1302): `projects`
   and `skills` symlinked to the shared host store; `sessions` kept VM-local.
3. ✅ **Rebuild and re-inspect session-state detection live** — done
   2026-05-29 in the corrected environment.
4. ✅ **Finalize the detection mechanism** (this revision): open items
   resolved; roster confirmed to carry `name`, `agent-name` entry shape
   confirmed.
5. ⏳ **Implement** the command-surface and resolver changes (#1292 + #73) in
   vergil-tooling, plus `vrg-vm list --sessions`.

## Scope boundaries

- **In scope:** default-to-`claude`, required workspace arg, deterministic
  naming, slot selection + `--slot`/`--fork`, session-state detection,
  `vrg-vm list --sessions`, and the prerequisite mount fix.
- **Out of scope:** the user/admin/audit identity-mode design (separate
  vergil-tooling work); stale-session expiry/garbage-collection policy
  (possible later follow-up).

## Repositories affected

| Repository | Change |
|---|---|
| vergil-tooling | `vrg_vm.py` (`session` default + slot logic), in-VM resolver, `lima.py` mount fix, `list --sessions` |
| vergil-vm | This design doc; any provisioning needed so the in-VM resolver is available |
