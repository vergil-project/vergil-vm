# Troubleshooting

## Provisioning failures

If the VM fails during creation or the readiness probe times out,
the simplest fix is usually to destroy and recreate:

```bash
vrg-vm rebuild
```

If you need to diagnose the cause, check the cloud-init provisioning
logs inside the VM:

```bash
limactl shell vergil -- cat /var/log/cloud-init-output.log
```

Common causes:

- **Network issues** — provisioning downloads packages from apt repos,
  GitHub, NodeSource, and npm
- **Disk space** — a full host disk prevents the VM image from
  expanding. Check with `df -h`.
- **Lima version** — the template requires Lima 2.0+. Check with
  `limactl --version`.

## Readiness probe timeout

The readiness probe waits up to 30 minutes for `gh`, `uv`, `claude`,
and containerd. If it times out, rebuild the VM:

```bash
vrg-vm rebuild
```

To diagnose before rebuilding, shell into the VM and check which
tools are missing:

```bash
limactl shell vergil -- which gh uv claude
limactl shell vergil -- pgrep -f containerd
```

The most common cause is a slow or interrupted npm install of Claude
Code.

## Credential issues

Credentials are injected automatically by `vrg-vm create` and
refreshed on each `vrg-vm start` or `vrg-vm session`. If credential
issues arise, restarting the VM re-injects them:

```bash
vrg-vm restart
```

If problems persist, rebuild the VM entirely:

```bash
vrg-vm rebuild
```

## Containerd not starting

Containerd runs as a rootless user service. To check its status:

```bash
limactl shell vergil -- systemctl --user status containerd
```

If it is not running, restart the VM:

```bash
vrg-vm restart
```

To verify containerd works:

```bash
limactl shell vergil -- nerdctl run --rm alpine echo hello
```

## Mount issues

The projects mount uses path preservation — the host's `projects_dir`
is mounted at the same absolute path inside the VM. Common issues:

- **Relative path** — `projects_dir` in identities.toml must be an
  absolute path (e.g., `/Users/you/dev/projects`, not `~/projects`)
- **Path does not exist** — the host directory must exist before VM
  creation
- **Permission denied** — Lima needs read/write access to the host
  directory

To check the current mount configuration:

```bash
limactl list --json | jq '.[].config.mounts'
```

If the mount path is wrong, rebuild with the corrected `projects_dir`
in identities.toml:

```bash
vrg-vm rebuild
```
