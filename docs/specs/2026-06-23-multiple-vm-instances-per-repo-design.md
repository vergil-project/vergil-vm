# Multiple VM Instances Per Repo (Named Instances) Design

**Issues:**
- [vergil-vm #242 — Support multiple VM instances per repo (independent backends/configs) + guard the backend-switch destroy-orphan edge condition](https://github.com/vergil-project/vergil-vm/issues/242)

**Date:** 2026-06-23

**Status:** Design (from brainstorming, 2026-06-23). Extends the per-repo VM
profiles model (#99) and the off-platform backend (#199); supersedes neither.

**Spans two repositories.** Like #99 and #199, this feature touches both
`vergil-vm` (the OpenTofu module state/label contract, per-instance volume keying,
and tests) and `vergil-tooling` (the `vrg-vm` CLI: profile parsing, composition,
fingerprint, handle naming, `--name` selection across every verb, recorded-state
lifecycle dispatch, and the `list` surface). The document lives in `vergil-vm`
because issue #242 is filed here. A companion `vergil-tooling` issue carries the
tooling work (to be filed, mirroring [#1412](https://github.com/vergil-project/vergil-tooling/issues/1412)
for #99 and [#1706](https://github.com/vergil-project/vergil-tooling/issues/1706)
for #199); this spec is authoritative for the `vergil-vm`-owned contract and
specifies the tooling side at the interface level.

## Problem

The off-platform backend (#199) preserved the foundational rule established by
#99: a single `(identity, org/repo)` maps to **exactly one VM**, whose backend is
whatever that identity's composed profile resolves to (`local` Lima or
`off-platform` cloud). The path you `cd` to *is* the selector, and there is no way
to own — or choose among — more than one VM for the same `(identity, repo)`.

Two related problems fall out of that 1:1 mapping.

### Problem 1 — switching `backend` orphans the old VM on destroy

`vrg-vm destroy` resolves the *current* composed profile to decide what to tear
down. Flip an identity's `backend` (e.g. move `vergil-user` from local Lima to
off-platform GCP) and then run `destroy`, and it targets the **new** backend's VM.
If that VM was never created, `destroy` is a no-op (or an error) and the **old**
backend's VM is silently orphaned — left running, billing, and holding resources
with no lifecycle handle left in the tooling. Today's only mitigation is
undocumented ordering discipline (destroy under the old config before changing it),
which is easy to forget and costs real money when the orphan is a cloud VM.

### Problem 2 — one repo, several independent instances

The 1:1 mapping blocks the natural multi-instance workflow. Concrete, current and
near-term use cases (from `logical-minds-foundry/mq-cluster-tooling` / the MQ
Resiliency Lab):

- **Dual-arch (now).** Run a local arm64 Lima box *and* an off-platform x86 cloud
  box for the same identity/repo at once — develop locally on arm, validate
  native-x86 in the cloud.
- **One-per-setup (near-term).** Stand up a distinct lab instance per cluster
  setup — Native HA RHEL, RDQM RHEL, Native HA Ubuntu, Pacemaker Ubuntu — each
  managed, sized, and versioned independently, rather than crammed into one large
  always-on box that pays the whole cost at once.
- **Named-for-a-person/client.** A lab built with a special config (e.g. SSH /
  remote access) so a named collaborator can experiment in it.

Right now you must pick one VM per `(identity, repo)`; bringing up a second
replaces the first.

### Decision: Problem 2 subsumes Problem 1

This spec designs Problem 2 — named instances — and lets Problem 1 dissolve out of
it. Distinct named instances have distinct lifecycle handles, distinct recorded
state, and distinct volumes, so switching or replacing one can no longer orphan
another. See "How Problem 1 dissolves." The interim stopgap for Problem 1 (manual
destroy-before-switch) remains the only mitigation until this work lands.

## Goals

- **Several named instances per `(identity, repo)`,** each with its own composed
  profile, backend, lifecycle, state, and persistent volume.
- **Fully backward compatible.** A repo that names nothing behaves exactly as
  today; `--name` is optional on every verb; every existing VM handle stays valid.
- **Deterministic, no guessing.** A bare verb targets the default instance; a named
  instance is addressed explicitly. The four-part handle stays reversible.
- **Problem 1 dissolved, not patched.** Lifecycle verbs act on what was actually
  built, orphans are surfaced, and the orphan-prone in-place backend flip is no
  longer the natural operation.
- **Name and backend independent.** The name is a handle, not a backend selector;
  each instance's composed profile declares its own `backend`.

## Non-goals

- **Automatic backend inference from name.** A name like `cloud-x86` does not imply
  off-platform; the instance's profile sets `backend` explicitly.
- **Cross-instance shared volume / multi-attach.** Each instance is 1:1 with its
  own volume, preserving #199's no-concurrent-attach property. No shared FS between
  instances.
- **Auto-reaper for forgotten paid instances.** #199's documented teardown
  discipline plus the e2e `trap … EXIT` backstop still apply — now per instance.
  No billing surface in `list`, no auto-prune of orphans (carried from #99/#199).
- **Per-instance org-tier specs.** The org tier stays reserved (#99), unbuilt.
- **A "forbid the bare default" mode.** A repo cannot yet declare that a bare verb
  must name an instance. Easy opt-in flag later if a lab repo wants it; deferred.

## Terminology

- **Instance name** — an optional, free-form, source-controlled label
  (`[a-z0-9-]+`, no `--`) that distinguishes co-existing VMs for one
  `(identity, org/repo)`. Examples: `cloud-x86`, `rdqm-rhel`, `pacemaker-ubuntu`.
- **Default instance** — the instance addressed when no name is given. It composes
  `[vm] ⊕ [vm.<identity>]` (tiers 1–4 below) and, when that is empty, is the base
  box — i.e. exactly today's behavior.
- **Named instance** — an instance declared under
  `[vm.<identity>.instances.<name>]`, composing the cascade plus its named overlay.
- **Handle** — the authoritative key `(identity, org/repo, name)`, where an absent
  name selects the default instance.

The #99/#199 terms (identity, base VM, dedicated VM, agent, human) carry over
unchanged.

## The model: a name extends the handle

The authoritative key moves from `(identity, org/repo)` to
`(identity, org/repo, name)`; an absent name is the default instance.

### Handle / slug / Lima instance / resource label

The `--`-delimited naming convention from #99 gains a fourth segment:

| Handle | Slug |
|---|---|
| base box | `vergil-user` |
| dedicated, unnamed (default) | `vergil-user--logical-minds-foundry--mq-cluster-tooling` |
| named instance `cloud-x86` | `vergil-user--logical-minds-foundry--mq-cluster-tooling--cloud-x86` |

`split('--')` recovers `[identity, org, repo, name]` exactly: one segment is the
base box, three is the unnamed dedicated VM, four is a named instance — fully
qualified and reversible. **Names are constrained to `[a-z0-9-]+` and must not
contain `--`** (a single dash inside a name is fine; a double dash would break the
delimiter). The constraint is validated at parse time with a loud error
(no-silent-failures); an invalid name never produces a malformed slug.

### Config: the `instances` namespace (source-controlled)

A named instance is declared in the consuming repo's `vergil.toml` under an
explicit `instances` table inside the role overlay. The explicit namespace makes
intent unmistakable and avoids any clash with array-of-table keys (`port_forwards`,
`apt_repos`):

```toml
# logical-minds-foundry/mq-cluster-tooling/vergil.toml
[vm]                                     # all identities, all instances
packages = ["qemu-system-x86", "libvirt-daemon-system", "..."]

[vm.vergil-user]                         # the DEFAULT (unnamed) instance
cpus   = 12
memory = "64GiB"
disk   = "300GiB"                        # local arm64 Lima box (backend defaults to local)

[vm.vergil-user.instances.cloud-x86]     # named: "cloud-x86"
backend  = "off-platform"
provider = "gcp"
region   = "us-central1"
instance = "n2-standard-16"
volume   = "300GiB"
nested   = true
cpus     = 16                            # intent floor; `instance` is authoritative (#199)
memory   = "64GiB"

[vm.vergil-user.instances.rdqm-rhel]     # named: "rdqm-rhel" — smaller, independent
backend  = "off-platform"
provider = "gcp"
region   = "us-central1"
instance = "n2-standard-8"
volume   = "200GiB"
nested   = true
cpus     = 8                             # overrides the inherited 12 from [vm.vergil-user]
memory   = "32GiB"
```

### Composition cascade (extending #99/#199, not replacing)

A named instance is the identity's profile with a named overlay on top. Lowest →
highest precedence:

1. Built-in base footprint (hard default).
2. `identities.toml [<identity>]` — credentials + base footprint.
3. Repo `[vm]` — all-identity, all-instance requirements (e.g. shared packages).
4. Repo `[vm.<identity>]` — role overlay. **This defines the default instance.**
5. Repo `[vm.<identity>.instances.<name>]` — the named-instance overlay.
6. `identities.toml [<identity>.<org>.<repo>]` — host override, wins. A per-name
   override slot (`[<identity>.<org>.<repo>.<name>]`) is **reserved** here and is
   non-breaking to add; not built now.

- **The default instance** composes tiers 1–4 (+6).
- **A named instance** composes tiers 1–5 (+6) — it inherits the role overlay
  (tier 4) and overrides it (tier 5).

Merge rules are unchanged from #99/#199: `packages` accumulate (union, additive);
scalars (`cpus`, `memory`, `disk`, `backend`, `provider`, `region`, `instance`,
`volume`, `stale_days`, `nested`) are last-wins; credentials come solely from tier
2. `backend` defaults to `local` unless an overlay sets `off-platform`; the
off-platform required-key rule (#199: `off-platform` requires
`provider`/`region`/`instance`/`volume`, hard-error if any missing) applies
per named instance.

## Resolution and selection

### Addressing

A `--name <name>` flag on every verb selects a named instance; absent, the verb
targets the default instance:

```
vrg-vm session mq-cluster-tooling                    # default (tiers 1–4)
vrg-vm session mq-cluster-tooling --name cloud-x86   # named instance
vrg-vm create  mq-cluster-tooling --name rdqm-rhel
vrg-vm destroy mq-cluster-tooling --name cloud-x86
```

`--name` is preferred over a `repo:name` positional suffix: it reads explicitly and
keeps the org/repo positional clean. (The suffix form is a possible future
ergonomic alias, not built now.)

### The default always resolves — no error path

A bare verb targets `compose([vm] ⊕ [vm.<identity>])`. When that is empty it is the
base box (today's behavior); when it carries config it is the unnamed dedicated VM.
Named instances are purely additive. There is **no** "error and list when only
named instances exist" path — it adds a special case for little gain, and "bare
verb hits the base/default box" is the consistent #99 rule. A repo that wants to
forbid a bare default is a deferred opt-in flag (Non-goals).

### Preflight gate (unchanged shape, per-instance)

`session`/`start` compose the selected instance's spec, compare its fingerprint
against the built marker, and abort with the exact `create`/`rebuild` command on a
missing or drifted box — exactly the #99 gate, now keyed on the four-part handle.
The fingerprint covers the composed spec (footprint + packages + backend / provider
/ region / instance / volume, per #99/#199); the **name is the handle, not
fingerprint content**, so adding or renaming instances never trips drift on the
others.

## How Problem 1 dissolves

Three mechanisms together, not one:

1. **The natural operation changes.** "Move the lab to GCP" stops being *flip
   `backend` on the one VM* (which re-resolved `destroy` onto a non-existent box
   and orphaned the live one) and becomes *declare a `cloud-x86` instance, destroy
   `local` by name when ready* — two independent handles, two independent
   lifecycles. The orphan-prone in-place mutation is no longer the path.

2. **Lifecycle verbs resolve from recorded state, not the live profile.** This is
   the robustness guarantee that closes the edge even if someone *does* edit a
   named instance's `backend` in place:
   - `create` / `rebuild` / `session`-preflight resolve from the **composed
     profile + fingerprint** — you are asserting intent.
   - `destroy` / `stop` / `start` resolve from **recorded state** — the existing
     Lima instance for the slug, or the tofu state directory (which records its
     provider) — you are acting on reality. A profile edit can never aim `destroy`
     at a box that was never built; it tears down what actually exists for that
     handle.

3. **`list` surfaces the leftover.** Any built instance whose composed spec no
   longer backs it (the repo dropped the stanza, or its backend was edited away)
   enumerates as `SPEC = orphaned` — the #99 orphan mechanism, now per instance —
   and `destroy --name <name>` (or by slug) removes it. Nothing lingers invisibly.

Net: distinct instances have distinct handles, destroy acts on reality, and orphans
are visible — together these mean a backend switch can no longer silently abandon a
billing cloud VM.

## State, resource naming, and volumes

### State paths and labels (off-platform, extending #199)

The tofu state path and cloud resource labels extend by the name segment:

```
~/.config/vergil/tofu/<identity>--<org>--<repo>--<name>/<provider>/
  volume.tfstate   # precious; re-importable from labels
  vm.tfstate       # ephemeral
```

Cloud resources gain a `vergil-instance` label alongside #199's
`vergil-identity` / `vergil-repo`, so label-matched re-import (#199's recovery
posture for a lost `volume.tfstate`) stays deterministic per instance. Lima
instances are enumerated by the same `<identity>--*` prefix scan; the fourth
segment rides along, and four-segment slugs classify as named instances.

### Persistent volume is 1:1 with the instance

Each named instance owns its **own** persistent volume, keyed by the four-part slug
(not the repo). This is exactly the independence the one-per-setup use case wants:
`rdqm-rhel` and `cloud-x86` carry separate checkouts, `.claude` history, and
`build/` lab artifacts, versioned and torn down independently. Because the mapping
stays 1:1 instance→volume, there is still **no multi-attach** — #199's
no-concurrent-attach property is preserved unchanged. The bootstrap-vs-reattach
logic, the fixed-path mount, the format-only-if-blank guard, and the guarded
`destroy-volume` verb (now `destroy-volume --name <name>`) all behave per #199, per
instance.

## `vrg-vm list`

`list` gains an **INSTANCE** column (between SCOPE and BACKEND), `—` for the
default instance:

```
IDENTITY     SCOPE                  INSTANCE   BACKEND  STATUS   CPUS  MEM    DISK    AGENTS  HUMANS  SPEC
vergil-user  lmf/mq-cluster-tooling —          local    Running  12    64GiB  300GiB  1       0       ok
vergil-user  lmf/mq-cluster-tooling cloud-x86  gcp      Running  16    64GiB  —       2       1       ok
vergil-user  lmf/mq-cluster-tooling rdqm-rhel  gcp      Stopped  8     32GiB  —       —       —       NEEDS-REBUILD
vergil-user  lmf/mq-cluster-tooling old-azure  azure    Running  8     32GiB  —       0       0       orphaned
```

The CPUS/MEM/DISK, AGENTS/HUMANS (process-tree classification, #99), BACKEND
(#199), and SPEC (`ok` / `NEEDS-REBUILD` / `orphaned` / `under`) semantics are
unchanged — they are now reported per instance. Enumeration remains O(instances)
(Lima `<identity>--*` instances + tofu state dirs), not O(checked-out repos), per
#99/#111. `list` degrades visibly without cloud creds (#199:
`unknown (no <provider> creds)`), per instance.

## Backward compatibility and migration

Fully backward compatible:

- A repo that names nothing has an empty `instances` namespace and resolves exactly
  as today (default instance = `[vm] ⊕ [vm.<identity>]`, base box if empty).
- Every existing slug is a valid one- or three-segment handle; the four-segment
  form is new and additive.
- `--name` is optional on every verb; omitting it preserves current behavior.

No migration of existing VMs or `identities.toml`/`vergil.toml` config is required.

## Security boundaries

The named-for-a-person/client use case can configure broader access (e.g. extra SSH
ingress) on a specific instance. This rides the existing seams rather than adding a
new class: the #99 repo-code-runs-as-root-in-a-credentialed-VM boundary and the
#199 credentialed-VM-on-a-public-IP boundary both still apply, **per instance** —
each instance composes its own profile and provisions independently, so a permissive
config on one instance does not widen another. The off-platform SSH allow-list stays
derived from the create-initiator's origin (#199), per instance; `0.0.0.0/0` remains
forbidden. No new register entry is required; the existing
[vergil-tooling #1369](https://github.com/vergil-project/vergil-tooling/issues/1369)
entries cover the seams, now at instance granularity.

## Testing

- **Offline (CI-safe).** `tofu validate`/`plan` assert the per-instance state-path
  and `vergil-instance` label contract; the interface-symmetry test (#199) still
  passes; the Lima regression suite proves the default/unnamed path is unchanged.
- **Composition / handle.** Assert four-part slug round-trips through
  `split('--')`; assert an invalid name (`--`, illegal chars) is rejected loudly;
  assert a named instance composes tiers 1–5 and the default composes 1–4; assert a
  repo with an empty `instances` namespace behaves identically to today.
- **Lifecycle / Problem 1.** Assert `destroy` targets recorded state, not the live
  profile: build a local instance, edit its overlay `backend` to off-platform,
  `destroy --name <name>` removes the **local** box (no orphan); assert the
  leftover from a dropped stanza shows `orphaned` in `list` and `destroy --name`
  removes it.
- **Gated real e2e (opt-in, costs money).** Extend `tests/e2e-off-platform.sh`
  (#199) to stand up two named instances for one repo, assert independent volumes
  and lifecycles, and keep the mandatory `trap … EXIT` teardown per instance.

## Acceptance criteria

1. `vrg-vm create/session/destroy/stop/start/rebuild mq-cluster-tooling --name X`
   operate on the named instance `X` independently of the default and of other
   named instances.
2. Two named instances for one `(identity, repo)` — e.g. a local arm64 default and
   an off-platform x86 `cloud-x86` — co-exist and run simultaneously, each with its
   own volume, state, and fingerprint.
3. A bare verb (no `--name`) resolves to the default instance exactly as today; a
   repo that names nothing is behaviorally identical to pre-change.
4. Editing a built instance's `backend` in place and running `destroy --name X`
   tears down the **originally built** box — never orphaning it — and a dropped
   stanza surfaces as `orphaned` in `list`, removable by `destroy --name X`.
5. An invalid instance name (containing `--` or illegal characters) is rejected at
   parse time with a clear error; no malformed slug is produced.
6. `vrg-vm list` shows the INSTANCE column with correct per-instance
   STATUS/footprint/AGENTS/HUMANS/BACKEND/SPEC; enumeration stays O(instances).
7. The full existing `tests/` suite is green — the Lima default path is unchanged.

## Implementation touch-points

**`vergil-vm` (this repo):**

- `opentofu/modules/{gcp,azure}/{volume,vm}` — add the `vergil-instance` label to
  the resource label set; ensure nothing assumes a repo-keyed (vs instance-keyed)
  volume; per-instance state-path is a tooling concern but the label contract is
  module-owned.
- `tests/` — offline assertions for the `vergil-instance` label + per-instance
  state separation; extend `e2e-off-platform.sh` for two co-existing named
  instances with the mandatory teardown trap; the existing Lima suite as the
  default-path regression guardrail.

**`vergil-tooling` (companion issue, to be filed):**

- Parse the `[vm.<identity>.instances.<name>]` namespace; validate names
  (`[a-z0-9-]+`, no `--`) loudly; compose tiers 1–5 (+6) per instance; reserve the
  per-name host-override slot.
- Four-part handle/slug naming and reversible `split('--')`; fold the handle into
  state paths and the `vergil-instance` label; fingerprint per instance (name is
  handle, not fingerprint content).
- `--name` across `create`/`session`/`rebuild`/`destroy`/`stop`/`start`/`update`/
  `destroy-volume`; default-instance resolution with no error path.
- **Recorded-state lifecycle dispatch**: `destroy`/`stop`/`start` resolve from the
  existing Lima instance or tofu state (provider recorded there), not the live
  profile; `create`/`rebuild`/`session`-preflight resolve from the composed profile.
- `vrg-vm list` INSTANCE column; per-instance orphan classification; O(instances)
  enumeration including four-segment slugs.

## Related

- **Parent models:** vergil-vm #99 (per-repo VM profiles — the cascade and the
  `--`-delimited naming this extends), #199 (off-platform backend — the `backend`
  key, tofu state, and persistent volume this makes per-instance), #131
  (nested-virt knob), #170 (port forwards), #111 (O(instances) `list`
  enumeration / orphan surfacing).
- **Companion (shared tooling):** vergil-tooling issue to be filed (mirrors #1412 /
  #1706).
- **Security register:** vergil-tooling #1369.
