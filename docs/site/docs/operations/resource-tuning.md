# Resource Tuning

## Defaults

The defaults are conservative, suitable for modest hardware. The disk
default depends on which kind of Lima VM `vrg-vm` creates:

| Resource | Shared VM | Dedicated per-repo VM |
| -------- | --------- | --------------------- |
| CPUs | 4 | 4 |
| Memory | 4 GiB | 4 GiB |
| Disk | 50 GiB | 100 GiB |

The shared VM takes the VM template's own values (`templates/agent.yaml`)
for any field the identity leaves unset. A dedicated VM takes its size
from `vrg-vm`'s base footprint, which sets a 100 GiB disk
(vergil-tooling #4791). A repo's `[vm]` profile can size a dedicated VM
itself; see vergil-tooling's VM spec reference. Off-platform cloud VMs
have no `disk` field: they size an ephemeral boot disk (60 GiB by
default) and a persistent volume instead.

## How to Configure

Set resource fields in `~/.config/vergil/identities.toml`:

```toml
[identities.vergil]
app_id = 12345
private_key_path = "~/.config/vergil/keys/vergil.pem"
cpus = 12
memory = "32GiB"
disk = "100GiB"
```

These values are applied automatically by `vrg-vm create` when creating
a VM for this identity.

## Applying Changes

To apply new resource settings, rebuild the VM:

```bash
vrg-vm rebuild
```

If you only changed CPU or memory (not disk), a restart is sufficient:

```bash
vrg-vm restart
```

!!! note
    Disk size can only be increased, not decreased, and requires a
    rebuild. CPU and memory changes take effect on restart.
