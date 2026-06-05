# Multi-VM Identities: Per-Repo VM Profiles Design

**Issues:**
- [vergil-vm #99 — feat: per-repo VM profiles — build a VM from a consuming repo's spec](https://github.com/vergil-project/vergil-vm/issues/99)

**Date:** 2026-06-04

**Status:** Implemented (issue #99). Revised after a structured pushback review
(2026-06-04) — see "Pushback resolutions" at the end.

> **Amended by [vergil-vm #105](https://github.com/vergil-project/vergil-vm/issues/105).**
> The `provision` *script hook* described below (and its content-hashing) was **removed**
> before real use and replaced with two **declarative** knobs in `vergil.toml [vm]`:
> `apt_repos` (extra apt repositories: key + source line) and `vagrant_plugins`. The
> reviewed `vergil-vm` template owns the install; repos never supply a script. Relatedly,
> **`.vergil/` is global gitignored scratch** — nothing source-controlled lives there
> (the hook's old `.vergil/provision.sh` home was the trigger). Wherever this document
> says `provision` / `provision.sh`, read `apt_repos` + `vagrant_plugins`.

> **Amended by [vergil-vm #111](https://github.com/vergil-project/vergil-vm/issues/111).**
> `vrg-vm list` enumerates dedicated VMs from **existing Lima instances only**; the
> projects-tree scan and the `not-created` SPEC state are **dropped**. Discovery of
> declared-but-unbuilt VMs stays with the `session`/`start` preflight gate, which
> already aborts with the exact `create` command at the moment the signal is
> actionable. The "Extended `vrg-vm list`", "Dedicated-VM lifecycle (orphans)", and
> implementation touch-point sections below incorporate the revision. Implementation:
> [vergil-tooling #1412](https://github.com/vergil-project/vergil-tooling/issues/1412).

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
  never `apt install`-ed into a live box. `rebuild` reproduces the **declared
  spec** (footprint + package set + provisioning) — no working state is baked in;
  lab content lives in `build/`. Package *versions* track upstream (see
  Reproducibility, below).

## Non-goals

- **Org-level VM specs.** Deferred — no current use case. The cascade *reserves*
  the org tier so it is non-breaking to add later. See Deferred work.
- **Host resource sanity-checking.** Verifying the Mac actually has the RAM/disk
  (and warning near capacity) is real but second/third-order. Reserved as future
  work, not built now.
- **Buildkit provisioning (#97).** The Approved-but-unmerged
  `feature/97-buildkit-provisioning` adds a `mode: user` buildkit block to the same
  `templates/agent.yaml` this design parameterizes. It is intentionally **on hold**
  and out of scope here; after this lands, #97 is rebased and re-engineered to sit
  on top of these provisioning changes — it adapts to this design, not the reverse.
- **Infra changes to `vergil-vm` itself running inside a profile VM.** The
  recursive-bootstrap caveat (#86) stands: changes to the VM image are made on the
  host, not from inside a profile VM.

The identity-key normalization (`user`/`audit` → `vergil-user`/`vergil-audit`) **is
in scope** — see "Identity-key normalization (migration)". Retiring the legacy
`vergil-agent` *VM instance* and any broader fleet migration remain separate
execution.

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
# Non-apt TOOLING installs (HashiCorp repo for vagrant, then `vagrant plugin
# install vagrant-libvirt`) live in a source-controlled provisioning hook, not
# the apt list — see "Package & provisioning layering". The hook installs tooling
# ONLY; it never builds Vagrant boxes or stands up the lab.
provision = ".vergil/provision.sh"

[vm.vergil-user]                  # role overlay: only vergil-user is tuned up
cpus       = 12
memory     = "64GiB"
disk       = "300GiB"
stale_days = 7                    # rebuild nag once a week (base default is 3)
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
bare `agent` / bare `user` / inconsistent prefixing in the current file.

### Identity-key normalization (migration)

The merged dual-App setup (vergil-tooling v2.1.0) ships **bare-role identity keys**
— `[identities.user]` / `[identities.audit]` with `vm_instance = "vergil-user"` —
documented in `account-setup.md`. That split (key `user`, instance `vergil-user`)
is exactly the inconsistency this design removes. This work **normalizes the
identity keys to `vergil-<role>`** so the key equals the instance base everywhere.

We take this breaking change *now*, deliberately, because the deployment is still
**fleet-of-one** (a single human, a single `identities.toml`, pre-public-release).
There is no installed base to keep backward-compatible yet, so no compatibility
shim is built — we simply normalize the one file and the docs.

Scope of the rename:

- **Identity key:** `user` → `vergil-user`, `audit` → `vergil-audit` (and the
  reserved `admin` → `vergil-admin`). The `--identity` default becomes
  `vergil-user`.
- **`vm_instance` (base VM name):** stays `vergil-user` / `vergil-audit` — now equal
  to the key. The legacy `vergil-agent` instance is retired separately.
- **GitHub App credential names are UNCHANGED:** the Apps remain
  `<username>-vergil-<role>` (e.g. `wphillipmoore-vergil-user`). Only the
  identities.toml *key* moves; the credential layer is untouched.
- **Docs:** `vergil-tooling`'s `account-setup.md` and the dual-stanza example are
  updated to the `vergil-<role>` keys (see touch-points).

### Composition & precedence

The spec used to build/validate a VM is an overlay, lowest → highest precedence:

1. Built-in base footprint (hard default).
2. `identities.toml [<identity>]` — credentials + base footprint.
3. Repo `vergil.toml [vm]` — all-identity requirements.
4. Repo `vergil.toml [vm.<identity>]` — role requirements.
5. `identities.toml [<identity>.<org>.<repo>]` — **host-side override, wins.**

Merge rules:

- **`packages` accumulate** (union across tiers — additive, never subtractive).
- **Scalars (`cpus`, `memory`, `disk`, `stale_days`) are last-wins** — the
  highest-precedence tier that sets them decides. `stale_days` defaults to the base
  policy (3) when unset; a dedicated lab box typically sets a longer window (e.g. 7)
  in its repo `[vm]`/`[vm.<role>]` overlay.
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

This is what makes the system honest: you can never silently run on a stale box.
The fingerprint is over the *composed* spec, so a deliberate host override matches
and a real requirement change does not.

**Under-provisioning warning (the override floor).** A host override (tier 5) can
size a box *below* what the repo's `[vm]`/`[vm.<role>]` declares — that is the whole
point of the override (a 32 GiB Mac running a repo that asks for 64). But because
the fingerprint compares against the *composed* spec, such a box reads `ok`, hiding
the fact that it falls short of the author's stated need. That is a silent
misconfiguration waiting to surface as days of phantom debugging (nodes that won't
boot, OOM kills) on a problem that is actually a config choice. So: the override
stays **sovereign** (we never block — your machine, your call), but it is **never
silent**. When any composed scalar is below the repo's declared value, `session`
prints a loud notice at launch (e.g. *"this repo asks for 64GiB; this box has 32GiB
— it probably will not work"*) and `list` flags the row (see `SPEC` below). A hard
gate (refuse-unless-`--force`) is deliberately deferred until loud-warning proves
insufficient in practice.

The "more than one VM → ask" UX the issue gestured at **dissolves** under path
addressing: `(identity, org/repo)` is exactly one VM, so `session` is never
ambiguous. The auto/ask disambiguation remains only where it already lives —
session *slots inside* a VM (`vrg-vm-resolve-session`), unchanged by this work.

## Package & provisioning layering

The issue flagged two install shapes. **Both layer TOOLING only** — they install
what the VM needs to *do* the repo's work; they never build the repo's actual work
product (the Vagrant boxes / lab):

- **Apt packages** — the common case. The `packages` union is layered onto the
  base image at provision time via a parameterized provisioning step in
  `templates/agent.yaml`. The template is fetched by tag (`lima.py:fetch_template`),
  so its package-layering contract is versioned in `vergil-vm`.
- **Non-apt tooling installs** — e.g. Vagrant (HashiCorp apt repo) and the
  `vagrant-libvirt` plugin (`vagrant plugin install …`). These are *not* single apt
  packages, so they do not belong in `packages`. They live in a source-controlled
  **provisioning hook** the repo references from `[vm]`
  (`provision = ".vergil/provision.sh"`), run after the apt layer at provision time.
  The hook shape is a **repo-relative script path** (decided in review): it keeps
  complex multi-line install logic in real shell under source control, out of TOML.
  The script must be idempotent.

**Lab/box building is NOT provisioning.** Building the Vagrant boxes and standing up
the multi-VM lab is a **development-time** decision the human and agent make
together per the dev/test mode they are in — it is expensive, varied, and run on
demand, not baked into the image. Lab artefacts land in the gitignored,
host-mounted `build/`. This is *why* even the heavy lab box rebuilds in minutes: the
image is base + tooling, and the lab content is reconstructed at dev time on top of
it. It also keeps the box ephemeral and data-less.

Both tooling layers feed the fingerprint, so changing the package set or the
provisioning hook triggers `NEEDS-REBUILD` just as a footprint change does.

### Reproducibility (what "reproducible" means here)

`rebuild` reproduces the **declared spec** — the same footprint, the same package
*set*, the same provisioning hook — not a byte-identical image. Package *versions*
are not pinned: `apt-get install <pkg>` (and the base template's `gh` / Node /
Claude Code / `yq` installs) pull whatever is current, so two rebuilds a week apart
can differ in versions while matching the same fingerprint. This is deliberate — a
dev VM should track upstream, and version-pinning would rot and fight the base
image's "install latest" design. The **fingerprint therefore covers the
declaration** (footprint + package list + provision-hook identity), *not* the
resulting bytes. The genuinely reproducible guarantee — that no working state is
baked into the image, and lab content lives in `build/` — holds fully.

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
- **AGENTS / HUMANS — counted by process-tree classification, not arithmetic.**
  Each in-VM login session is classified by inspecting its process tree: it is an
  **agent** if its tree roots the harness (`claude`), a **human** if it is an
  interactive PTY login that is not agent-hosting. The two columns are *direct
  counts* of those two classes — there is **no** "total minus agents" subtraction.
  This is deliberate: a naïve total-logins count sweeps in the tooling's own
  transient non-interactive `limactl shell -- cmd` calls (credential injection,
  config copy, session resolve, even the occupancy query itself), and the
  subtraction can mis-attribute or go negative. Process-tree classification excludes
  those non-TTY exec channels *by construction*.
  - **AGENTS** — harness instances; reconciles with the `--sessions` roster.
  - **HUMANS** — **open human-held interactive shells** (`limactl shell` / SSH for
    debugging and triage). The label is `HUMANS`, not `LOGINS`, to make the access
    model legible at a glance: agents are walled into the harness, humans get the
    shell. **This rests on the invariant that agents never hold an interactive
    login** — if that ever changes (a supervised agent debug shell, a remote-trigger
    harness login), the classifier and this column's meaning must be revisited. The
    count is a tally of *shells*, not distinct people (one human with three triage
    tabs reads `3`); the docs and `--help` state this precisely.
  - Shown as two numbers, **never summed** — total occupancy is their sum, but the
    split is the thing you want to see. Both are `—` when the VM is not running.
    Per-VM occupancy is queried only for running VMs and only on `list`.
- **SPEC** — the drift/health gate surfaced:
  - `ok` — composed spec matches the built fingerprint.
  - `NEEDS-REBUILD` — fingerprint drift (the repo spec changed); `session`/`start`
    abort with the `rebuild` command.
  - `orphaned` — a dedicated VM instance exists but no backing spec does (the repo
    dropped its `[vm]`, or was renamed/removed). See Dedicated-VM lifecycle.
  - `ok ⚠ under (mem 32<64)` — running, but a host override sized a scalar below the
    repo's declared value (the override floor warning).

  A repo that declares a spec but has never built its VM is deliberately **not** a
  `list` state (#111). That signal is delivered by the `session`/`start` preflight
  gate — which aborts with the exact `create` command at the moment the user
  expresses intent to use the repo — rather than as standing inventory. Listing it
  would mean scanning every checked-out repo per identity (O(repos), not
  O(instances)), and at scale the declared-but-unbuilt rows would drown the rows
  that matter.

## Staleness (tunable per VM)

The existing lifecycle hard-codes a 3-day staleness threshold: `start`/`session`
abort on a VM older than the threshold, nudging a rebuild (which also refreshes
in-VM tooling). That default is right for the cheap base sandbox. Dedicated VMs make
the threshold **tunable** via `stale_days` in the repo `[vm]`/`[vm.<role>]` cascade
(composed like any scalar, last-wins). The base VM keeps the 3-day default; the
`mq-cluster-tooling` lab sets `7` (weekly).

Because lab content is rebuilt at dev time into `build/` (not baked into the image),
even the heavy box rebuilds in minutes, so a tunable nag — rather than a longer hard
floor or a fingerprint-only policy — is the right first cut. We are deliberately not
over-designing this; further policies (e.g. staleness keyed off fingerprint rather
than age) are revisited if experience demands.

## Dedicated-VM lifecycle (orphans)

`list` enumerates dedicated VMs from **existing Lima instances only** — those
matching `<identity>--*`. For each instance, one **targeted read** of that repo's
`vergil.toml` (under `projects_dir`) classifies it: a backing `[vm]` spec means
present; none means **orphaned** — the repo dropped its `[vm]`, or was
renamed/moved/deleted. Cost is O(instances), not O(checked-out repos).

There is no projects-tree scan (#111). The original design unioned in a second
source — every spec-bearing repo under `projects_dir` — solely to surface
`not-created` rows; orphan classification never needed it. The scan paid a
full-tree config parse per identity, would drown the live rows in
declared-but-unbuilt inventory as adoption grows, and coupled `list` output to
validation noise from every `vergil.toml` in the tree. The preflight abort gate
(see "Resolution & the safety gate") remains the discovery surface for
declared-but-unbuilt VMs.

Orphans route nothing (`session` now lands on base) and have no spec to drift
against, so without handling they would linger invisibly, consuming disk — up to
300 GiB on the lab box.

Resolution: orphans are **surfaced, not auto-removed**. `list` shows the instance
with `SPEC = orphaned`; `destroy <org>/<repo>` (or `destroy` by the instance name)
removes it — `destroy` needs only the name, not a composed spec. We deliberately do
**not** auto-prune: these VMs are expensive and a missing spec can be transient (a
repo temporarily moved, a stanza about to be re-added), so silently nuking 300 GiB
on that signal is too dangerous. If stale orphans pile up in practice, an opt-in
`gc` is an easy follow-up.

## Security boundaries

Vergil's hard problems live at the **seams between systems**, where one system's
guarantees do not line up with the next's. This design adds one such seam and must
name it rather than leave it implicit:

**Repo-controlled code runs as root in a credentialed VM.** The `provision` hook is
a script from the consuming repo, executed with root at provision time; the same VM
later holds the identity's GitHub App private key (injected by `session`/`start`). A
hostile or compromised `provision.sh` — or a dependency it pulls — could read that
key and exfiltrate it. The VM's host-isolation protects the laptop; it does **not**
protect the credential inside the VM.

Bound and mitigation (no new machinery, proportionate to a single-user system
developing its own repos):

- **Trust boundary, stated:** build a dedicated VM only for a repo you trust to run
  code as root. In normal use that is your own repo.
- **Fingerprint as review checkpoint:** the hook is folded into the fingerprint, so
  any change to `provision.sh` flips `NEEDS-REBUILD` — a forced moment to eyeball
  the script before it re-runs.
- **Tooling-only hook:** the hook installs tooling, not lab content, keeping it
  small and auditable.

This seam is logged — alongside GitHub's permission-granularity gaps (grants that
carry unwanted companion permissions; no fine-grained agent-capability control) — in
a **strategic security-boundary register**
([vergil-tooling #1369](https://github.com/vergil-project/vergil-tooling/issues/1369))
for long-term, solution-seeking tracking. Those entries also become comparison criteria
when evaluating GitHub alternatives: do the same imperfectly-aligned boundaries
apply there?

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
- **Host-side override usage.** The override *mechanism* (tier 5) and its loud
  under-provisioning warning ship now; we have no machine that yet needs to cap the
  lab, so it is untested against a real downsizing case until one exists. A hard gate
  (refuse-unless-`--force` below the declared floor) is deferred until the loud
  warning proves insufficient.

## Invariants preserved

- **Requirements in source (`vergil.toml [vm]`), credentials + selection in user
  config (`identities.toml`).** No secrets in the repo; no repo requirements baked
  into user config.
- **Ephemeral, data-less, reproducible-from-declaration.** Packages and provisioning
  are *declared*, never installed into a live box. `vrg-vm rebuild <org>/<repo>`
  reproduces the **declared** footprint + package set + provisioning from the
  composed spec alone (versions track upstream — see Reproducibility). No working
  state is baked in; lab content lives in `build/`.
- **The only working space is the consuming repo's gitignored `build/`,**
  host-mounted into the VM.
- **Recursive-bootstrap caveat (#86).** Infra changes to `vergil-vm` itself run on
  the host, not inside a profile VM.

## Implementation touch-points

**`vergil-tooling`:**

- `lib/identity.py` — normalize identity keys to `vergil-<role>`; parse the nested
  `[identities.<id>.<org>.<repo>]` cascade; add the composition/overlay resolver
  (tiers 1–5) and a `compose_vm_spec(identity, org, repo)`; reuse `_SIZE_PATTERN`
  and the resource validators; keep `resolve_workspace` for locating the repo.
- new lib helper — read/validate a repo's `vergil.toml [vm]` cascade
  (`packages`, `cpus`/`memory`/`disk`, `stale_days`, `provision`); compute the
  composed-spec fingerprint (declaration: footprint + package list + provision-hook
  identity).
- `lib/lima.py` — `create_vm(...)` layers the composed `packages` and runs the
  `provision` hook at provision time; write the fingerprint marker into the VM;
  read it back for the drift check; **classify per-VM occupancy by process tree**
  (agent = tree roots the harness; human = interactive PTY login that is not
  agent-hosting); enumerate dedicated VMs from existing `<identity>--*` instances,
  classifying each present/orphaned via a targeted read of that repo's
  `vergil.toml` — no projects-tree scan (#111;
  [vergil-tooling #1412](https://github.com/vergil-project/vergil-tooling/issues/1412)).
- `bin/vrg_vm.py` — accept the optional `<org>/<repo>` positional across
  `create`/`session`/`rebuild`/`destroy`/`start`/`stop`/`restart`/`update`;
  implement the base-vs-dedicated resolution + abort gate; apply composed
  `stale_days`; emit the loud under-provisioning warning when a host override sizes
  below the repo's declared scalar; extend `list` with the
  CPUS/MEM/DISK/AGENTS/HUMANS/SPEC columns (including `orphaned` and the `under`
  flag).
- `bin/vrg_vm_resolve.py` — unchanged in behaviour; its roster reconciles with the
  process-tree `AGENTS` count.
- `docs/site/docs/guides/account-setup.md` (+ the dual-stanza example) — update the
  `[identities.user]`/`[identities.audit]` keys to `vergil-user`/`vergil-audit` per
  the identity-key normalization; the App-credential naming is unchanged.

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
  `HUMANS` counts: an extra `limactl shell` raises `HUMANS` by one and leaves
  `AGENTS` unchanged; the tooling's own transient non-interactive `limactl shell --`
  calls do **not** move either count.
- Identity keys are `vergil-user`/`vergil-audit`; `--identity` defaults to
  `vergil-user`; `account-setup.md` matches. Identity-only `vrg-vm create` /
  `session` (no positional) is unchanged.
- `vergil-audit` against the same spec'd repo builds a packages-only dedicated box
  at base footprint; `vergil-user` builds the tuned-up box.
- A repo `[vm]` setting `stale_days = 7` is honoured: the box does not nag until day
  7, while the base box still nags at day 3.
- Dropping a repo's `[vm]` leaves its instance as `SPEC = orphaned` in `list`, and
  `vrg-vm destroy <org>/<repo>` removes it.
- A host override sizing memory below the repo's declared value runs, but `session`
  warns loudly at launch and `list` flags the row `under`.

## Resolved open questions (from issue #99)

1. **Package layering mechanism** — apt `packages` union layered in the
   tag-versioned `agent.yaml` provisioning step; deterministic, fingerprinted.
2. **Vagrant / `vagrant-libvirt`** — non-apt **tooling** installs go in a
   source-controlled `provision` hook (repo-relative script path) referenced from
   `[vm]`, run after the apt layer. Not in the apt list. The hook installs tooling
   only; building the lab is a dev-time step into `build/`.
3. **Inline overrides** — yes, as host-side overrides at the `identities.toml`
   `[<id>.<org>.<repo>]` tier (precedence 5, wins); mechanism built, rarely used.
4. **Name collisions** — solved by fully-qualified, reversible `--`-delimited
   instance names and nested TOML keys; no invented profile names.
5. **Nested virtualization** — template default (host permitting), not a spec knob;
   macOS/Apple-Virtualization enablement is a template/provisioning concern.

## Pushback resolutions (2026-06-04)

A structured pushback review surfaced two source-control conflicts and six design
findings. Resolutions, all folded into the body above:

**Conflicts**

- **Identity-key naming** — the shipped dual-App setup uses bare-role keys
  (`[identities.user]`). Resolved to **normalize keys to `vergil-<role>`** now, while
  fleet-of-one and pre-release; see "Identity-key normalization (migration)".
- **#97 buildkit provisioning** — Approved-but-unmerged, touches the same
  `agent.yaml`. Resolved to **defer**; #97 rebases onto this work later (Non-goals).

**Findings**

1. **Dedicated-VM staleness** (serious) — `stale_days` made tunable per VM, lab
   defaults to 7; base stays 3. Plus the correction that the `provision` hook is
   **tooling-only** (lab building is dev-time), which keeps rebuilds fast.
2. **AGENTS/HUMANS counting** (serious) — replaced fragile "total − agents"
   arithmetic with **process-tree classification**, counted directly.
3. **Reproducibility overclaim** (moderate) — dropped "byte-for-byte"; reproduces the
   **declared** spec, versions track upstream; fingerprint = declaration. See
   "Reproducibility".
4. **`provision.sh` root-in-credentialed-VM** (security) — documented trust boundary
   + fingerprint-as-checkpoint in "Security boundaries"; logged to a strategic
   security-boundary register (vergil-tooling #1369) alongside GitHub permission-
   granularity gaps.
5. **Orphaned dedicated VMs** (moderate) — `list` surfaces `SPEC = orphaned`,
   `destroy` removes; no auto-prune. See "Dedicated-VM lifecycle".
6. **Host override below declared minimum** (moderate) — override stays sovereign but
   **never silent**: loud `session` warning + `list` `under` flag. Hard gate
   deferred. See the override-floor note under "Resolution & the safety gate".
