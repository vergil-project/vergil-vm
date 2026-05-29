# Getting Started

Configure a Vergil identity, create a sandboxed VM, and launch your
first Claude Code session.

## Prerequisites

- **macOS** — Lima uses Apple's Virtualization.framework; Linux desktop
  is not yet tested or supported
- **Lima 2.0+** — VM manager
  ([install](https://lima-vm.io/docs/installation/))
- **vergil-tooling** — provides the `vrg-vm` CLI and related tools
  ([install](https://vergil-project.github.io/vergil-tooling/getting-started.html))

## 1. Configure your identity

Before creating a VM, you need an identity configuration that tells
the tooling which GitHub App to use and where your projects live.

Create `~/.config/vergil/identities.toml`:

```toml
default_identity = "vergil"

[identities.vergil]
vm_instance = "vergil"
app_id = 123456
private_key_path = "~/.config/vergil/keys/vergil.pem"
projects_dir = "/Users/you/dev/projects"
```

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
vrg-vm create --identity vergil
```

This fetches the VM template, creates a Lima VM with your configured
resource limits and projects mount, starts it, injects your GitHub App
credentials, and installs vergil-tooling inside the VM. The process
takes several minutes on first run (provisioning downloads packages
and tools).

When complete, you'll see:

```text
VM 'vergil' is ready.
```

## 3. Launch a Claude Code session

Start a sandboxed Claude Code session inside the VM:

```bash
vrg-vm session vergil
```

This connects to the VM (starting it if needed), updates credentials
and tooling, and drops you into an interactive shell at your projects
directory. From there, launch Claude Code:

```bash
claude
```

Or launch directly into a specific workspace:

```bash
vrg-vm session vergil my-project -- claude
```

The agent now has access only to your projects directory and can only
authenticate to GitHub repositories granted to your App.

## Day-to-day usage

After initial setup, the typical workflow is:

```bash
vrg-vm session vergil           # connect to your VM
claude                          # launch Claude Code
```

The VM persists between sessions. Stop it when not in use:

```bash
vrg-vm stop --identity vergil
```

If the VM becomes stale (older than 3 days), the tooling will prompt
you to rebuild:

```bash
vrg-vm rebuild --identity vergil
```

## Next Steps

- [Architecture](architecture/index.md) — understand the VM anatomy and
  provisioning pipeline
- [Build and Test](operations/build-and-test.md) — run the test suite
  against template changes
- [Resource Tuning](operations/resource-tuning.md) — adjust CPU, memory,
  and disk for your workload
