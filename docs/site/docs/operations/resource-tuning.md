# Resource Tuning

## Defaults

The VM template defines conservative defaults suitable for modest
hardware:

| Resource | Default |
| -------- | ------- |
| CPUs | 4 |
| Memory | 4 GiB |
| Disk | 50 GiB |

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
