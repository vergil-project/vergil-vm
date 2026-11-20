# Resource Tuning

## Defaults

The defaults are conservative, suitable for modest hardware, and the
same for both kinds of Lima VM `vrg-vm` creates, the shared VM and a
dedicated per-repo VM:

| Resource | Default |
| -------- | ------- |
| CPUs | 4 |
| Memory | 4 GiB |
| Disk | 100 GiB |

For any field the identity leaves unset, both kinds take their size from
`vrg-vm`'s base footprint, not from the VM template's own values in
`templates/agent.yaml` (vergil-tooling #4791, #4810). A per-identity
`disk` (see below) overrides the 100 GiB default, and so does a named
instance's `disk` in a repo's `[vm]` profile; see vergil-tooling's VM
spec reference. A shared VM created before #4810, at the template's
50 GiB, reaches 100 GiB only when it is rebuilt. Off-platform cloud VMs
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
disk = "200GiB"
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
