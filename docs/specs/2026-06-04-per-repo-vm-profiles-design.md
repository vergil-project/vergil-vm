# Multi-VM Identities: Per-Repo VM Profiles Design

**Issues:**
- [vergil-vm #99 — feat: per-repo VM profiles — build a VM from a consuming repo's spec](https://github.com/vergil-project/vergil-vm/issues/99)

**Date:** 2026-06-04

**Status:** Proposed (issue #99).

**Spans two repositories.** This feature touches both `vergil-vm` (the VM image
template and its tests) and `vergil-tooling` (the `vrg-vm` CLI, identity parsing,
Lima driver, and in-VM session resolver). Each touch-point below is tagged with
its owning repo. The design document lives in `vergil-vm` because that is where
issue #99 is filed.

**Relationship to the issue's "Fork B" sketch.** Issue #99 proposed hand-authored
`[vms.<name>]` profile tables in user config, selected with `--vm <name>`. This
design supersedes that sketch. It keeps the issue's core boundary — *requirements
in source control, credentials and selection in user config* — but removes the
invented profile name (and the name-collision problem the issue flagged as an open
question) by keying everything on the **real `org/repo` path the user already
types**, and by deriving the base-vs-dedicated decision from the *existence* of
config rather than a flag.

## Problem

Today a VM's footprint is a property of the **identity**. An `Identity` in
`~/.config/vergil/identities.toml` owns exactly one `vm_instance`, and
`vrg-vm create` builds that one box at `cpus`/`memory`/`disk` taken from the
identity. There is:

- **no way to drive multiple VM shapes from one identity** — same GitHub App
  credentials, different box; and
- **no mechanism to install additive packages** beyond the stripped Vergil base
  image.

The stripped-minimal base (4 CPU / 4 GiB / 50 GiB) is correct for everyday Claude
Code agent work — unit tests, integration tests, editing across many small repos.
But some repos need far more. The first real consumer,
`logical-minds-foundry/mq-cluster-tooling`, builds Vagrant-based, multi-network,
multi-VM "mini data centers" — nested VMs for an IBM MQ lab — and needs roughly
12 CPU / 64 GiB / 300 GiB plus QEMU/libvirt/Vagrant build dependencies. You cannot
hand-customize a live VM to get there without breaking the ephemeral, reproducible
guarantees the whole system rests on.

The identity model deliberately conflates *who* (credentials) with *what kind of
box*. This design splits them.

## Goals

- **One identity, many VMs.** The same credentials can drive a base VM plus any
  number of repo-specific VMs.
- **Requirements live in source control.** A repo declares the footprint and extra
  packages it needs in its own `vergil.toml`, cascaded by identity role.
- **Credentials and host-side tuning live in user config.** `identities.toml`
  holds GitHub App credentials, the base footprint, and rare per-host overrides —
  never secrets in the repo, never repo requirements in user config.
- **Deterministic selection, no guessing.** `(identity, org/repo)` maps to exactly
  one VM. The path you already `cd` to and type *is* the selector.
- **A loud drift signal.** `vrg-vm list` shows, per VM, whether it still matches
  its composed spec — `NEEDS-REBUILD` in all caps when it does not.
- **Observability.** `list` shows configured footprint and live occupancy split
  into `AGENTS` (harness instances) and `HUMANS` (interactive shells).
- **Ephemeral, data-less, reproducible — preserved.** Packages are *declared*,
  never `apt install`-ed into a live box. `rebuild` reproduces identically from
  the composed spec alone.

## Non-goals

- **Org-level VM specs.** Deferred — no current use case. The cascade *reserves*
  the org tier so it is non-breaking to add later. See Deferred work.
- **Host resource sanity-checking.** Verifying the Mac actually has the RAM/disk
  (and warning near capacity) is real but second/third-order. Reserved as future
  work, not built now.
- **Completing the identity namespace migration.** Retiring the legacy
  `vergil-agent` identity in favour of `vergil-user` / `vergil-audit` /
  `vergil-admin` is in-flight execution the maintainer drives separately. This
  design names the *destination* structure; it does not perform the migration.
- **Infra changes to `vergil-vm` itself running inside a profile VM.** The
  recursive-bootstrap caveat (#86) stands: changes to the VM image are made on the
  host, not from inside a profile VM.

## Terminology

- **Identity** — a role-qualified persona backed by GitHub App credentials a human
  acquired: `vergil-user`, `vergil-audit`, and eventually `vergil-admin`. The
  identity is the prefix for every VM it owns.
- **Base VM** — the minimal sandbox, one per identity. Today's behaviour. Hosts
  any repo that declares no special requirements.
- **Dedicated VM** — a per-`(identity, org, repo)` box built to a composed spec.
- **Agent** — a Claude Code (or other harness) instance: a named session as listed
  by `vrg-vm list --sessions`. Agents never get an interactive login; they are
  sandboxed to running the harness inside the VM.
- **Human** — an interactive login shell (`limactl shell` / SSH), used for
  debugging and triage. Only humans get full interactive access to the box.

## The model: two files, two cascades

### Repo `vergil.toml` — the requirement (source-controlled, cascades by role)

A repo that needs more than the base box declares it in a `[vm]` stanza of its own
`vergil.toml` (one place for all Vergil repo config — no separate spec file). The
stanza cascades by identity role:

```toml
# logical-minds-foundry/mq-cluster-tooling/vergil.toml
[vm]                              # applies to ANY identity that runs a VM here
packages = [
  "qemu-system-x86", "qemu-system-arm", "qemu-utils",
  "libvirt-daemon-system", "libvirt-clients", "bridge-utils",
  "dnsmasq-base", "genisoimage",
  "ruby-dev", "libvirt-dev", "pkg-config", "gcc", "make",
]
# Non-apt installs (HashiCorp repo for vagrant, then `vagrant plugin install
# vagrant-libvirt`) live in a source-controlled provisioning hook, not the apt
# list — see "Package & provisioning layering".
provision = ".vergil/provision.sh"

[vm.vergil-user]                  # role overlay: only vergil-user is tuned up
cpus   = 12
memory = "64GiB"
disk   = "300GiB"
```

The composed **repo-spec for identity `I`** = `[vm]` ⊕ `[vm.I]`. The repo author
controls *who gets a dedicated box* purely by **where** they place config:

- `[vm]` → every identity that touches this repo (e.g. shared packages).
- `[vm.<role>]` → only that role (e.g. the heavy footprint for `vergil-user`).

So in the example above:

| Identity | Composed repo-spec | Result |
|---|---|---|
| `vergil-user` | packages **+** 12 / 64 GiB / 300 GiB | dedicated, tuned-up box |
| `vergil-audit` | packages **+** base footprint | dedicated, packages-only box (tools to *review*, not horsepower to *run* the lab) |
| any plain repo | *(empty)* | base VM |

There is no `use = "base"` flag. **An identity uses its base VM for an `org/repo`
iff there is no `[vm]` config in the repo's `vergil.toml` and no `identities.toml`
override for that `(identity, org, repo)`.** Any customization at all → a dedicated
VM.

### `identities.toml` — credentials, base footprint, host overrides

User config holds credentials and the base sandbox footprint at the identity tier,
and an optional path cascade for rare host-side overrides. The path cascade uses
**nested TOML tables**, which keep `org` and `repo` structurally separate keys —
no flattened `a-b-c` whose org/repo boundary you have to guess:

```toml
default_identity = "vergil-user"
vergil           = "2.1.0"

[identities.vergil-user]
auth_type        = "app"
app_id           = "…"
private_key_path = "…"
projects_dir     = "~/dev/projects"
cpus   = 4                                  # the BASE sandbox footprint
memory = "4GiB"
disk   = "50GiB"

[identities.vergil-audit]
# …credentials, base footprint…

# Host-side override (rare). Example: a 32 GiB Mac that cannot run the lab at the
# repo's declared 64 GiB tunes it down for THIS machine only. Wins over the repo
# spec (host reality is authoritative for this user's box). Usually absent.
# [identities.vergil-user."logical-minds-foundry"."mq-cluster-tooling"]
# memory = "32GiB"
```

**Forward namespace.** Identities are role-qualified and always `vergil-`-prefixed:
`vergil-user`, `vergil-audit`, `vergil-admin`. This retires the awkward mix of
bare `agent` / bare `user` / inconsistent prefixing in the current file. The legacy
`vergil-agent` identity goes away as part of the separate migration.

### Composition & precedence

The spec used to build/validate a VM is an overlay, lowest → highest precedence:

1. Built-in base footprint (hard default).
2. `identities.toml [<identity>]` — credentials + base footprint.
3. Repo `vergil.toml [vm]` — all-identity requirements.
4. Repo `vergil.toml [vm.<identity>]` — role requirements.
5. `identities.toml [<identity>.<org>.<repo>]` — **host-side override, wins.**

Merge rules:

- **`packages` accumulate** (union across tiers — additive, never subtractive).
- **Scalars (`cpus`, `memory`, `disk`) are last-wins** — the highest-precedence
  tier that sets them decides.
- **Credentials** come solely from tier 2.

A host override (tier 5) is a legitimate, *recorded* build target — it is folded
into the fingerprint (below), so overriding does not register as drift. The
override mechanism is built now because it is nearly free (one more tier of an
overlay already being computed); it is not expected to see use day one.

## VM instance naming convention

Every Lima instance is named from `(identity, scope)`, with `--` (double dash) as
the tier delimiter so single dashes can live inside org/repo names:

| Identity | Scope | Lima instance |
|---|---|---|
| `vergil-user` | base | `vergil-user` |
| `vergil-user` | `logical-minds-foundry/mq-cluster-tooling` | `vergil-user--logical-minds-foundry--mq-cluster-tooling` |
| `vergil-audit` | base | `vergil-audit` |
| `vergil-audit` | `logical-minds-foundry/mq-cluster-tooling` | `vergil-audit--logical-minds-foundry--mq-cluster-tooling` |

`split('--')` recovers `[identity, org, repo]` exactly — fully qualified (no
collisions, even across orgs that share a repo name like `.github`) and reversible,
which the slash→dash flattening never was. A bare identity name (no `--`) is the
base box. The instance name is a derived handle; the authoritative key is the
`(identity, org/repo)` pair and the nested config.

## Resolution & the safety gate

For `vrg-vm session <identity> <org>/<repo>` (and lifecycle commands):

1. Read the repo's `vergil.toml` from the local checkout under `projects_dir`
   (the repo must be checked out to be worked on — a local read, no network).
2. Compose the repo-spec (`[vm]` ⊕ `[vm.<identity>]`) and apply any
   `identities.toml` override tier.
3. **Empty composed spec** → target the **base** VM.
   **Non-empty** → target the **dedicated** VM `<identity>--<org>--<repo>`.
4. **Fingerprint check.** Each VM records, at provision time, a fingerprint of the
   composed spec it was built from (an in-VM marker file, e.g.
   `/etc/vergil/vm-spec.fingerprint`, written during provisioning and read back on
   start/session). Compare it to the freshly composed spec:
   - VM missing → **abort** with the exact `vrg-vm create <org>/<repo>` to run.
   - Fingerprint mismatch (spec changed — e.g. the author bumped 32 → 64 GiB, or
     added a package) → **abort** with the exact `vrg-vm rebuild <org>/<repo>` to
     run; surfaced as `NEEDS-REBUILD` in `list`.
   - Match → proceed.

This is what makes the system honest: you can never silently run on an undersized
or stale box. The fingerprint is over the *composed* spec, so a deliberate host
override matches and a real requirement change does not.

The "more than one VM → ask" UX the issue gestured at **dissolves** under path
addressing: `(identity, org/repo)` is exactly one VM, so `session` is never
ambiguous. The auto/ask disambiguation remains only where it already lives —
session *slots inside* a VM (`vrg-vm-resolve-session`), unchanged by this work.

## Package & provisioning layering

The issue flagged two install shapes; both must stay reproducible:

- **Apt packages** — the common case. The `packages` union is layered onto the
  base image at provision time via a parameterized provisioning step in
  `templates/agent.yaml`. The template is fetched by tag (`lima.py:fetch_template`),
  so its package-layering contract is versioned in `vergil-vm`.
- **Non-apt installs** — e.g. Vagrant (HashiCorp apt repo) and the
  `vagrant-libvirt` plugin (`vagrant plugin install …`). These are *not* single
  apt packages, so they do not belong in `packages`. They live in a
  source-controlled **provisioning hook** the repo references from `[vm]`
  (`provision = ".vergil/provision.sh"`), run after the apt layer at provision
  time. The script must be idempotent and deterministic so `rebuild` reproduces
  byte-for-byte.

> **Open for pushback:** the exact hook shape — a repo-relative script path (as
> above) vs. an inline command list in `[vm]`. The script-path form keeps complex,
> multi-line install logic in real shell under source control and out of TOML;
> that is the recommendation, to be confirmed in review.

Both layers feed the fingerprint, so changing the provisioning hook triggers
`NEEDS-REBUILD` just as a package or footprint change does.

## CLI surface

`--identity` defaults to `vergil-user`. An optional `<org>/<repo>` positional
selects a dedicated VM; **absence means the base VM.**

```
vrg-vm session <org>/<repo> [--identity I]   # main entry; path → base or dedicated, auto
vrg-vm create  [<org>/<repo>] [--identity I] # no path = base; path reads repo vergil.toml
vrg-vm rebuild [<org>/<repo>] [--identity I] # destroy + recreate from composed spec
vrg-vm destroy [<org>/<repo>] [--identity I]
vrg-vm start | stop | restart [<org>/<repo>] [--identity I]
vrg-vm update  [<org>/<repo>] [--identity I] # vergil-tooling refresh, base or dedicated
vrg-vm list    [--identity I]                # see below
```

`session` / `start` on a spec'd repo with no conforming VM aborts with the precise
`create` / `rebuild` command. The identity-only path (`vrg-vm create` with no
positional) is **unchanged** — it builds the base box exactly as today.

## Extended `vrg-vm list`

`list` becomes an observability surface, not just a status check:

```
IDENTITY      SCOPE                                    STATUS   CPUS  MEM    DISK    AGENTS  HUMANS  SPEC
vergil-user   base                                     Running  4     4GiB   50GiB   1       0       ok
vergil-user   logical-minds-foundry/mq-cluster-tooling Running  12    64GiB  300GiB  2       1       NEEDS-REBUILD
vergil-audit  base                                     Stopped  4     4GiB   50GiB   —       —       ok
```

- **CPUS / MEM / DISK** — the *composed* footprint the VM is configured for, so a
  `NEEDS-REBUILD` row shows the target and you can eyeball over/under-sizing.
- **AGENTS** — harness instances (named sessions, from the in-VM roster already
  queried by `--sessions`). Harness-agnostic. Agents are sandboxed to running the
  harness; they never hold an interactive login.
- **HUMANS** — **open human-held interactive shells** (`limactl shell` / SSH),
  computed as *total interactive logins − agent sessions* so the shell each agent
  runs inside is not double-counted. The label is `HUMANS`, not `LOGINS`, to make
  the access model legible at a glance: agents are walled into the harness, humans
  get the shell. **This rests on the invariant that agents never hold an
  interactive login** — if that ever changes (a supervised agent debug shell, a
  remote-trigger harness login), the column's semantics must be revisited, because
  an agent login would otherwise be miscounted as a human. The count is a tally of
  *shells*, not distinct people (one human with three triage tabs reads `3`); the
  docs and `--help` state this precisely.
- **AGENTS** and **HUMANS** are shown as two numbers, never summed — total
  occupancy is their sum, but the split is the thing you actually want to see.
  Both are `—` when the VM is not running. Per-VM occupancy is queried only for
  running VMs and only on `list`.
- **SPEC** — `ok` / `NEEDS-REBUILD` / `not-created`, the drift gate surfaced.

## Nested virtualization

The `mq-cluster-tooling` lab needs `/dev/kvm` inside the VM for its arm64 nodes.
Nested virtualization is therefore the **template default** (host permitting),
*not* a per-spec knob — a repo opting *out* of nesting is hard to imagine, and a
knob nobody flips is dead surface. The open enablement question (macOS + Apple
Virtualization nested-virt support) is a **template/provisioning** problem to solve
in `vergil-vm`, not a field in `vergil.toml`.

## Deferred work

- **Org-level specs.** The natural home is the org's `.github` repo (where org
  READMEs live, git-managed) — but it cannot be assumed checked out locally, so it
  would require a GitHub API lookup against the default branch HEAD. Real
  complexity, zero current use cases. Deferred. The cascade **reserves the org
  tier** (`[identities.<id>.<org>]` and a future `org/*` resolution slot) so adding
  it is non-breaking. When it lands, org conformance is **meets-minimum**
  (≥ required cpus/memory, packages ⊇ required), *not* the exact-fingerprint match
  used for per-repo dedicated VMs.
- **Host resource sanity-check.** Before building, verify the host has the RAM/disk
  and warn past a threshold (e.g. > 80 % of available). Future work.
- **Host-side override usage.** The override *mechanism* (tier 5) ships now; we
  have no machine that yet needs to cap the lab, so it is untested against a real
  downsizing case until one exists.

## Invariants preserved

- **Requirements in source (`vergil.toml [vm]`), credentials + selection in user
  config (`identities.toml`).** No secrets in the repo; no repo requirements baked
  into user config.
- **Ephemeral, data-less, reproducible.** Packages and provisioning are *declared*,
  never installed into a live box. `vrg-vm rebuild <org>/<repo>` reproduces
  identically from the composed spec alone.
- **The only working space is the consuming repo's gitignored `build/`,**
  host-mounted into the VM.
- **Recursive-bootstrap caveat (#86).** Infra changes to `vergil-vm` itself run on
  the host, not inside a profile VM.

## Implementation touch-points

**`vergil-tooling`:**

- `lib/identity.py` — parse the nested `[identities.<id>.<org>.<repo>]` cascade;
  add the composition/overlay resolver (tiers 1–5) and a `compose_vm_spec(identity,
  org, repo)`; reuse `_SIZE_PATTERN` and the resource validators. Parse the new
  role-qualified identity names; keep `resolve_workspace` for locating the repo.
- new lib helper — read/validate a repo's `vergil.toml [vm]` cascade
  (`packages`, `cpus`/`memory`/`disk`, `provision`); compute the composed-spec
  fingerprint.
- `lib/lima.py` — `create_vm(...)` layers the composed `packages` and runs the
  `provision` hook at provision time; write the fingerprint marker into the VM;
  read it back for the drift check; add per-VM occupancy queries (agents from the
  roster, humans from login/seat enumeration).
- `bin/vrg_vm.py` — accept the optional `<org>/<repo>` positional across
  `create`/`session`/`rebuild`/`destroy`/`start`/`stop`/`restart`/`update`;
  implement the base-vs-dedicated resolution + abort gate; extend `list` with the
  CPUS/MEM/DISK/AGENTS/HUMANS/SPEC columns.
- `bin/vrg_vm_resolve.py` — unchanged in behaviour; its roster output feeds the
  `AGENTS` count.

**`vergil-vm` (this repo):**

- `templates/agent.yaml` — a parameterized provisioning step that installs the
  composed `packages` list and runs the repo `provision` hook; nested-virt enabled
  by default; write the spec fingerprint marker. The template is tag-versioned, so
  this is the stable package/provisioning contract.
- `tests/` — assert a dedicated profile VM has an extra package the base lacks;
  assert the fingerprint drift gate flips `NEEDS-REBUILD` when the spec changes;
  assert identity-only `create` is unchanged.

## Acceptance criteria

- `vrg-vm create <org>/<repo>` builds a Lima instance sized by the composed spec
  (`nproc` / `free -h` / `df -h` match) with the declared extra packages installed.
- A throwaway profile pointed at a tiny test repo with one extra package proves the
  apt-layering end-to-end; a second case proves the `provision` hook runs.
- `vrg-vm rebuild <org>/<repo>` destroys + recreates to identical state from the
  composed spec alone, with the host-mounted `build/` intact.
- Bumping a footprint or package in the repo `vergil.toml` flips that VM's `list`
  row to `NEEDS-REBUILD`, and `session`/`start` abort with the `rebuild` command.
- `vrg-vm list` shows CPUS/MEM/DISK and, for running VMs, correct `AGENTS` and
  `HUMANS` counts (an extra `limactl shell` raises `HUMANS` by one; it does not
  change `AGENTS`).
- Identity-only `vrg-vm create` / `session` (no positional) is unchanged.
- `vergil-audit` against the same spec'd repo builds a packages-only dedicated box
  at base footprint; `vergil-user` builds the tuned-up box.

## Resolved open questions (from issue #99)

1. **Package layering mechanism** — apt `packages` union layered in the
   tag-versioned `agent.yaml` provisioning step; deterministic, fingerprinted.
2. **Vagrant / `vagrant-libvirt`** — non-apt installs go in a source-controlled
   `provision` hook referenced from `[vm]`, run after the apt layer (script-path
   shape recommended, confirm in review). Not in the apt list.
3. **Inline overrides** — yes, as host-side overrides at the `identities.toml`
   `[<id>.<org>.<repo>]` tier (precedence 5, wins); mechanism built, rarely used.
4. **Name collisions** — solved by fully-qualified, reversible `--`-delimited
   instance names and nested TOML keys; no invented profile names.
5. **Nested virtualization** — template default (host permitting), not a spec knob;
   macOS/Apple-Virtualization enablement is a template/provisioning concern.
