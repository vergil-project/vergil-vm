# Troubleshooting

## Provisioning failures

If the VM fails during creation or the readiness probe times out, check
the cloud-init provisioning logs:

```bash
limactl shell <instance> -- cat /var/log/cloud-init-output.log
```

Common causes:

- **Network issues** — provisioning downloads packages from apt repos,
  GitHub, NodeSource, and npm. Verify the VM has internet access:
  `limactl shell <instance> -- curl -s https://github.com`
- **Disk space** — a full host disk prevents the VM image from
  expanding. Check with `df -h`.
- **Lima version** — the template requires Lima 2.0+. Check with
  `limactl --version`.

## Readiness probe timeout

The readiness probe waits up to 30 minutes for `gh`, `uv`, `claude`,
and containerd. If it times out:

1. Shell into the VM: `limactl shell <instance>`
2. Check which tools are missing: `which gh uv claude`
3. Check containerd: `pgrep -f containerd`
4. Review provisioning logs (see above)

The most common cause is a slow or interrupted npm install of Claude
Code. Re-running `npm install -g @anthropic-ai/claude-code` inside the
VM may resolve it.

## Credential verification failures

After running `vrg-vm-init.sh`, the script runs a 5-point verification.
If checks fail:

| Check | Fix |
| ----- | --- |
| App private key missing | Re-run `vrg-vm-init.sh` — the key file may not have been copied |
| Key permissions wrong | `limactl shell <instance> -- chmod 600 ~/.config/vergil/app.pem` |
| App config missing | Verify `VRG_APP_ID` or `identities.toml` has the `app_id` field |
| Config permissions wrong | `limactl shell <instance> -- chmod 600 ~/.config/vergil/app.env` |
| Git HTTPS rewrite missing | `limactl shell <instance> -- git config --global url."https://github.com/".insteadOf "git@github.com:"` |

You can re-run verification independently:

```bash
limactl shell <instance> -- bash -s < scripts/vm-verify-credentials.sh
```

## Containerd not starting

Containerd runs as a rootless user service. To check its status:

```bash
limactl shell <instance> -- systemctl --user status containerd
```

If it is not running, start it:

```bash
limactl shell <instance> -- systemctl --user start containerd
```

Verify it works by pulling and running a container:

```bash
limactl shell <instance> -- nerdctl run --rm alpine echo hello
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

If the mount path is wrong, the VM must be recreated with the correct
`--set` value — mounts cannot be changed after creation.
