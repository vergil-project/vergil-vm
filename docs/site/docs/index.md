# Vergil VM

Vergil VM implements a sandbox environment for running
[Claude Code](https://claude.ai/claude-code) within the Vergil
ecosystem. It creates isolated Ubuntu virtual machines where AI
agents operate with tightly scoped access — protecting both your host
system and your GitHub resources.

## Why Sandbox?

Running a code agent directly on your workstation gives it broad access
to your filesystem, credentials, and network. Vergil VM narrows that
exposure through three layers of protection:

**A. Filesystem isolation** — The VM can only access a single directory
you designate as your projects hierarchy. Your home directory, system
files, SSH keys, and everything else on the host remain invisible to
the agent.

**B. GitHub App scoping** — Instead of sharing your personal GitHub
credentials, each VM authenticates via a dedicated GitHub App with
fine-grained permissions. The agent can only access repositories you
explicitly grant to that App, and its tokens are short-lived.

**C. Egress protection** *(work in progress)* — Network egress controls
will restrict what the agent can communicate with externally, completing
the sandbox boundary. This is not yet implemented but will be in place
before public release.

The goal is to progressively shrink-wrap the agent's surface area to the
absolute minimum required for productive development work.

## How It Works

Each identity (a named GitHub App configuration) gets its own long-lived
VM. The VM is created once and reused across sessions — starting it
injects fresh credentials and launches Claude Code against your projects.

| Component    | Path                   | Purpose                                          |
| ------------ | ---------------------- | ------------------------------------------------ |
| VM template  | `templates/agent.yaml` | Lima VM definition with provisioning scripts      |
| Build script | `scripts/build.sh`     | Creates a test VM, runs the test suite, cleans up |
| Test suite   | `tests/`               | Integration tests that run inside the VM          |

## What's in the Box

Every VM created from the agent template includes:

- **Ubuntu LTS** with zsh as the default shell
- **Rootless containerd** — agents can pull and run containers without root
- **Core tools** — git, jq, ripgrep, fzf, vim, tmux, curl, wget
- **GitHub CLI** (`gh`) for repository operations
- **Node.js** and **Claude Code** for AI-assisted development
- **uv** — Python package manager for installing vergil-tooling at runtime
- **yq** — YAML processor for configuration management

## Ecosystem Context

Vergil VM is one of five repositories in the Vergil ecosystem:

| Repository | Purpose |
| ---------- | ------- |
| [vergil-tooling](https://github.com/vergil-project/vergil-tooling) | CLI tools (`vrg-vm`, `vrg-git`, etc.), validators, and git hooks |
| **vergil-vm** | VM template definition and test suite |
| [vergil-docker](https://github.com/vergil-project/vergil-docker) | Dev container images for CI pipelines and local validation |
| [vergil-claude-plugin](https://github.com/vergil-project/vergil-claude-plugin) | Claude Code plugin with skills, hooks, and MCP configuration |
| [vergil-actions](https://github.com/vergil-project/vergil-actions) | Reusable GitHub Actions for CI/CD workflows |

The `vrg-vm` CLI (provided by vergil-tooling) is the primary interface
for creating, starting, and connecting to VMs defined by this template.

## Quick Links

- [Getting Started](getting-started.md) — configure an identity and launch your first session
- [Architecture](architecture/index.md) — how the VM is built and provisioned
- [Operations](operations/build-and-test.md) — build, test, tune, and troubleshoot

## Acknowledgements

The concept for Vergil VM — using Lima to sandbox code agents inside
isolated virtual machines — is inspired by
[corral](https://gitlab.com/dmorel69/corral) by D. Morel. Corral
demonstrated the approach of running agents in per-repo Lima VMs with
controlled filesystem access. Vergil VM adapts the idea to a
per-identity model where a single VM serves an agent's entire
collection of repositories, integrated with the broader Vergil tooling
ecosystem.
