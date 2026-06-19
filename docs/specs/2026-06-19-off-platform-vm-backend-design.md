# Off-Platform (Cloud) VM Backend Design

**Issues:**
- [vergil-vm #199 — Off-platform (cloud) VM backend: run a Vergil session on a native-x86 nested-virt cloud host](https://github.com/vergil-project/vergil-vm/issues/199)

**Date:** 2026-06-19

**Status:** Design (from brainstorming, 2026-06-19). Supersedes nothing; extends the
per-repo VM profiles model (#99).

**Spans two repositories.** Like the per-repo VM profiles work (#99), this feature
touches both `vergil-vm` (the OpenTofu modules, the extracted provisioning scripts,
the tests) and `vergil-tooling` (the `vrg-vm` backend dispatcher, profile parsing,
tofu invocation, SSH session, and credential injection on a remote peer). The
document lives in `vergil-vm` because issue #199 is filed here. Each touch-point
below is tagged with its owning repo. The `vergil-tooling` work is tracked in the
companion **[vergil-tooling #1706](https://github.com/vergil-project/vergil-tooling/issues/1706)**;
this spec is authoritative for the `vergil-vm`-owned contract and specifies the
tooling side **at the interface level** (what the dispatcher must call and what it
receives back).

## Problem

A Vergil session runs in a local macOS Lima VM. For most work that is correct. But
some repos genuinely need **native x86** — today the IBM MQ cluster lab
(`logical-minds-foundry/mq-cluster-tooling`). On Apple Silicon, x86_64 guests are
forced into **QEMU TCG software emulation** (no cross-arch KVM), so a *merely
running* queue manager costs roughly one host core and the lab's performance numbers
are meaningless. Full quantified evidence: mq-cluster-tooling
[#289](https://github.com/logical-minds-foundry/mq-cluster-tooling/issues/289) ("The
TCG Emulation Tax"); related [#276](https://github.com/logical-minds-foundry/mq-cluster-tooling/issues/276)
and [#283](https://github.com/logical-minds-foundry/mq-cluster-tooling/issues/283).

On a **native-x86 cloud host** the same lab runs as **nested KVM**, not TCG, and the
emulation tax disappears. The lab's pain was *instruction emulation*, not nesting —
a nested KVM guest on a native-x86 host runs at near-native speed, so nesting one
level deep in the cloud is fine.

This design adds an **opt-in, per-repo, off-platform VM backend**: a second backend
behind the same `vrg-vm` verbs, driving a remote native-x86 cloud host via OpenTofu
instead of a local Lima VM. The default identity stays on the local Mac; this is a
special-case backend for repos that need native x86, not a replacement.

## Goals

- **Same verbs, second backend.** `vrg-vm create/start/stop/destroy/rebuild/session`
  work for an off-platform VM exactly as they do for Lima, dispatched by a per-repo
  `backend` declaration.
- **Vergil-owned lifecycle via OpenTofu.** A per-provider OpenTofu module (instance +
  nested-virt + SSH key + cloud-init) gives the same one-command UX as local. Adding
  a provider = adding a module, no `vrg-vm` code change.
- **Nested KVM, not TCG.** Lab guests resolve `driver=kvm` on the cloud box.
- **Ephemeral VM, persistent volume.** The VM is data-less and rebuild-only; a single
  1:1 reattachable block volume (keyed to the repo) is the "laptop analog" persistent
  store and survives teardown.
- **Provider-agnostic, proven on two clouds.** Implement and run on both GCP and
  Azure to validate the module interface is genuinely provider-neutral, not
  accidentally GCP-shaped.
- **Local Lima default unaffected.** A repo with no `backend` declaration behaves
  exactly as today.
- **One provisioning truth.** The Lima and cloud backends provision from the same
  extracted, backend-neutral scripts — no drift between the two boxes.

## Non-goals

- **Bare metal.** Reserved for a possible future L1-KVM perf test; not the default
  (cost). Nested KVM on native x86 is near-native, so the bare-metal premium isn't
  justified for the lab's actual workload.
- **AWS.** Nested KVM on AWS forces `*.metal` instances; deprioritized on cost. The
  module interface keeps the path open (it is a per-module fact), but it is not built.
- **Shared filesystem with the Mac.** The cloud VM is a *peer*; it does its own git
  checkout. No network filesystem, no host mount.
- **Multiple VMs per repo.** Multiplexing is multiple sessions on the one VM, never
  multiple VMs — so no concurrent multi-attach.
- **In-place update mechanism.** Off-platform is rebuild-not-update by default (native
  x86 bootstrap is cheap again). A lightweight tooling-refresh script is noted as an
  easy fallback if rebuilds ever prove slow, but not built now.
- **Identity×repo volume scoping.** The volume is 1:1 with `(identity, org/repo)`;
  finer scoping is a possible later refinement, not built now.

## Repository boundary

| Concern | Owner |
|---|---|
| OpenTofu modules (`opentofu/modules/<provider>/{volume,vm}`) | **vergil-vm** |
| Backend-neutral provisioning scripts (`templates/provision/*.sh`) | **vergil-vm** |
| Cloud-init that invokes those scripts | **vergil-vm** (inside the modules) |
| Tests (module `validate`/`plan`, interface symmetry, Lima regression, gated e2e) | **vergil-vm** |
| `vrg-vm` backend dispatch (Lima vs off-platform) | **vergil-tooling (#1706)** |
| Profile parsing of the new keys, composition, fingerprint | **vergil-tooling (#1706)** |
| `tofu` invocation, state-path management, SSH session | **vergil-tooling (#1706)** |
| Provider-credential selection; GitHub App cred injection over SSH | **vergil-tooling (#1706)** |

This spec specifies the tooling side at the interface level; the mechanism is the
companion's.

## Phasing

The spec covers the whole abstraction; the implementation plan sequences it:

1. **Provisioning extraction.** Refactor `templates/agent.yaml` to source
   `templates/provision/*.sh`. The Lima path stays behaviorally identical; the
   existing `tests/` suite is the regression guardrail. No cloud work yet. This is
   independently shippable and de-risks everything downstream.
2. **GCP backend, end-to-end.** Volume module + vm module + dispatch + SSH session +
   cred injection. Proves the loop: `create`/`session`/`destroy`, `driver=kvm`
   resolves, volume survives teardown.
3. **Azure backend.** A second module against the *same* interface — the validation
   that the contract is provider-agnostic, not GCP-shaped. This is an explicit goal,
   not a stretch.

AWS `*.metal` stays noted, not built.

## Profile schema and composition

The off-platform backend rides the **same #99 cascade** (`[vm]` ⊕ `[vm.<identity>]`,
with the `identities.toml` host-override tier on top). It adds a small set of keys;
their presence with `backend = "off-platform"` is what flips resolution from the Lima
driver to the OpenTofu driver.

### New `[vm.<identity>]` keys (source-controlled in the consuming repo's `vergil.toml`)

```toml
# logical-minds-foundry/mq-cluster-tooling/vergil.toml
[vm.vergil-user]
backend  = "off-platform"     # default "local" (Lima). Only this value changes the driver.
provider = "gcp"              # "gcp" | "azure" — selects the OpenTofu module
region   = "us-central1"      # provider-native region string
instance = "n2-standard-16"   # provider-native nested-virt-capable instance type
volume   = "300GiB"           # PERSISTENT volume size (created once, reused, outlives the VM)
nested   = true               # already exists (#131); means /dev/kvm here too

cpus     = 12                 # still meaningful as a request / sanity floor;
memory   = "64GiB"            #   the instance type is authoritative on cloud
packages = [ ... ]            # composed + provisioned identically to Lima
```

`disk` (the #99 Lima single-disk knob) is **not** a cloud knob and is ignored on the
off-platform path: on cloud there are two disks with opposite lifecycles — the
ephemeral VM's **boot disk** (a fixed module default, e.g. 30 GiB, dies with the VM)
and the **persistent `volume`** (declared above, outlives the VM). Only `volume` is
author-facing.

### Composition rules (extending #99, not replacing)

- `backend`/`provider`/`region`/`instance`/`volume` are **scalars, last-wins** through
  the same precedence chain (built-in → identity → `[vm]` → `[vm.<identity>]` →
  `identities.toml` host-override).
- `backend = "off-platform"` **requires** `provider`, `region`, `instance`, and
  `volume`. The composer hard-errors — loudly, no silent default — if any is missing.
  (`volume` no longer falls back to `disk`; `disk` is not a cloud knob.)
- `packages`, `nested`, `port_forwards`, `stale_days`, and the fingerprint all behave
  exactly as #99/#131/#170 define. Because provisioning is backend-neutral (see
  "Provisioning extraction"), a profile's package list yields the *same* box on Lima
  or cloud.
- **`instance` is authoritative over `cpus`/`memory` on cloud.** You cannot ask a
  cloud for "12.5 vCPU". `cpus`/`memory` stay in the spec as human-readable intent and
  feed the under-provisioning sanity check: if the chosen `instance` is smaller than
  the declared `cpus`/`memory`, `session` warns loudly (the #99 override-floor
  pattern) rather than silently running undersized.

### Resolution, naming, and fingerprint

- The existing `(identity, org/repo) → exactly one VM` rule is unchanged. The instance
  name stays `vergil-user--logical-minds-foundry--mq-cluster-tooling`. For
  off-platform it is also the **OpenTofu state key** and the **cloud resource label
  set** (`vergil-identity`, `vergil-repo`) — the deterministic naming that makes state
  recoverable (see "OpenTofu module interface").
- The **fingerprint** now includes `backend`/`provider`/`region`/`instance`/`volume`,
  so flipping a repo from Lima to cloud, or resizing the instance, trips
  `NEEDS-REBUILD` exactly as a package change does today.
- `vrg-vm list` gains a **BACKEND** column (`local` / `gcp` / `azure`) so the fleet is
  legible at a glance.

The **default stays local Lima** — a repo with no `backend` key is untouched.
`vergil-audit` against an off-platform repo composes to the same cloud backend but at
whatever (typically smaller) `instance` its role overlay declares, mirroring the #99
audit-box pattern.

## Provisioning extraction (backend-neutral scripts)

This refactor lets one provisioning truth serve both backends, and is the phase-1
deliverable.

### What moves

The provisioning logic currently embedded in `agent.yaml`'s `provision:` blocks is
extracted into idempotent shell scripts under `templates/provision/`. But the
extraction is **not** a flat ordered list of root scripts, and modeling it that way
(an earlier draft of this spec did) is wrong: `agent.yaml`'s provisioning spans four
Lima execution modes — `boot` (pre-everything: the logind VT fix), `system` (root),
`user` (runs as the unprivileged Lima user — this is where **uv + vergil-tooling**
install, and the `.zshenv`/identity-prompt setup live), and `readiness` (Lima's
"VM is ready" gate) — and it carries **three independent first-boot guards**
(`provisioned.base`, `provisioned.uv`, `provisioned.profile`), with some blocks (the
time block) deliberately running on **every** boot. `mode: user` and
`mode: readiness` have no direct cloud-init equivalent, so "source the same scripts in
order" understates the problem: the cloud backend must *synthesize* the user-context
and readiness semantics Lima provides for free, or it will ship a box missing
vergil-tooling or one that reports ready before provisioning finished.

So each script declares a **context + cadence**, and the readiness signal is explicit.

### The provisioning contract: context, cadence, readiness

Each `templates/provision/*.sh` script declares two attributes (as a header comment /
manifest the backends read):

- **context** — `root` (privileged) or `user` (runs as the unprivileged session user).
- **cadence** — `once` (first-boot-only, gated by one of the named markers below) or
  `boot` (re-run every boot, must be safely re-entrant).

The real block inventory (replacing the placeholder six of the earlier draft):

| Script | Context | Cadence | Guard | What it does |
|---|---|---|---|---|
| `00-logind-fix.sh`   | root | boot | — | the `mode: boot` VT/logind fix (must run before anything that logs in) |
| `10-base.sh`         | root | once | `provisioned.base` | apt base, gh, Node, Claude Code, yq, zsh, sshd AcceptEnv, PATH/`managed-settings.json` autoupdater disable (#85/#110) |
| `20-packages.sh`     | root | once | `provisioned.base` | `EXTRA_PACKAGES`/`APT_REPOS`/`VAGRANT_PLUGINS` layering |
| `30-nested-virt.sh`  | root | once | `provisioned.base` | `/dev/kvm` verification — fails loudly if absent (the `driver=kvm` guarantee) |
| `40-minimize.sh`     | root | once | `provisioned.base` | service-surface minimization (#78) |
| `50-toolchain.sh`    | **user** | once | `provisioned.uv` | uv + shell/identity config (`.zshenv`/`VRG_IDENTITY_MODE` (#149) + identity-aware prompt (#154/#171)). `vergil-tooling` itself installs later, at credential-injection time (`vrg-vm-init.sh`), not in this block. |
| `60-time.sh`         | root | **boot** | — | chrony config + timesyncd handoff + optional NTP serving (#187) — re-runs each boot so serving tracks the current profile |
| `90-profile.sh`      | root | once | `provisioned.profile` | stamp `/etc/vergil/vm-spec.fingerprint`; register declared apt repos; libvirt group membership |

The `mode: readiness` Lima gate is **not** a script — it is the backend-specific
"provisioning finished cleanly" signal (see below).

### How each backend realizes context, cadence, and readiness

Inputs flow through a single sourced env file (`/etc/vergil/provision.env`) instead of
Lima's `{{.User}}` templating or `.param.*` injection — the one thing each backend
writes differently:

| Input | Lima writes it via | Cloud writes it via |
|---|---|---|
| `VERGIL_USER`, `HOME` | resolve from `{{.User}}` / `getent` | cloud-init default user |
| `EXTRA_PACKAGES`, `APT_REPOS`, `VAGRANT_PLUGINS`, `NESTED_VIRT`, `PORT_FORWARDS`, `SPEC_FINGERPRINT` | `--set=.param.*`, written to the env file in a `mode: boot` shim | OpenTofu templates them into cloud-init, which writes the env file |

Context + cadence + readiness mapping:

- **Lima** (`agent.yaml`): keeps the native modes — a `mode: boot` shim writes
  `provision.env`, then each script runs under the mode matching its declared context
  (`root`→`mode: system`, `user`→`mode: user`), and `mode: readiness` stays Lima's
  readiness gate. Cadence is enforced by the script's own first-boot guard. Scripts are
  fetched onto the box at template-fetch time (the template is tag-versioned, so the
  scripts version alongside it).
- **Cloud** (OpenTofu module): cloud-init `write_files` drops `provision.env` + the
  scripts; `runcmd` runs each in declared order, mapping context as
  `root`→direct `runcmd` and `user`→`runcmd` with `sudo -iu "$VERGIL_USER"`. There is
  no native readiness gate, so the module **synthesizes** one: `create` polls
  `cloud-init status --wait` over SSH and then checks the fingerprint marker exists —
  a non-zero cloud-init status or a missing marker is a **hard failure** of `create`
  (no-silent-failures), mirroring Lima refusing to mark a half-provisioned box ready.
  The `/dev/kvm` check is the **same** `30-nested-virt.sh`, so "resolved `driver=kvm`,
  not TCG" is verified identically on both paths.

### Invariants preserved

- **First-boot-only markers (#177).** The three guards (`provisioned.base`,
  `provisioned.uv`, `provisioned.profile`) are each stamped **last** in their owning
  block, only after its steps succeed — so a failed install never leaves the box
  marked provisioned. Both backends honor "install once, fail loudly, never mark a
  half-provisioned box ready"; the cloud readiness synthesis above is what enforces
  "fail loudly" where Lima's `mode: readiness` does on the local path.
- **Lima behavior is unchanged.** The existing `tests/` suite (`test_base.sh`,
  `test_nested_virt.sh`, `test_services.sh`, `test_tools.sh`, `test_vergil.sh`, and the
  e2e scripts) is the regression guardrail. Phase 1 is not done until they are all
  green against the refactored template. The extraction is a *pure refactor* of the
  Lima path — no behavior change — which is exactly why it ships first.
- **Mount-agnostic.** The scripts must not assume a `/projects` mount (cloud has none).
  Anything mount-specific stays out of these scripts and lives in the backend layer
  (see "Persistent volume").

## OpenTofu module interface

This is the provider-agnostic contract — what Azure (phase 3) must satisfy unchanged
to prove the abstraction is not GCP-shaped.

### Two modules per provider, two local states

```
opentofu/
  modules/
    gcp/
      volume/     # persistent block volume — created once, long-lived
      vm/         # ephemeral instance + attach + cloud-init
    azure/
      volume/
      vm/
```

State lives locally, keyed by instance name and provider:

```
~/.config/vergil/tofu/<identity>--<org>--<repo>/<provider>/
  volume.tfstate   # precious; re-importable from labels
  vm.tfstate       # ephemeral
```

This matches the fleet-of-one deployment: no remote-bucket bootstrap chicken-and-egg,
no always-on state cost. Because resource names and labels are deterministic from
`(identity, org/repo)`, a lost `vm.tfstate` is harmless (the VM is ephemeral — just
`create` again) and a lost `volume.tfstate` is recoverable by `tofu import` against
the label-matched volume.

### The provider-agnostic interface

Every provider's modules expose the **same** variables and outputs, so the dispatcher
is provider-blind.

`volume` module:

| Direction | Name | Meaning |
|---|---|---|
| in | `name` | `<identity>--<org>--<repo>` (also the label set `vergil-identity`/`vergil-repo`) |
| in | `region`, `size_gib` | from composed spec |
| out | `volume_id` | provider-native handle the vm module attaches |
| out | `zone` | the **zone the volume actually landed in** — chosen once at first `create`, recorded in `volume.tfstate` and as a label |

A cloud block volume is **zonal**: a disk in `us-central1-a` only attaches to an
instance in `us-central1-a`. So the volume owns its zone, and the VM **follows** it —
otherwise the "destroy VM → next VM reattaches" loop fails intermittently when the new
instance lands in a sibling zone. `region` stays the human-facing knob; the zone is a
derived property of the volume.

`vm` module:

| Direction | Name | Meaning |
|---|---|---|
| in | `name`, `instance_type`, `nested` | composed spec |
| in | `zone` | the volume's zone (from the volume module's `zone` output) — pins the instance to the volume |
| in | `volume_id` | from the volume module's output |
| in | `boot_disk_gib` | fixed module default for the ephemeral boot disk (not author-facing) |
| in | `ssh_public_key` | Vergil-managed keypair for this instance |
| in | `provision_env`, `provision_scripts` | the env file + `provision/*.sh`, templated into cloud-init |
| out | `host`, `ssh_user` | public IP/DNS and login user `session` SSHes to |

Provider-native specifics live **inside** the module, never leaking out: GCP's
nested-virt is `advanced_machine_features.enable_nested_virtualization = true` on a
standard family; Azure's is a nested-capable SKU; AWS would need `*.metal` — which is
*why* it is deprioritized, and the interface makes that a per-module fact, not a core
concern. The dispatcher passes only `instance_type` + `nested = true` and trusts the
module to realize it.

### Two-state lifecycle in practice (tooling, #1706)

- `create`: `tofu apply` **volume** (idempotent — no-op if it exists) → read
  `volume_id` + `zone` → `tofu apply` **vm** pinned to that zone with that volume.
- `destroy`: `tofu destroy` on **vm state only**. Volume state is never in scope —
  structurally impossible to delete by a teardown.
- `rebuild`: `destroy` vm + `apply` vm (volume untouched → data survives, the whole
  point).
- a separate explicit **`destroy-volume`** verb (or `destroy --volume`) is the *only*
  path that tears down the volume state — guarded, never the default.

### Host dependency: OpenTofu + providers (pinned, preflighted)

The off-platform path adds `tofu` and the provider plugins as host dependencies on the
Mac — the off-platform analog of the tag-versioned Lima template. They are **pinned**,
not assumed: each module declares `required_version` for OpenTofu and
`required_providers` with `~>` constraints, and a committed `.terraform.lock.hcl` pins
provider versions so two `apply`s a week apart behave identically (the reproducibility
posture #99 already takes). The dispatcher **preflights** `tofu` presence and version
before any cloud verb and fails with a clear remediation message ("install OpenTofu
≥ x.y") rather than an opaque stack trace (no-silent-failures).

## Lifecycle verb mapping

Every `vrg-vm` verb keeps its meaning; the dispatcher routes to Lima or to the
OpenTofu+SSH path based on the composed `backend`.

| Verb | Off-platform behavior |
|---|---|
| `create [org/repo]` | `tofu apply` **volume** (idempotent) → `tofu apply` **vm** with `volume_id` + cloud-init carrying `provision.env` + scripts. Then GitHub App cred injection over SSH and volume bootstrap. Blocks until cloud-init `done` + fingerprint stamped — a failed provision fails `create` (no half-ready box, mirroring Lima). |
| `session [org/repo]` | Preflight gate (VM exists? fingerprint matches? under-provisioned?) exactly as #99 — then **SSH into `host` as `ssh_user`** instead of `limactl shell`. In-VM session resolution/naming is unchanged (it runs in-guest). |
| `stop` | Provider stop/deallocate of the instance (not destroy) — pauses compute billing while the volume persists. The "keep it overnight" affordance. |
| `start` | Starts the stopped instance; re-runs the preflight gate. |
| `destroy [org/repo]` | `tofu destroy` on **vm state only**. Volume + its state survive. Routine end-of-day teardown. |
| `rebuild [org/repo]` | `destroy` vm → `create` vm against the **existing** volume. Reproduces the data-less box from the composed spec; volume data (checkout + `.claude` + `build/`) reattaches intact. |
| `destroy-volume [org/repo]` | **New, guarded verb.** The only path that tears down the volume state and deletes the persistent disk. Requires explicit confirmation; never implied by `destroy`. |
| `update [org/repo]` | Off-platform is rebuild-not-update by default → `update` maps to `rebuild`. A lightweight in-place tooling refresh is a noted fallback if rebuilds prove slow, not built now. |
| `list` | Adds the **BACKEND** column. With cloud creds present, off-platform rows query the cloud for running/stopped status and occupancy (AGENTS/HUMANS process-tree classification (#99) runs in-guest over SSH, unchanged). **Without creds, `list` degrades visibly** — the off-platform row still shows from local state/profile with status `unknown (no <provider> creds)`; `list` never errors because a cloud isn't authed, and never silently hides a possibly-running row. |

Notes:

- **`stop`/`start` are genuinely useful here** — the "overnight long test" affordance
  the issue calls out (keep the volume *and* the configured instance, just pause
  compute). `destroy` remains the default daily cadence.
- **Concurrency stays "multiple sessions on one VM."** There is never a second VM per
  repo, so no multi-attach and no network FS. The dispatcher refuses to stand up a
  second instance for an `(identity, org/repo)` that already has a running one.

## Persistent volume

The volume is the "laptop analog" — the one piece of state that outlives the VM.

### Mount

The volume attaches at a fixed in-VM path (e.g. `/vergil`). The dispatcher passes
`volume_id`; cloud-init formats-on-first-use and mounts it (fstab/systemd) before
provisioning's user-facing steps. The filesystem is created **only if the disk is
blank** — a reattach must never reformat. Loud guard: if the disk has a filesystem but
not our label, abort rather than risk data.

### Layout

```
/vergil/
  projects/<org>/<repo>/        # the VM's OWN git checkout(s) — the dev/projects analog
                                #   (the gitignored build/ lab working space lives here)
  claude/                       # the .claude config (session continuity/transparency)
```

The `<org>/<repo>` tree is kept for **sanity/convenience only** — strict path-parity
with the Mac is no longer required now that the VM is a peer, not a child of the
laptop. `.claude` lives on the volume so session history and config survive teardown
(the transparency property the issue cares about). `build/` (the #99 lab working
space) lives on the volume too, so heavy lab artifacts persist across VM teardown and
a `rebuild` reconstructs only the box, not the lab.

### First-time bootstrap vs reattach

The distinguishing signal is whether `/vergil/projects/<org>/<repo>` already holds a
checkout:

- **Fresh volume (first `create`):** the VM does its **own `git clone`** of the repo
  into `/vergil/projects/<org>/<repo>` (using the injected GitHub App creds), and seeds
  an empty `/vergil/claude/`. This is the issue's "peer does its own checkout, the
  better model anyway."
- **Reattach (every later `create`/`rebuild`):** mount, detect the existing checkout,
  **do not clone** — `git fetch`/status to surface drift, leave working state intact.
  `.claude` is already there.

`.claude` is **seeded empty on a fresh volume**, not copied from the Mac: the cloud VM
is a peer with its own session history, and copying the Mac's `.claude` would conflate
two machines' state.

### No shared filesystem with the Mac

There is no `/projects` host mount on cloud. The base provisioning scripts are
mount-agnostic; the checkout/`.claude` wiring is a **backend-layer step** that runs
after provisioning, only on the off-platform path.

## Credentials

Two distinct flows, both runtime-injected, never committed.

### Cloud provider credentials (GCP/Azure) — consumed by OpenTofu on the Mac

Sourced from the provider SDK default chain at `tofu` invocation time
(`GOOGLE_APPLICATION_CREDENTIALS` / `gcloud` ADC; `az login` / `ARM_*` for Azure). The
dispatcher passes them to `tofu` as process environment — never written into the repo,
the profile, or committed tfvars. They live only on the operator's Mac and in the tofu
process env; local state may reference resource ids but not the cloud creds
themselves. This is **vergil-tooling (#1706)** territory — the dispatcher owns
provider-auth selection, paralleling how it already selects GitHub App creds per
identity. The spec records the *contract* (creds arrive via the provider default chain
at apply time); the mechanism is the companion's.

### GitHub App credentials — injected into the remote VM over SSH

Today `scripts/vrg-vm-init.sh` injects App creds into a Lima instance. For
off-platform it does the same thing to a remote SSH host. The injection logic (read
the identity's App id + private key, configure git HTTPS, dynamic installation-token
acquisition via `vrg-git`/`vrg-gh`) is **unchanged** — only the transport changes
(SSH to `host`/`ssh_user` vs `limactl`). Generalizing that transport is the **#1706**
companion's job (the "`vrg-*` wrapper / credential-selection on a remote peer" the
issue calls out). The App private key is **injected per-`create`, not persisted on the
volume** — a destroyed VM leaves no key behind.

### Security boundary

Repo-declared provisioning runs as root in a credentialed VM — the #99 trust boundary
still applies, now with the added surface that the VM is **internet-reachable** (public
IP for SSH). Two concrete controls, because "lock it down" stated abstractly drifts
toward too-wide:

- **SSH allow-list derived from the create-initiator's origin address(es).** At
  `create` time we already know where the operation is coming from — the operator's
  current public address(es). The module sets the SSH ingress rule to exactly that set
  (a `/32` per address), and **re-applies it on every `create`**, so the allow-list
  naturally tracks wherever the operator is working from without any hand-maintained
  CIDR. sshd is **key-only** (passwords disabled). `0.0.0.0/0` is forbidden — never a
  fallback. A provider-native bastion / tunnel (GCP IAP, Azure Bastion) that removes
  the open port entirely is logged as the **hardening path** (it cuts against the
  provider-agnostic interface, so it is future work, not the first cut).
- **App key on the ephemeral boot disk, never the volume.** The injected GitHub App
  private key lands on the **ephemeral boot disk** (mode `600`, owned by the session
  user), so `destroy` (which deletes the boot disk) destroys the key. It is never
  written to the persistent `volume`, so a surviving volume never carries a key.

The "credentialed VM on a public IP" seam is logged into the strategic
security-boundary register
([vergil-tooling #1369](https://github.com/vergil-project/vergil-tooling/issues/1369))
alongside the existing entries (the repo-root-in-credentialed-VM seam, GitHub
permission-granularity gaps), with the bastion/tunnel option as its tracked hardening.

## Testing

Three tiers, scaled to cost:

- **Offline (CI-safe, default).** `tofu validate` + `tofu plan` against both modules
  with fake credentials/vars asserts the interface contract holds and that the
  volume/vm states are correctly separated. The provisioning scripts get shellcheck +
  the **Lima regression suite** (the existing `tests/` prove the extracted scripts did
  not change Lima behavior).
- **Interface-symmetry test.** A mechanical assertion that the GCP and Azure modules
  expose **identical** variable/output names — the guard that the abstraction stays
  provider-agnostic.
- **Gated real e2e (manual/opt-in, costs money).** `tests/e2e-off-platform.sh`
  actually stands up a GCP (then Azure) instance, asserts `driver=kvm` resolves (not
  TCG), the volume survives `destroy`+`create`, and cred injection works. Off by
  default, never in CI, explicitly invoked. **Every real instance is wrapped in a
  shell `trap … EXIT` that always `tofu destroy`s the vm state** — a failed or aborted
  (Ctrl-C) test can never leak a paid instance. This trap is the one *mechanical*
  cost guard; see "Operational discipline" below for the rest.

## Operational discipline (cost)

A running off-platform VM costs real money; the design's cost story rests on
**ephemerality**, not on automation. We deliberately do **not** build an auto-reaper
or a billing-state surface in `list` (rejected as over-machinery for fleet-of-one):
the guard is documented discipline plus the one mechanical backstop above.

- **Default cadence is destroy-at-end-of-day.** `destroy` (vm state only; volume
  survives) is the routine teardown. `stop` is the deliberate "keep it overnight for a
  long test" exception, not the default.
- **The e2e teardown trap is mandatory** (above) — the only place automation enforces
  teardown, because un-trapped real-cloud tests are a money bug.
- If forgotten-instance spend proves to be a real problem in practice, a staleness
  nudge (reusing the #99 `stale_days` mechanism) or an opt-in reaper is an easy
  follow-up — not built now.

## Acceptance criteria

1. `vrg-vm create/session/destroy` work against a nested-virt instance on **both GCP
   and Azure** via the OpenTofu modules.
2. Lab guests resolve **`driver=kvm`**, not TCG — verified by `30-nested-virt.sh`'s
   `/dev/kvm` check passing on the cloud box.
3. The VM is **ephemeral/rebuild-only**; `destroy` then `create` reattaches the volume
   with the repo checkout + `.claude` intact; the volume's tofu state is never in
   `destroy`'s scope.
4. **The local Lima default is unaffected** — a repo with no `backend` key behaves
   identically; the full `tests/` suite is green against the refactored template.
5. The GCP and Azure modules expose an identical interface (the symmetry test passes).
6. Phase 1 (provisioning extraction) is independently shippable and green before any
   cloud work begins.

## Implementation touch-points

**`vergil-vm` (this repo):**

- `templates/provision/*.sh` — the extracted, idempotent, backend-neutral provisioning
  scripts driven by `/etc/vergil/provision.env`, each declaring its **context**
  (`root`/`user`) and **cadence** (`once`/`boot`); the real block inventory (logind-fix,
  base, packages, nested-virt, minimize, toolchain/uv+vergil-tooling, time, profile)
  with its three first-boot guards.
- `templates/agent.yaml` — refactored so the Lima `provision:` blocks write
  `provision.env` and run each script under the mode matching its declared context
  (`root`→`system`, `user`→`user`), readiness via `mode: readiness`; behavior unchanged
  (existing `tests/` are the guardrail).
- `opentofu/modules/{gcp,azure}/{volume,vm}` — the two-module-per-provider OpenTofu
  modules implementing the provider-agnostic interface (volume owns its `zone`; vm
  follows it; ephemeral boot disk is a fixed module default); cloud-init invokes the
  same provisioning scripts (`root`→`runcmd`, `user`→`sudo -iu`) and **synthesizes
  readiness** via `cloud-init status --wait` + fingerprint-marker check; SSH ingress
  set to the create-initiator's origin address(es), key-only, never `0.0.0.0/0`;
  App key on the ephemeral boot disk only; pinned `required_version`/`required_providers`
  + committed `.terraform.lock.hcl`.
- `tests/` — offline `tofu validate`/`plan`; interface-symmetry assertion; gated
  `e2e-off-platform.sh` with a mandatory `trap … EXIT` teardown; the existing Lima
  suite as the phase-1 regression guardrail.

**`vergil-tooling` ([#1706](https://github.com/vergil-project/vergil-tooling/issues/1706)):**

- Backend dispatch (Lima vs off-platform) keyed on composed `backend`; preflight that
  `tofu` is present at the required version (clear remediation on failure).
- Parse and compose `backend`/`provider`/`region`/`instance`/`volume`; hard-error on
  any missing required key (now including `volume`); `disk` ignored on cloud; fold the
  keys into the fingerprint; the `instance`-vs-`cpus`/`memory` under-provisioning
  warning.
- `tofu` invocation + local state-path management (two states per
  `(identity, org/repo, provider)`); read the volume's `zone`/`volume_id` and pin the
  vm to them; the volume bootstrap-vs-reattach step.
- SSH `session` transport; resolve the create-initiator's origin address(es) for the
  ingress rule; GitHub App cred injection over SSH onto the ephemeral boot disk;
  provider-credential selection from the SDK default chain.
- `vrg-vm list` BACKEND column with graceful degradation when cloud creds are absent
  (`unknown (no <provider> creds)`); `destroy-volume` verb; `update`→`rebuild` mapping
  for off-platform.

## Pushback resolutions (2026-06-19)

A structured pushback review (paad:pushback) ran against the first draft. No
source-control conflicts; the spec is appropriately phased and not splittable. Six
findings, all folded into the body above:

1. **Provisioning extraction underspecified across execution contexts** (serious) —
   replaced the flat "ordered scripts" model with an explicit **context + cadence +
   readiness contract**, the real block inventory (including the `mode: user`
   uv/vergil-tooling install) and its three first-boot guards, and a cloud readiness
   synthesis (`cloud-init status --wait` + fingerprint check). See "Provisioning
   extraction".
2. **No guard against orphaned paid instances** (serious) — chose documented
   discipline + a mandatory e2e `trap … EXIT` teardown; deliberately **no** auto-reaper
   or billing surface in `list`. See "Operational discipline".
3. **Volume zonal pinning + boot/persistent disk conflation** (moderate-serious) — the
   volume **owns its zone** (state + label) and the vm **follows** it; `volume` is the
   persistent-disk size (now required), the ephemeral boot disk is a fixed module
   default, and `disk` is not a cloud knob. See "Profile schema" + "OpenTofu module
   interface".
4. **Public-IP SSH exposure + key-at-rest window** (moderate, security) — SSH ingress
   is derived from the **create-initiator's origin address(es)**, re-applied each
   `create`, key-only, never `0.0.0.0/0`; the App key lives on the **ephemeral boot
   disk** only. Bastion/tunnel logged as hardening in #1369. See "Security boundary".
5. **OpenTofu as an unmanaged host dependency** (minor-moderate) — pinned
   `required_version`/`required_providers` + committed `.terraform.lock.hcl`, with a
   dispatcher preflight. See "Host dependency".
6. **`list` without cloud creds** (minor) — degrades visibly to
   `unknown (no <provider> creds)`; never errors, never hides a row. See "Lifecycle
   verb mapping".

## Related

- **Evidence:** mq-cluster-tooling #289 (TCG Emulation Tax), #276, #283.
- **Parent model:** vergil-vm #99 (per-repo VM profiles — the cascade this extends),
  #131 (nested-virt knob), #170 (port forwards), #177 (first-boot-only provisioning).
- **Synergistic:** vergil-vm #186 (golden image / fast rebuild), #88 (persisting data
  / mount).
- **Companion (shared tooling):** vergil-tooling #1706.
- **Security register:** vergil-tooling #1369.
