# Getting Started

Configure a Vergil identity, create a sandboxed VM, and launch your
first Claude Code session.

## Prerequisites

- **macOS** — Lima uses Apple's Virtualization.framework; Windows and
  Linux desktops are not yet tested
- **Lima 2.0+** — VM manager
  ([install](https://lima-vm.io/docs/installation/))
- **vergil-tooling** — provides the `vrg-vm` CLI and related tools
  ([install](https://vergil-project.github.io/vergil-tooling/getting-started.html))

## 1. Configure your identity

Before creating a VM, you need an identity configuration that tells
the tooling which GitHub App to use and where your projects live.
Identity setup and management is documented in the
[vergil-tooling identity guide](https://vergil-project.github.io/vergil-tooling/identity-setup.html).

The identity name `vergil` is the standard primary identity. The
GitHub App is typically named `<your-username>-vergil` and granted
access to the repositories you want the agent to work with.

!!! note
    Additional identities (e.g., a `mimir` identity for security
    testing) are planned but not yet supported. For now, configure
    a single `vergil` identity.

## 2. Create the VM

With your identity configured, create the VM:

```bash
vrg-vm create
```

This fetches the VM template, creates a Lima VM with your configured
resource limits, mounts your projects directory with path preservation
(the same absolute path is used inside the VM), starts it, injects
your GitHub App credentials, and installs vergil-tooling inside the
VM. The process takes several minutes on first run (provisioning
downloads packages and tools).

When complete, you'll see:

```text
VM 'vergil' is ready.
```

## 3. Launch a Claude Code session

Start a sandboxed Claude Code session:

```bash
vrg-vm session my-project
```

This connects to the VM (starting it if needed) and launches Claude
Code with your working directory set to `my-project` (a subdirectory
of your configured projects path). The agent has access only to your
projects directory and can only authenticate to GitHub repositories
granted to your App.

## Day-to-day usage

The typical workflow is:

```bash
vrg-vm session my-project
```

When you're done, cancel out of Claude Code and the session ends.
That's it — there's nothing else to manage.

These are ephemeral, disposable sessions. Rebuild your VM frequently
to stay current with the latest tooling and provisioning:

```bash
vrg-vm rebuild
```

If the VM becomes stale (older than 3 days), the tooling will prompt
you to rebuild automatically.

## Next Steps

- [Sessions](sessions.md) — naming, resume, slots, `--fresh`, staleness, and
  `vrg-vm list --sessions`
- [Architecture](architecture/index.md) — understand the VM anatomy and
  provisioning pipeline
- [Build and Test](operations/build-and-test.md) — run the test suite
  against template changes
- [Resource Tuning](operations/resource-tuning.md) — adjust CPU, memory,
  and disk for your workload
