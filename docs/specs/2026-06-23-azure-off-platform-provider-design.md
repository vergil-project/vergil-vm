# Azure Off-Platform Cloud Provider Design

**Issues:**
- [vergil-vm #250 — Add Azure as a second off-platform cloud provider (clone of the GCP modules)](https://github.com/vergil-project/vergil-vm/issues/250)
- Companion vergil-tooling issue (consumer side) — to be filed (analog of vergil-tooling #1706).

**Depends on / coordinates with:**
[vergil-vm #242 — multiple VM instances per repo](https://github.com/vergil-project/vergil-vm/issues/242)
(tooling companion #1831). #242 is an in-flight, same-week design that replaces the
1:1 `(identity, org, repo) → one VM` rule with **several named instances per repo**,
each with its own state, lifecycle, and volume. When #1831 lands,
`cloud_resource_name` gains an instance dimension and `var.name` becomes the
**per-instance handle**. This spec is written against that model: every Azure resource
set is keyed off `var.name` as a per-*instance* identifier, not per-repo. See
"Resource keying & the #242 dependency" below.

**Date:** 2026-06-23

**Status:** Design (from brainstorming, 2026-06-23; pushback review 2026-06-24).
Extends the off-platform VM backend (#199); adds a second provider without
restructuring it. Coordinates with the named-instances work (#242).

**Spans two repositories.** Like the GCP off-platform work (#199), this feature
touches both `vergil-vm` (the OpenTofu modules, the cloud-init/provisioning deltas,
the tests) and `vergil-tooling` (the `vrg-vm` backend dispatcher, transport, tofu
invocation, SSH session, credential injection, capacity/zone handling). This document
lives in `vergil-vm` because issue #250 is filed here. It is **authoritative for the
`vergil-vm`-owned contract** (the Azure modules and their conformance to
`opentofu/interface.json`) and specifies the `vergil-tooling` side **at the interface
level** — what the dispatcher must call and what it receives back. The tooling work is
tracked in a companion issue.

---

## Problem

The off-platform backend (#199) runs a Vergil session on a native-x86 nested-virt
cloud host instead of a local macOS Lima VM, for repos that genuinely need native x86
(today: the IBM MQ cluster lab). It currently supports exactly one provider, GCP.

GCP capacity has been an ongoing, day-long operational problem: after a
`destroy`/`recreate` cycle we have repeatedly been unable to re-acquire the same
nested-virt-capable VM in our zone. A single-provider off-platform backend is a
**single point of failure for capacity**. The remedy is a second provider the same
workload can fall back to.

**Success criterion.** The real measure is not feature parity — it is "can we reliably
acquire a nested-virt-capable size in a reachable region/zone, and fall back across
zones when the first is full." Azure's value is being a second place to land the same
session.

---

## Architecture: pluggable by design (unchanged)

The #199 design states the governing principle: *"Adding a provider = adding a module,
no vergil-vm code change."* This spec honors that. We add a provider tree; we do not
restructure the existing one.

```text
opentofu/
  interface.json                      ← +1 vm variable (ssh_public_key); otherwise same
  modules/
    gcp/{vm,volume}/                   ← vm gains an ignored ssh_public_key var (1 line)
    azure/
      vm/      {main,variables,outputs,versions}.tf, cloud-init.yaml(.skel)
      volume/  {main,variables,outputs,versions}.tf
```

The contract both providers satisfy (`interface.json` after the one addition — see
"One honest interface addition" below; `ssh_public_key` is the only new key):

```json
{
  "volume": { "variables": ["name","region","zone","size_gib","labels"],
              "outputs":   ["volume_id","zone"] },
  "vm":     { "variables": ["name","zone","instance_type","nested","volume_id",
                            "boot_disk_gib","ssh_user","provision_env","labels",
                            "ssh_public_key"],
              "outputs":   ["host","ssh_user"] }
}
```

### The carrier trick: keep `interface.json` frozen

Azure introduces a concept GCP lacks — the **resource group** — plus explicit
networking (VNet/subnet/NSG/NIC) that GCP's implicit `default` network provided for
free. The fixed interface has no key for any of this. We do not add one.

Instead we exploit the fact that an Azure managed-disk **resource ID** is a fully
qualified path:

```text
/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/disks/<name>
```

The `volume` module returns this resource ID as `volume_id`. The `vm` module already
receives `volume_id`; it parses the subscription and resource group out of it and
`data`-sources the conventionally-named VNet, subnet, and NSG within that RG. This is
the Azure analog of GCP passing the disk `self_link` — the resource-group dimension
needs no new interface key.

### One honest interface addition: `ssh_public_key`

The carrier trick covers the resource group because the RG is *derivable* from the disk
ID (no new information). The SSH key is different: an `azurerm_linux_virtual_machine`
**requires an SSH public key at create time**, and that key is genuinely new information
with no existing channel to carry it. GCP needed none — IAP injects ephemeral keys — so
the original interface has no slot, and `tests/check-opentofu-contract.sh` enforces the
variable/output sets **exactly** (no extras) across *all* providers. Rather than smuggle
the key through `labels` or `provision_env`, we make one honest addition:

- `interface.json` gains **one** vm variable: `ssh_public_key`.
- Both providers declare it. **Azure** consumes it (`admin_ssh_key`). **GCP** declares it
  with `default = ""` and ignores it — a one-line, behavior-neutral change to the GCP vm
  module, required only so the strict contract test stays green for both providers.
- The tooling generates and persists the keypair, passes the **public** key in via this
  variable, and keeps the **private** key local for the `SshTransport`. No private key
  ever enters tofu state or module outputs.

This is the only interface change. Everything else (the RG, networking) rides the
existing keys.

### Resource keying & the #242 dependency

Every Azure resource set in this design is keyed off `var.name`, and **`var.name` is
the per-instance handle** (#242), not a per-repo identifier. So the resource group,
VNet/subnet/NSG, managed disk, and VM are **one set per named instance**: bring up a
second named instance in the same repo and it gets its own RG (`<name>-rg`), its own
networking, its own disk, and its own VM — fully self-contained, with no shared
lifecycle. This matches #242's "distinct state, distinct volumes" intent and keeps the
carrier trick clean (the RG stays 1:1 with the disk, so parsing the RG out of
`volume_id` is unambiguous). On Azure this is cheap — VNets and resource groups carry
no standing cost; only the VM and disk do.

**Dependency (satisfied).** #1831 has **landed**: `cloud_resource_name(slug)` now takes a
per-instance slug, and `OffPlatformBackend` keys `self.name`/`self.state_key` off that
slug (`self.instance_name` → `self.slug` → `self.name`). So the per-instance handle the
Azure modules need already exists — the tooling passes it as the module `name`, and the
isolation guarantee above is fully realized today. Nothing in the Azure module contract
depends on the slug's internal shape — only that `name` is a per-instance identifier.

---

## Component: `azure/volume` module (long-lived state)

Owns the **per-instance resource group and all long-lived scaffolding** (one set per
named instance — see "Resource keying & the #242 dependency"). Created once; the gated
`destroy-volume` verb is the only routine path that tears it down.

Resources:
- `azurerm_resource_group` — name derived from `var.name` (e.g. `<name>-rg`).
- `azurerm_virtual_network` + `azurerm_subnet` — conventional names derived from
  `var.name` so the `vm` module can find them by convention within the parsed RG.
- `azurerm_network_security_group` — subnet-attached. Ships with an inbound-22 rule
  whose source is a **deny/placeholder address**; the tooling rewrites the source to
  the operator's current IP at session start (see Transport). The rule *exists* here so
  it is long-lived and survives VM churn; only its source address is reconciled by the
  tooling.
- `azurerm_managed_disk` — the persistent "laptop analog". `create_option = Empty`,
  sized from `var.size_gib`, `StandardSSD_LRS` or `Premium_LRS`. Never auto-deleted.

Outputs (exactly the contract):
- `volume_id` = the managed disk's **resource ID** (the carrier above).
- `zone` = the availability-zone string, or empty for a regional deployment.

Teardown guarantees mirror GCP: routine `destroy` runs against the `vm` state only and
never includes this state; the dedicated, confirmation-gated `destroy-volume` verb
deletes the resource group (and everything in it). Azure managed disks, like GCP disks,
cannot be resized *down* in place, so a shrink in `size_gib` must be a deliberate
`destroy-volume`, not an in-place apply.

---

## Component: `azure/vm` module (ephemeral state)

Owns only what churns with the VM lifecycle.

Logic:
- Parse subscription + resource group from `var.volume_id`.
- `data`-source the VNet/subnet/NSG/managed-disk by convention within that RG.

Resources:
- `azurerm_public_ip` — Standard SKU, Static allocation.
- `azurerm_network_interface` — in the looked-up subnet, with the public IP.
- `azurerm_linux_virtual_machine`:
  - `size = var.instance_type` (e.g. `Standard_D16s_v5`).
  - **`security_type` MUST remain Standard — NOT Trusted Launch.** Azure's default
    Trusted Launch is incompatible with nested virtualization; this is a silent-failure
    trap and is enforced + commented loudly, mirroring GCP's `enable_nested_virtualization`
    comment.
  - `admin_username = var.ssh_user`; `admin_ssh_key.public_key = var.ssh_public_key`
    (the tooling-generated public key passed in via the new interface variable).
  - `custom_data` = base64 of the rendered cloud-init (same `@@PROVISION_ENV@@` splice
    mechanism as GCP — `replace()`, not `templatefile()`, because the inlined provision
    scripts contain shell `${...}`).
  - data disk attached at a fixed LUN; source image
    `Canonical:ubuntu-24_04-lts:server:latest`.

Outputs (exactly the contract):
- `host` = the public IP address (routable; unlike GCP IAP, which returned the instance
  name addressed through the tunnel).
- `ssh_user` = `var.ssh_user`.

### Nested virtualization is implicit, so `nested` becomes a guard

Azure has **no `enable_nested_virtualization` flag** — nesting is implicit on supported
sizes (Dv3/Dsv3, Dv4/Dsv4, Dv5/Dsv5, Ev3/Esv3, Ev4/Esv4, Ev5/Esv5, Fsv2). So
`var.nested` is not a toggle here; it is a **guard**: when `true`, the module/tooling
validates the chosen `instance_type` is in a nested-capable family and fails loudly
otherwise. No silent "nested requested but the size can't do it." `Standard_D16s_v5`
(16 vCPU) is the direct analog to GCP's `n2-standard-16`.

Sources for the nested-virt facts (verified 2026-06-23):
- <https://learn.microsoft.com/en-us/answers/questions/813416/how-do-i-know-what-size-azure-vm-supports-nested-v>
- <https://azure.microsoft.com/en-us/blog/nested-virtualization-in-azure/>

---

## Provisioning deltas (cloud-init)

The extracted provision scripts are largely provider-neutral and are reused as-is —
including the `/vergil` mount, the loud `/dev/kvm` nested-virt self-check (which now
also catches a Trusted-Launch misconfiguration), and the provision loop. Two real
deltas:

1. **Data-disk device path.** GCP surfaced the data disk at
   `/dev/disk/by-id/google-vergil-data` via `device_name`. Azure surfaces data disks by
   LUN, at `/dev/disk/azure/scsi1/lun<N>`. The mount script (`mount-volume.sh` / its
   skel) needs an Azure-aware path, supplied as a provider-templated value **at build
   time**, not guessed at runtime.

2. **SSH keypair.** GCP IAP injected ephemeral keys, so the GCP module managed none.
   Azure requires a real admin keypair at create time: the tooling generates and
   persists one per instance, passes the **public** key into the module via the new
   `ssh_public_key` interface variable (see "One honest interface addition"), and keeps
   the **private** key local for the `SshTransport`. Correspondingly `host` is a routable
   public IP, not an instance name.

Everything else in the existing cloud-init carries over unchanged.

---

## Consumer side (vergil-tooling) — specified at the interface level

The dispatcher already stores `spec.provider` as an opaque string and has exactly one
dispatch decision point (`spec.off_platform`). The profile schema (`backend`,
`provider`, `region`, `instance`, `volume`, `zone`) already carries everything; a repo
opts into Azure with `provider = "azure"`, `instance = "Standard_D16s_v5"`,
`region = "eastus"`. **No schema change.**

### Provider parameterization (the cheap part)

- Replace the four hardcoded `"gcp"` literals in the module-path construction with
  `spec.provider`, so paths resolve to `<modules_root>/spec.provider/{"vm","volume"}`.
- State directory is already keyed by `(state_key, provider)` — no change.

### Build & release packaging

The modules are no longer consumed from a local checkout — the off-platform path fetches
them from a **version-tagged release archive** (#212 published modules as a release
asset; #216 switched the consumer to fetch the v-tag archive; #0c3c1e9 dropped the
publish-modules job). Two requirements follow:

- The `modules/azure/` tree **must be included in the published release asset**.
- The packaging/build step must glob `modules/**` generically, so a new provider is
  picked up automatically rather than by an explicit per-provider list. Verify this —
  the modules validate locally but would 404 at fetch time for real users if the
  archive omits `azure/`, a failure that only appears off the developer's machine.

### Transport: `SshTransport` (new, selected on provider)

A new transport class beside `IapTransport`, implementing the same
`run`/`pipe`/`popen`/`exec_session` surface — so **all guest-side code (credential
injection, provisioning, session) is reused untouched**.

- Base command: plain `ssh -i <managed_key> <ssh_user>@<host>`, where `host` is the
  public IP from module outputs.
- **Session-time NSG refresh (the roaming fix that replaces IAP).** Before connecting,
  the transport discovers the operator's current public IP and runs
  `az network nsg rule update` to set the inbound-22 source to exactly that `/32`. This
  runs at every `session`/lifecycle op, so a moved operator is always reconciled —
  neutralizing the roaming problem IAP was protecting against.
- **Operator-IP discovery is configurable and fail-closed.** The current public IP is
  obtained from a public echo endpoint that **defaults to a named service but is
  overridable** (env/config), so the dependency is not hard-wired. If discovery fails
  (endpoint unreachable, empty/garbage response), the transport **aborts the operation
  loudly** — it MUST NEVER fall back to a wide-open rule (`0.0.0.0/0`) or skip the
  refresh, which would silently destroy the single-address security posture.
- **Host-key trust.** Unlike IAP (where `gcloud` manages the tunnel and known-hosts),
  plain `ssh` must set a host-key policy: trust-on-first-contact (`accept-new`) into a
  vergil-managed `known_hosts`. Because a **rebuild** keeps the host's name/IP but
  regenerates its host key, the rebuild/destroy path MUST prune the stale `known_hosts`
  entry so the recreated box reconnects cleanly instead of hard-failing on a host-key
  mismatch.

Honest costs of this choice (vs GCP IAP): a tooling-managed SSH keypair (GCP had none),
a public IP (NSG-locked to a single address at any moment), and a runtime dependency on
an operator-IP echo endpoint (configurable, fail-closed).

### Credentials & preflight (Azure branch of the GCP-specific ~40%)

- Preflight: verify `az` CLI present and `az account get-access-token` succeeds (the
  ADC analog), and OpenTofu ≥ 1.8.0.
- Resolve subscription from `AZURE_SUBSCRIPTION_ID` or `az account show`; export
  `ARM_SUBSCRIPTION_ID` into the tofu environment (the `azurerm` 4.x provider requires
  the subscription set explicitly).

### Capacity & zone fallback (the part that addresses the actual pain)

The zone-fallback **scaffolding already exists and is reused** —
`apply_vm_with_zone_fallback` (`vm_cloud.py:753`) already sweeps a region's zones on a
capacity stockout (#1816). What it does *not* yet have is an Azure path; three pieces
inside it are hard-GCP and each needs an explicit Azure implementation (not a one-line
"generalize"):

1. **Zone enumeration.** `region_zones()` (`vm_cloud.py:731`) shells to
   `gcloud compute zones list --filter=name~^{region}-`, and there is suffix-stripping
   logic (`vm_cloud.py:842`) for GCP's `${region}-b` zone names. Azure availability
   zones are bare integers (`1`/`2`/`3`) discovered via `az vm list-skus` / the zones
   API, and not every region has them — the Azure path must handle the regional
   (zoneless) case as well.
2. **Capacity-error matching.** `is_zone_capacity_error()` matches a GCP-specific
   `_ZONE_CAPACITY_RE` (`vm_cloud.py:719`). Azure signals stockout with different
   strings — `SkuNotAvailable`, `ZonalAllocationFailed`,
   `OverconstrainedAllocationRequest` — which need an Azure detector.
3. **Zone-pinned volume recreation.** The fallback recreates the *empty* volume pinned
   to each candidate zone; Azure's managed-disk AZ pinning and the per-instance
   RG-scoped resources interact differently and must be handled in the Azure path.

This is the mechanism that makes a second provider actually help with capacity, so it
is first-milestone scope, not a follow-up.

### Read & enumerate surface (every verb that reaches the provider read-only)

The lifecycle verbs are not the only ones that touch the cloud — a class of read/enumerate
verbs shell to `gcloud` directly and each needs an Azure equivalent. These are everyday
verbs (`status`, `list`), and they are exactly the surface an operator uses to *find* a
VM when GCP capacity has just failed them, so they are first-milestone scope:

- `OffPlatformBackend.status()` → `gcloud compute instances describe` (`vm_cloud.py:951`)
  ⟶ `az vm show` / `az vm get-instance-view`.
- `region_zones()` → `gcloud compute zones list` (`vm_cloud.py:738`) ⟶ Azure zones API
  (shared with the zone-fallback work above).
- `vrg-vm volumes` (#1798) — surfaces persistent volumes from local tofu state; the
  state read is provider-neutral but any provider-side confirmation must branch.
- `list` / session-listing (#1806) and `update --all` — enumerate off-platform VMs.

**No silent non-GCP degradation.** The current `if provider != "gcp"` guard (which
*skips* the zone-status query for non-GCP providers) must become a real Azure branch,
not a skip. A provider you cannot `status`/`list` is a provider you cannot operate;
degraded-but-silent is treated as a defect, not an acceptable default.

### Lifecycle paths that must reach parity

Two behaviors already hardened on GCP are wired to the IAP transport / GCP resource set
and must be replicated for Azure, or they regress silently:

- **In-place update of a running box (#1815).** `vrg-vm update` pushes changes over the
  transport instead of destroy/recreate, preserving running state. The `SshTransport`
  must carry this path — not just `session` and the apply path — or an Azure `update`
  silently degrades to a full rebuild.
- **Failed-apply orphan rollback (#1807).** On GCP a failed VM apply left an orphan
  firewall that 409'd every retry, so the tooling rolls it back. The Azure ephemeral set
  has the same hazard: a half-created VM can leave an **orphan public IP, NIC, or a stale
  NSG source rule**. The Azure path must roll these back on a failed apply so retries
  don't wedge on a conflict.

### Provider-strategy seam (targeted refactor)

The branch points above (transport selection, preflight, capacity regex, zone
enumeration, module path, the read/enumerate queries, in-place update, orphan rollback)
are the natural seams. Rather than grow `if provider == ...` ladders through
`vm_cloud.py`, extract a small provider-strategy object scoped to exactly the spots
Azure touches. This is the only refactor in scope; it is not a general rework of the
cloud path.

---

## Testing

Mirror the existing test style (e.g. `tests/check-cloud-init-generation.sh`,
`tests/check-opentofu-name-validation.sh`). **Neither `tofu plan` nor `apply` runs in
CI** — the `azurerm` provider requires a real subscription/credentials even to `plan`
(it configures an API client and the `vm` module reads live `data` sources), so a `plan`
cannot run offline and CI must not hold cloud credentials. CI verification is therefore:

- `tofu init -backend=false` + **`tofu validate`** + `tofu fmt -check` against the Azure
  modules (offline, no credentials).
- Name-validation test extended for Azure's naming rules where they differ from RFC1035
  (resource-group, managed-disk, and public-IP constraints).
- Cloud-init generation test covering the Azure data-disk LUN path and the `custom_data`
  base64 wrapping.
- A host-side check asserting the `volume_id` → (subscription, resource group) parse and
  the Azure disk resource-ID validation are present.

All under `vrg-container-run -- vrg-validate`, the only validation entrypoint. A real
`tofu plan`/`apply` happens only in the **credentialed first-milestone stand-up** (see
Scope & milestones), never in CI.

---

## Scope & milestones

**In scope:**
- One `interface.json` addition: the vm `ssh_public_key` variable (see "One honest
  interface addition").
- `opentofu/modules/azure/{vm,volume}` satisfying `interface.json`, keyed per-instance
  (#242).
- A one-line, behavior-neutral addition to the **GCP** vm module: declare the new
  `ssh_public_key` variable with `default = ""` and ignore it, so the strict contract
  test stays green for both providers. (This is the only GCP touch — not a rework.)
- Azure cloud-init / provisioning deltas (disk path, SSH key).
- The Azure module tree shipped in the published release asset (`modules/**` packaging).
- vergil-tooling (companion issue): provider parameterization, `SshTransport` with NSG
  refresh, Azure preflight/credentials, Azure capacity detection + zone fallback (the
  three GCP-coupled pieces), the **read & enumerate surface** (`status`/`list`/zone
  enumeration with no silent non-GCP degradation), **lifecycle parity** (in-place update
  #1815, orphan rollback #1807), and the provider-strategy seam.

**Out of scope (named so the plan stays focused):**
- Cloud-account setup runbook — tracked in #204 (already covers GCP + Azure).
- Overnight stop/start pause — #209.
- Any rework of the GCP provider.

**First milestone.** Stand up one real Azure off-platform VM for the same MQ-cluster
workload and prove (a) nested KVM works (no TCG emulation tax), and (b) the
capacity-fallback story — zone-walking on allocation failure — behaves as designed.
