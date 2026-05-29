# Architecture

## VM Anatomy

Each Vergil identity VM is a full Ubuntu 24.04 virtual machine managed
by [Lima](https://lima-vm.io/). Lima wraps QEMU to run the guest OS and
provides transparent SSH access from the host. A single writable mount
at `/projects` gives the guest access to the host's project directory.

```text
┌─────────────────────────────────────────────┐
│  Host (macOS / Linux)                       │
│                                             │
│  limactl ──SSH──► ┌──────────────────────┐  │
│                   │  Ubuntu 24.04 Guest   │  │
│                   │                       │  │
│  /path/to/        │  /projects (mount)    │  │
│  projects ◄──────►│                       │  │
│                   │  containerd (rootless) │  │
│                   │  gh, uv, claude, ...  │  │
│                   └──────────────────────┘  │
└─────────────────────────────────────────────┘
```

Rootless containerd runs as a user service inside the VM, allowing
agents to pull and run containers without root privileges. See
[VM Isolation Model](decisions/vm-isolation-model.md) for the design
rationale.

## Provisioning Pipeline

The VM template (`templates/agent.yaml`) defines a four-stage pipeline
that runs when a VM is created:

### Stage 1: System provisioning (root)

Installs OS packages and development tools:

| Tool | Source | Purpose |
| ---- | ------ | ------- |
| curl, wget, unzip | apt | File downloads and extraction |
| jq | apt | JSON processing |
| ripgrep | apt | Fast code search |
| fzf | apt | Fuzzy finder |
| zsh, vim, tmux, nano | apt | Shell and editors |
| python3, python3-venv | apt | Python runtime |
| git | apt | Version control |
| gh | GitHub CLI apt repo | GitHub API and workflows |
| Node.js 22 | NodeSource apt repo | Runtime for Claude Code |
| yq | GitHub releases binary | YAML processing |
| Claude Code | npm global install | AI-assisted development |

Also configures:

- zsh as the default shell for the Lima user
- sshd drop-in to accept terminal environment variables (see
  [SSH Terminal Forwarding](#ssh-terminal-environment-forwarding))

### Stage 2: User provisioning (lima user)

- Installs [uv](https://docs.astral.sh/uv/) (Python package manager)
- Creates a minimal `.zshrc` with PATH, history, and prompt configuration

### Stage 3: Readiness probe

Waits up to 30 minutes for all of the following:

- `gh` command available
- `uv` command available
- `claude` command available
- containerd process running

The VM reports ready only after all four conditions are met.

### Stage 4: Credential injection (post-creation)

Run manually after VM creation via `scripts/vrg-vm-init.sh`. This stage
is separate because credentials are identity-specific — the template
remains generic and reusable across identities. See
[Credential Injection](decisions/credential-injection.md) for the
design rationale.

The script:

1. Reads GitHub App credentials from `~/.config/vergil/identities.toml`
   or environment variables
2. Injects `app.pem` and `app.env` into `~/.config/vergil/` inside the
   VM (mode 600)
3. Configures git to rewrite `git@github.com:` URLs to HTTPS
4. Installs vergil-tooling via `uv tool install`
5. Runs a verification check (5 assertions)

## Credential Model

Vergil uses GitHub App authentication. Each identity corresponds to a
GitHub App with fine-grained repository permissions.

**Credentials at rest** (inside the VM):

| File | Contents | Permissions |
| ---- | -------- | ----------- |
| `~/.config/vergil/app.pem` | GitHub App private key | 600 |
| `~/.config/vergil/app.env` | `APP_ID=<id>` | 600 |

**Token acquisition** happens dynamically at runtime. The `vrg-git` and
`vrg-gh` wrappers (provided by vergil-tooling) mint short-lived
installation tokens from the App private key on each invocation. No
long-lived tokens are stored.

The git HTTPS rewrite (`url."https://github.com/".insteadOf
"git@github.com:"`) ensures all git operations go through HTTPS, where
the credential helper can inject the installation token.

## SSH Terminal Environment Forwarding

When agents access VMs over SSH, the terminal's keyboard protocol
capabilities are normally lost. The VM's sshd is configured with a
drop-in at `/etc/ssh/sshd_config.d/10-acceptenv-terminal.conf` that
accepts three environment variables:

| Variable | Purpose |
| -------- | ------- |
| `COLORTERM` | Terminal color capability |
| `TERM_PROGRAM` | Terminal application name |
| `TERM_PROGRAM_VERSION` | Terminal version |

This allows Claude Code to detect keyboard protocol support
(shift+enter, alt+enter) when accessed over SSH from a capable
terminal. The client side (`SendEnv`) is configured by vergil-tooling's
`vrg-vm session` command.
