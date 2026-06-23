# Azure Off-Platform Cloud Provider Design

**Issues:**
- [vergil-vm #250 — Add Azure as a second off-platform cloud provider (clone of the GCP modules)](https://github.com/vergil-project/vergil-vm/issues/250)
- Companion vergil-tooling issue (consumer side) — to be filed (analog of vergil-tooling #1706).

**Date:** 2026-06-23

**Status:** Design (from brainstorming, 2026-06-23). Extends the off-platform VM
backend (#199); adds a second provider without restructuring it.

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
  interface.json                      ← UNCHANGED. Azure modules satisfy the same contract.
  modules/
    gcp/{vm,volume}/                   ← untouched
    azure/
      vm/      {main,variables,outputs,versions}.tf, cloud-init.yaml(.skel)
      volume/  {main,variables,outputs,versions}.tf
```

The contract both providers satisfy (current `interface.json`):

```json
{
  "volume": { "variables": ["name","region","zone","size_gib","labels"],
              "outputs":   ["volume_id","zone"] },
  "vm":     { "variables": ["name","zone","instance_type","nested","volume_id",
                            "boot_disk_gib","ssh_user","provision_env","labels"],
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
the Azure analog of GCP passing the disk `self_link` — the existing interface carries
everything Azure needs, and `interface.json` is unchanged byte-for-byte.

---

## Component: `azure/volume` module (long-lived state)

Owns the **per-repo resource group and all long-lived scaffolding**. Created once;
the gated `destroy-volume` verb is the only routine path that tears it down.

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
  - `admin_username = var.ssh_user`; `admin_ssh_key` = the tooling-managed public key.
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
   persists one per identity and passes the public key into the module. Correspondingly
   `host` is a routable public IP, not an instance name.

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
  `spec.provider`, so paths resolve to `modules_root / spec.provider / {"vm","volume"}`.
- State directory is already keyed by `(state_key, provider)` — no change.

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

Honest costs of this choice (vs GCP IAP): a tooling-managed SSH keypair (GCP had none)
and a public IP, though NSG-locked to a single address at any moment.

### Credentials & preflight (Azure branch of the GCP-specific ~40%)

- Preflight: verify `az` CLI present and `az account get-access-token` succeeds (the
  ADC analog), and OpenTofu ≥ 1.8.0.
- Resolve subscription from `AZURE_SUBSCRIPTION_ID` or `az account show`; export
  `ARM_SUBSCRIPTION_ID` into the tofu environment (the `azurerm` 4.x provider requires
  the subscription set explicitly).

### Capacity & zone fallback (the part that addresses the actual pain)

- Azure signals "no capacity" with different strings than GCP: `SkuNotAvailable`,
  `ZonalAllocationFailed`, `OverconstrainedAllocationRequest`. Add an Azure variant of
  the capacity-error detector.
- Generalize the existing zone-fallback retry: on an allocation failure, walk the
  region's availability zones (1/2/3) before surfacing the error. This is the Azure
  equivalent of GCP zone-walking and is the mechanism that makes a second provider
  actually help with capacity.

### Provider-strategy seam (targeted refactor)

The branch points above (transport selection, preflight, capacity regex, zone
enumeration, module path) are the natural seams. Rather than grow `if provider == ...`
ladders through `vm_cloud.py`, extract a small provider-strategy object scoped to
exactly the spots Azure touches. This is the only refactor in scope; it is not a
general rework of the cloud path.

---

## Testing

Mirror the existing test style (e.g. `tests/check-cloud-init-generation.sh`,
`tests/check-opentofu-name-validation.sh`). No `apply` in CI — no billed resources.

- `tofu validate` + `tofu plan` against the Azure modules with fixture vars.
- Name-validation test extended for Azure's naming rules where they differ from RFC1035
  (resource-group, managed-disk, and public-IP constraints).
- Cloud-init generation test covering the Azure data-disk LUN path and the `custom_data`
  base64 wrapping.
- A unit test asserting the `volume_id` → (subscription, resource group) parse is
  correct.

All under `vrg-container-run -- vrg-validate`, the only validation entrypoint.

---

## Scope & milestones

**In scope:**
- `opentofu/modules/azure/{vm,volume}` satisfying `interface.json`.
- Azure cloud-init / provisioning deltas (disk path, SSH key).
- vergil-tooling: provider parameterization, `SshTransport` with NSG refresh, Azure
  preflight/credentials, Azure capacity detection + zone fallback, the provider-strategy
  seam. (Tracked in the companion vergil-tooling issue.)

**Out of scope (named so the plan stays focused):**
- Cloud-account setup runbook — tracked in #204 (already covers GCP + Azure).
- Overnight stop/start pause — #209.
- Any rework of the GCP provider.

**First milestone.** Stand up one real Azure off-platform VM for the same MQ-cluster
workload and prove (a) nested KVM works (no TCG emulation tax), and (b) the
capacity-fallback story — zone-walking on allocation failure — behaves as designed.
