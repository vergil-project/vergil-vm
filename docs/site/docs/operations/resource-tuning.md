# Resource Tuning

## Defaults

The VM template defines conservative defaults suitable for modest
hardware:

| Resource | Default |
| -------- | ------- |
| CPUs | 4 |
| Memory | 4 GiB |
| Disk | 50 GiB |

## Override Mechanisms

Resources can be customized at three levels, from most persistent to
most ad-hoc:

### Per-identity configuration

Set resource fields in `~/.config/vergil/identities.toml`:

```toml
[identities.my-agent]
app_id = 12345
private_key_path = "~/.config/vergil/keys/my-agent.pem"
cpus = 12
memory = "32GiB"
disk = "100GiB"
```

These values are applied automatically by `vrg-vm create` when creating
a VM for this identity.

### At create time

Pass `--set` flags to `limactl create`:

```bash
limactl create --name=vergil-agent templates/agent.yaml \
  --set='.cpus = 8' \
  --set='.memory = "16GiB"' \
  --set='.mounts[0].location = "/path/to/projects"' \
  --tty=false
```

### On a stopped VM

Edit a stopped VM's configuration directly:

```bash
limactl stop vergil-agent
limactl edit vergil-agent
```

This opens the VM's YAML configuration in your editor. Modify `cpus`,
`memory`, or `disk`, save, and restart:

```bash
limactl start vergil-agent
```

!!! note
    Disk size can only be increased, not decreased. CPU and memory
    changes take effect on the next start.
