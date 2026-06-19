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
  `prevent_destroy` on the disk backstops the "destroy the VM, keep the volume"
  contract.
- **The boot disk is ephemeral and fixed-size** (`boot_disk_gib`, default 30); only the
  persistent `volume` size is author-facing. (`disk` is a Lima knob, not a cloud one.)

## Provider-agnostic interface

Every provider's `volume`/`vm` modules expose exactly the variable/output names in
`opentofu/interface.json`; `tests/check-opentofu-contract.sh` enforces it. Azure
(Phase 3) must satisfy the same file unchanged — that is what proves the abstraction is
not GCP-shaped. Provider-native specifics (GCP's
`enable_nested_virtualization`) stay inside the module.

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

- **SSH ingress is locked to the create-initiator's origin address(es)**
  (`ssh_source_ranges`), re-applied each create; the module's variable validation
  **rejects an empty list and `0.0.0.0/0`**. Password auth is off (`ssh_pwauth: false`).
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
