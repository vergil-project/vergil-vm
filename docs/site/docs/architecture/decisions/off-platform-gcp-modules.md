# Off-Platform GCP Modules

The off-platform backend (vergil-vm #199) runs a Vergil session on a remote
native-x86, nested-virtualization cloud host instead of a local Lima VM, behind the
same `vrg-vm` verbs. This page covers the **vergil-vm-owned, offline** part: the GCP
OpenTofu modules. The end-to-end orchestration — `vrg-vm` dispatch, `tofu apply`,
SSH `session`, and credential injection — lives in the
[vergil-tooling #1706](https://github.com/vergil-project/vergil-tooling/issues/1706)
companion and is **out of scope here**.

## Two modules, two lifecycles

```text
opentofu/modules/gcp/
  volume/   persistent block disk — created once, long-lived (the "laptop analog")
  vm/       ephemeral instance + attach + cloud-init — destroyed and rebuilt routinely
```

- **The volume owns its zone.** A GCP disk is zonal, so the `volume` module records the
  zone it landed in (`coalesce(zone, "${region}-b")`) and outputs it; the `vm` module
  consumes that zone, so a rebuilt instance always lands where its disk lives.
  The "destroy the VM, keep the volume" contract holds structurally: routine
  teardown runs `tofu destroy` on the VM state only, never the volume state, and
  the dedicated `destroy-volume` verb is confirmation-gated. (An earlier
  `prevent_destroy` guard on the disk was removed — a literal can't be
  conditionalized, so it also blocked that legitimate verb.)
- **The boot disk is ephemeral and fixed-size** (`boot_disk_gib`, default 30); only the
  persistent `volume` size is author-facing. (`disk` is a Lima knob, not a cloud one.)

## Provider-agnostic interface

Every provider's `volume`/`vm` modules expose exactly the variable/output names in
`opentofu/interface.json`; `tests/check-opentofu-contract.sh` enforces it. Azure
(Phase 3) must satisfy the same file unchanged — that is what proves the abstraction is
not GCP-shaped. Provider-native specifics (GCP's
`enable_nested_virtualization`) stay inside the module.

## Named instances and resource naming (#242)

One `(identity, org/repo)` can own several named instances (vergil-vm #242), each its
own VM + volume. The instance handle is the four-segment slug
`<identity>--<org>--<repo>--<name>`, used for the tofu **state path**, the **Lima**
instance name, and as the **source of the identity labels**.

GCP resource names cannot be the slug: instance/disk/firewall names are capped at **63
chars** (RFC1035), the derived `<name>-data` / `<name>-ssh` add 5 / 4, and a realistic
four-segment slug already overflows. So the dispatcher (#1831) passes the modules a
**deterministic hashed name** — `vrg-<first 12 hex of sha256(slug)>` (≤ 16 chars,
RFC1035-valid) — and carries the human identity in the `vergil-identity` /
`vergil-repo` / `vergil-instance` **labels**. `vrg-vm list` and `tofu import` read the
labels; the cloud-console name is an opaque hash by design. `vergil-instance` is a
label *value* in the existing `labels` map — `interface.json` is unchanged.

The modules **fail loudly on a bad name**: `var.name` in both `volume` and `vm`
carries a `validation` enforcing the RFC1035 charset and length ≤ 58 (so `<name>-data`
stays ≤ 63), so a malformed or over-length name is rejected at `tofu plan`, not deep
in apply. `tests/check-opentofu-name-validation.sh` guards the validation's presence.

## One provisioning truth

The instance's cloud-init is **generated** by `scripts/build-cloud-init.sh` from a
skeleton plus the **same** `templates/provision/*.sh` the Lima backend uses (see the
generated-`agent.yaml` note in [Architecture](../index.md)). Each script's
`# vergil-provision:` manifest decides whether cloud-init runs it directly (`root`) or
via `sudo -iu "$VERGIL_USER"` (`user`). `tests/check-cloud-init-generation.sh` guards
the committed `cloud-init.yaml` against drift. The cloud-init also formats-on-first-use
and mounts the persistent volume at `/vergil` before provisioning, and disables
password SSH.

## Security

- **No public attack surface.** The instance has **no public IP** (`access_config` is
  dropped), so there is no internet-facing sshd. Access is via **GCP Identity-Aware
  Proxy (IAP) TCP tunneling**: the SSH firewall allows ingress only from Google's fixed
  IAP range `35.235.240.0/20` — a module constant, not an operator address, so nothing
  refreshes when the operator roams. IAP supersedes the original operator-IP allow-list,
  which was unsound behind NAT (a host cannot self-detect its public IP without a
  third-party echo — an unacceptable dependency in a create-blocking, security-critical
  path).
- **No Vergil-managed SSH keypair.** Auth is the operator's existing GCP IAM —
  `roles/iap.tunnelResourceAccessor` gates the tunnel — and `gcloud compute ssh
  --tunnel-through-iap` provisions ephemeral keys itself, so the module carries no
  `ssh_public_key`. Password auth is off (`ssh_pwauth: false`).
- **Precondition (operator account setup, see #204):** the IAP API enabled and
  `roles/iap.tunnelResourceAccessor` granted on the project. Azure's future module
  mirrors this access model via Azure Bastion (separate follow-up); the
  provider-agnostic module interface stays connection-method-blind.
- The GitHub App private key (injected by #1706) lands on the **ephemeral boot disk**,
  never the persistent volume — teardown destroys it.

## Reproducibility

`required_version` and `required_providers` (`hashicorp/google ~> 6.0`) are pinned, and
`.terraform.lock.hcl` is committed (for `darwin_arm64` and `linux_amd64`), so two
applies behave identically. The off-platform dispatcher (#1706) preflights that `tofu`
is installed.

## Verification

Offline only: `tests/run-host-tests.sh` runs generation-freshness, the manifest check,
the interface-contract check, and `tofu fmt`/`validate` per module. Real-cloud `create`/
`session`/`destroy` and the `driver=kvm` assertion are gated, cost money, and land
with the #1706 companion.
