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
`templates/agent.yaml` (vergil-tooling #4791, #4810). The template's
own values are the same 4 CPUs, 4 GiB and 100 GiB, and apply only to a
VM created from it directly with `limactl`, such as the test VM
`scripts/build.sh` builds. A per-identity `disk` (see below) overrides
the 100 GiB default, and so does a named instance's `disk` in a repo's
`[vm]` profile; see vergil-tooling's VM spec reference. A shared VM
created before #4810 has the 50 GiB disk the template had then, and
keeps it until it is rebuilt or its disk is
[grown in place](#growing-an-existing-vms-disk). Off-platform cloud VMs
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

A restart alone applies no changed setting: `vrg-vm restart` stops and
starts the VM with the CPUs, memory and disk Lima recorded when it was
created. To change those without a rebuild, edit the stopped VM with
`limactl edit`, as [Growing an Existing VM's
Disk](#growing-an-existing-vms-disk) shows for the disk; the same
command takes `--cpus <n>` and `--memory <GiB>`.

!!! note
    Disk size can only be increased, never decreased. A rebuild applies
    a larger disk; so does growing it in place, below.

## Growing an Existing VM's Disk

`vrg-vm` sets a VM's disk size only when it creates the VM. No `vrg-vm`
command changes the size of an existing VM's disk: `vrg-vm update`
reinstalls tooling and plugins in a running VM, and `vrg-vm restart`
stops and starts it as it is. An existing VM keeps its disk size until
it is rebuilt, or until its disk is grown in place.

Lima can grow, but never shrink, an existing instance's main disk with
`limactl edit --disk` (Lima 1.1 and later; this template requires Lima
2.0). Growing in place keeps the VM's contents, so it avoids the
rebuild. Run these steps on the host, one VM at a time:

1. Stop the VM, with the same identity and workspace arguments you use
   to start it. `vrg-vm stop` prints the Lima instance name, which
   `limactl list` also shows:

    ```bash
    vrg-vm stop
    ```

2. Set the new size, in GiB. It must be larger than the current size:

    ```bash
    limactl edit <instance> --disk 100
    ```

3. Start the VM with `vrg-vm start`, so credentials are injected as
   usual. On boot, the Ubuntu image's cloud-init `growpart` and
   `resizefs` modules, which run on every boot, grow the root partition
   and filesystem to fill the larger disk.

4. Check the result: the `DISK` column of `limactl list`, and `df -h /`
   inside the VM. `vrg-vm list` shows the size the identity's footprint
   asks for, not the VM's actual disk, so it cannot confirm the change.

A dedicated VM's `vrg-vm list` drift check compares the spec it was
created from, `disk` included, with the composed spec. Growing its disk
in place does not change that record, so a dedicated VM whose declared
`disk` changed still shows `NEEDS-REBUILD` after the steps above.
