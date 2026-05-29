# Vergil VM

Lima VM definitions that create isolated Ubuntu 24.04 execution environments
for Vergil AI agent sessions. Each VM is a full virtual machine with its own
OS, rootless container runtime, development tools, and Claude Code — providing
strong isolation between agent identities.

## Ecosystem Context

Vergil VM is one of three infrastructure repositories:

| Repository | Purpose |
| ---------- | ------- |
| [vergil-tooling](https://github.com/vergil-project/vergil-tooling) | CLI tools, validators, and git hooks consumed by all managed repos |
| **vergil-vm** | VM template and provisioning for long-running agent execution environments |
| [vergil-docker](https://github.com/vergil-project/vergil-docker) | Dev container images for CI pipelines and local validation |

These are complementary: vergil-docker images are ephemeral containers for
running linters and tests; vergil-vm instances are persistent virtual machines
where agents do sustained development work.

## Components

| Component | Path | Purpose |
| --------- | ---- | ------- |
| VM template | `templates/agent.yaml` | Lima VM definition with provisioning scripts |
| Build script | `scripts/build.sh` | Creates a test VM, runs the test suite, cleans up |
| Credential provisioning | `scripts/vrg-vm-init.sh` | Injects GitHub App credentials into a VM |
| Test suite | `tests/` | Integration tests that run inside the VM |

## What's in the Box

Every VM created from the agent template includes:

- **Ubuntu 24.04 LTS** with zsh as the default shell
- **Rootless containerd** — agents can pull and run containers without root
- **Core tools** — git, jq, ripgrep, fzf, vim, tmux, curl, wget
- **GitHub CLI** (`gh`) for repository operations
- **Node.js 22** and **Claude Code** for AI-assisted development
- **uv** — Python package manager for installing vergil-tooling at runtime
- **yq** — YAML processor for configuration management

## Quick Links

- [Getting Started](getting-started.md) — create your first VM and launch a session
- [Architecture](architecture/index.md) — how the VM is built and provisioned
- [Build and Test](operations/build-and-test.md) — run the test suite locally
