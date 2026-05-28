# Site Documentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write complete documentation site content for vergil-vm, replacing placeholder stubs with real pages.

**Architecture:** MkDocs with Material theme, mirroring the vergil-docker site structure. Five nav tabs: Home, Releases, Getting Started, Architecture, Operations. All files under `docs/site/docs/`.

**Tech Stack:** MkDocs Material, Markdown

**Design spec:** `docs/specs/2026-05-28-site-documentation-design.md`

**Worktree:** `.worktrees/issue-35-site-docs/`
**Branch:** `feature/35-site-docs`

---

### Task 1: Site infrastructure — mkdocs.yml, extra.css, release boilerplate

**Files:**
- Modify: `docs/site/mkdocs.yml`
- Create: `docs/site/docs/stylesheets/extra.css`
- Create: `docs/site/docs/changelog.md`
- Create: `docs/site/docs/releases/index.md`

- [ ] **Step 1: Rewrite mkdocs.yml**

Replace the entire contents of `docs/site/mkdocs.yml` with:

```yaml
site_name: Vergil VM
site_description: Lima VM definitions for isolated Vergil agent execution environments
repo_url: https://github.com/vergil-project/vergil-vm
repo_name: vergil-project/vergil-vm

docs_dir: docs
strict: true
edit_uri: ""

extra:
  version:
    provider: mike
extra_css:
  - stylesheets/extra.css

plugins:
  - search

theme:
  name: material
  palette:
    - media: "(prefers-color-scheme: light)"
      scheme: default
      primary: indigo
      accent: indigo
      toggle:
        icon: material/brightness-7
        name: Switch to dark mode
    - media: "(prefers-color-scheme: dark)"
      scheme: slate
      primary: indigo
      accent: indigo
      toggle:
        icon: material/brightness-4
        name: Switch to light mode
  features:
    - navigation.tabs
    - navigation.sections
    - navigation.indexes
    - navigation.top
    - content.code.copy
    - search.highlight
    - search.suggest

markdown_extensions:
  - admonition
  - pymdownx.details
  - pymdownx.highlight:
      anchor_linenums: true
  - pymdownx.superfences
  - pymdownx.tabbed:
      alternate_style: true
  - pymdownx.snippets
  - tables
  - toc:
      permalink: true

nav:
  - Home: index.md
  - Releases:
      - Changelog: changelog.md
      - Release Notes:
          - releases/index.md
  - Getting Started: getting-started.md
  - Architecture:
      - architecture/index.md
      - Design Decisions:
          - VM Isolation Model: architecture/decisions/vm-isolation-model.md
          - Credential Injection: architecture/decisions/credential-injection.md
  - Operations:
      - Build and Test: operations/build-and-test.md
      - Resource Tuning: operations/resource-tuning.md
      - Troubleshooting: operations/troubleshooting.md
```

- [ ] **Step 2: Create extra.css**

Create `docs/site/docs/stylesheets/extra.css`:

```css
.md-version::before {
  content: "Version:";
  margin-right: 0.4em;
  font-size: 0.8rem;
  color: var(--md-primary-bg-color);
  opacity: 0.7;
}
```

- [ ] **Step 3: Create changelog.md**

Create `docs/site/docs/changelog.md`:

```markdown
# Changelog

The changelog is generated during the release process. See the
[CHANGELOG.md](https://github.com/vergil-project/vergil-vm/blob/develop/CHANGELOG.md)
on GitHub for the latest version.
```

- [ ] **Step 4: Create releases/index.md**

Create `docs/site/docs/releases/index.md`:

```markdown
# Release Notes

Individual release notes are generated during the release process and published
here.
```

- [ ] **Step 5: Commit**

```bash
cd <worktree> && vrg-git add docs/site/mkdocs.yml docs/site/docs/stylesheets/extra.css docs/site/docs/changelog.md docs/site/docs/releases/index.md
cd <worktree> && vrg-commit --type docs --scope site --message "add site infrastructure, nav structure, and release boilerplate"
```

---

### Task 2: Home page

**Files:**
- Modify: `docs/site/docs/index.md`

- [ ] **Step 1: Rewrite index.md**

Replace the entire contents of `docs/site/docs/index.md` with:

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
cd <worktree> && vrg-git add docs/site/docs/index.md
cd <worktree> && vrg-commit --type docs --scope site --message "write home page with ecosystem context and component overview"
```

---

### Task 3: Getting Started

**Files:**
- Modify: `docs/site/docs/getting-started.md`

- [ ] **Step 1: Rewrite getting-started.md**

Replace the entire contents of `docs/site/docs/getting-started.md` with:

```markdown
# Getting Started

Create a Vergil identity VM, initialize credentials, and launch your
first agent session.

## Prerequisites

- **Lima 2.0+** — VM manager
  ([install](https://lima-vm.io/docs/installation/))
- **macOS or Linux** host
- **Identity configuration** — either environment variables or
  `~/.config/vergil/identities.toml` with your GitHub App credentials
  (see [Credential Injection](architecture/decisions/credential-injection.md)
  for background)

## 1. Create the VM

Clone the repository and create a VM from the agent template. The
`--set` flag configures the host directory that will be mounted at
`/projects` inside the VM.

```bash
git clone https://github.com/vergil-project/vergil-vm.git
cd vergil-vm

limactl create --name=vergil-agent templates/agent.yaml \
  --set='.mounts[0].location = "/absolute/path/to/your/projects"' \
  --tty=false
```

Then start the VM:

```bash
limactl start vergil-agent
```

The readiness probe waits up to 30 minutes for all provisioning to
complete. When it finishes, you'll see:

```text
vergil-agent VM is ready.
```

## 2. Initialize credentials

Inject GitHub App credentials so the agent can authenticate via
installation tokens:

```bash
./scripts/vrg-vm-init.sh <identity-name> vergil-agent
```

This reads credentials from `~/.config/vergil/identities.toml` (or
from `VRG_APP_ID` and `VRG_PRIVATE_KEY_PATH` environment variables),
injects them into the VM, configures git for HTTPS access, installs
vergil-tooling, and runs a verification check.

Expected output ends with:

```text
Credential checks: 5/5 passed

=== VM initialization complete ===
```

## 3. Start a session

Shell into the VM:

```bash
limactl shell vergil-agent
```

Verify the core tools are available:

```bash
gh --version
uv --version
claude --version
nerdctl --version
```

Launch Claude Code against your projects:

```bash
limactl shell vergil-agent --workdir /projects -- claude
```

## Next Steps

- [Architecture](architecture/index.md) — understand the VM anatomy and
  provisioning pipeline
- [Build and Test](operations/build-and-test.md) — run the test suite
  against template changes
- [Resource Tuning](operations/resource-tuning.md) — adjust CPU, memory,
  and disk for your workload
```

- [ ] **Step 2: Commit**

```bash
cd <worktree> && vrg-git add docs/site/docs/getting-started.md
cd <worktree> && vrg-commit --type docs --scope site --message "write getting started guide with VM creation and credential setup"
```

---

### Task 4: Architecture overview

**Files:**
- Create: `docs/site/docs/architecture/index.md`

- [ ] **Step 1: Create architecture/index.md**

Create `docs/site/docs/architecture/index.md`:

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
cd <worktree> && vrg-git add docs/site/docs/architecture/index.md
cd <worktree> && vrg-commit --type docs --scope site --message "write architecture overview with provisioning pipeline and credential model"
```

---

### Task 5: Design decision — VM Isolation Model

**Files:**
- Create: `docs/site/docs/architecture/decisions/vm-isolation-model.md`

- [ ] **Step 1: Create vm-isolation-model.md**

Create `docs/site/docs/architecture/decisions/vm-isolation-model.md`:

```markdown
# VM Isolation Model

Each Vergil agent identity runs inside a dedicated Lima virtual machine
rather than a container. This page documents the rationale behind the
isolation strategy.

**Implemented:** May 2026 |
**Issue:** [#1](https://github.com/vergil-project/vergil-vm/issues/1)

## Problem

Vergil agents need isolated execution environments where they can
install tools, manage credentials, run containers, and persist state
across sessions — all without interfering with other identities or the
host system.

## Key Decisions

### Full VMs instead of containers

Agent execution environments use Lima/QEMU virtual machines rather than
Docker or Podman containers.

**Why?** VMs provide a stronger isolation boundary than containers.
Each agent gets a full OS with its own kernel, filesystem, and network
stack. This matters because:

- Agents install arbitrary packages (`apt-get install`, `npm install -g`,
  `uv tool install`) — a container would need to be rebuilt or use
  volume mounts for persistence.
- Agents hold credentials that must be isolated per identity — VM-level
  isolation is simpler to reason about than container namespace
  configuration.
- Agents benefit from persistent state across sessions — the VM
  survives host reboots and can be stopped/started without
  reprovisioning.

**Trade-off:** VMs are heavier than containers (more memory, longer
startup). This is acceptable because agent VMs are long-lived — they are
created once and reused across many sessions, amortizing the startup
cost.

### Rootless containerd

Containerd runs as a user service (`containerd.user = true`) rather
than a system daemon.

**Why?** Agents can pull and run containers inside the VM (via
`nerdctl`) without root privileges. This supports workflows that use
dev containers or other containerized tools while maintaining the
principle of least privilege.

**Trade-off:** Rootless containerd has some limitations compared to
system mode (e.g., no privileged containers, limited networking
options). These limitations are acceptable for agent workloads, which
use containers for development tools rather than production services.

### Ubuntu 24.04 LTS

The VM base image is Ubuntu 24.04 (Noble Numbat), the current LTS
release.

**Why?**

- Broad package availability — most development tools are available via
  apt or have Ubuntu install instructions.
- Long support window (until April 2029 for standard support, 2034 for
  extended) — avoids forced base image churn.
- Familiar to most developers — reduces friction when debugging inside
  the VM.

**Trade-off:** Ubuntu is larger than minimal distributions like Alpine.
Disk size is not a primary concern for long-lived VMs with 50 GiB
default disks.
```

- [ ] **Step 2: Commit**

```bash
cd <worktree> && vrg-git add docs/site/docs/architecture/decisions/vm-isolation-model.md
cd <worktree> && vrg-commit --type docs --scope site --message "write VM isolation model design decision"
```

---

### Task 6: Design decision — Credential Injection

**Files:**
- Create: `docs/site/docs/architecture/decisions/credential-injection.md`

- [ ] **Step 1: Create credential-injection.md**

Create `docs/site/docs/architecture/decisions/credential-injection.md`:

```markdown
# Credential Injection

Agent VMs receive GitHub App credentials after creation through a
separate initialization step rather than having credentials baked into
the VM template. This page documents the rationale.

**Implemented:** May 2026 |
**Issue:** [#1](https://github.com/vergil-project/vergil-vm/issues/1)

## Problem

Agents need GitHub credentials to clone repositories, push commits, and
interact with the GitHub API. The credential strategy must support
multiple identities (each with their own GitHub App) while keeping the
VM template generic.

## Key Decisions

### Post-creation injection

Credentials are injected into the VM after it is created and started,
via `scripts/vrg-vm-init.sh`, rather than being embedded in the Lima
template.

**Why?** The VM template defines the execution environment — it is the
same for all identities. Credentials are identity-specific. Separating
these concerns means:

- One template serves all identities. No template-per-identity
  proliferation.
- The template can be version-controlled and shared without exposing
  secrets.
- Credential rotation does not require VM recreation — re-run
  `vrg-vm-init.sh` with updated credentials.

**Trade-off:** VM creation is a two-step process (create + initialize)
rather than a single command. This is acceptable because VM creation is
infrequent — typically once per identity.

### GitHub App authentication

Each identity maps to a GitHub App rather than using OAuth tokens or
personal access tokens (PATs).

**Why?**

- **Fine-grained permissions** — each App is scoped to specific
  repositories and operations.
- **Short-lived tokens** — installation tokens expire after one hour,
  limiting the blast radius of a compromised token.
- **Identity separation** — each App has its own identity in git
  history, making it clear which agent made which commit.
- **No user session dependency** — Apps authenticate independently of
  any human user's OAuth session.

**Trade-off:** GitHub Apps require initial setup (creating the App,
generating a private key, installing it on target repositories). This
one-time cost is justified by the operational benefits.

### Dynamic token acquisition

The raw App private key is stored in the VM, but tokens are minted on
demand by `vrg-git` and `vrg-gh` (vergil-tooling wrappers) rather than
being pre-generated and cached.

**Why?** Installation tokens have a one-hour lifetime. Generating them
at the moment of use ensures they are always fresh. The wrappers handle
token minting transparently — the agent uses `vrg-git push` as if it
were a normal git command.

**Trade-off:** Every git/gh operation incurs a token-minting API call.
The latency is negligible (~100ms) and GitHub's rate limits for App
token creation are generous (5000/hour).

### HTTPS-only git access

The VM is configured with a global git URL rewrite:

```
url."https://github.com/".insteadOf "git@github.com:"
```

This forces all git operations through HTTPS, where the credential
helper can inject the installation token.

**Why?** SSH-based git access would require deploying SSH keys per
identity. HTTPS with the token credential helper is simpler and
leverages the existing App authentication flow. SSH agent forwarding
is explicitly disabled (`forwardAgent: false`) to prevent credential
leakage from the host.
```

- [ ] **Step 2: Commit**

```bash
cd <worktree> && vrg-git add docs/site/docs/architecture/decisions/credential-injection.md
cd <worktree> && vrg-commit --type docs --scope site --message "write credential injection design decision"
```

---

### Task 7: Operations — Build and Test

**Files:**
- Create: `docs/site/docs/operations/build-and-test.md`

- [ ] **Step 1: Create build-and-test.md**

Create `docs/site/docs/operations/build-and-test.md`:

```markdown
# Build and Test

## How It Works

The build script (`scripts/build.sh`) validates the VM template,
creates a temporary VM, runs the full test suite inside it, and cleans
up:

```text
build.sh
  ├─ Validate template syntax (limactl validate)
  ├─ Delete any previous test VM
  ├─ Create VM from template (name: vergil-agent-test)
  │   └─ Mount: repo root → /projects in VM
  ├─ Start VM (wait for readiness probe, up to 30 min)
  ├─ Run test suite (tests/run-tests.sh)
  │   └─ Execute each test_*.sh inside VM via limactl shell
  └─ Cleanup: stop and delete VM
```

## Running Locally

Build, test, and clean up:

```bash
./scripts/build.sh
```

Build and test, but keep the VM running for debugging:

```bash
./scripts/build.sh --keep
```

When using `--keep`, the VM remains available after tests complete:

```bash
limactl shell vergil-agent-test
```

## Test Suite

All tests run inside the VM via `limactl shell`. The test runner
(`tests/run-tests.sh`) automatically discovers and executes every
`test_*.sh` file in the `tests/` directory.

| Test | Verifies |
| ---- | -------- |
| `test_base.sh` | Ubuntu 24.04, zsh default shell, passwordless sudo |
| `test_containerd.sh` | Rootless containerd running, nerdctl can pull and run containers |
| `test_credentials.sh` | Credential files exist with correct permissions, git HTTPS config |
| `test_ssh.sh` | sshd accepts `COLORTERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION` |
| `test_tools.sh` | All development tools installed (git, gh, uv, node, claude, jq, yq, rg, fzf) |
| `test_vergil.sh` | vergil-tooling installs via uv, `vrg-*` commands resolve on PATH |

Failed tests are automatically re-run with output displayed for
debugging. The runner reports a summary at the end:

```text
6 tests, 0 failures
```

## Adding a New Test

Create a new file matching the `test_*.sh` pattern in `tests/`:

```bash
#!/bin/bash
set -euo pipefail

# Verify something specific about the VM
command -v my-tool >/dev/null 2>&1 || { echo "my-tool not found"; exit 1; }
```

The test runner picks it up automatically on the next build — no
registration or configuration needed. Tests run inside the VM, so they
have access to all provisioned tools and the `/projects` mount.
```

- [ ] **Step 2: Commit**

```bash
cd <worktree> && vrg-git add docs/site/docs/operations/build-and-test.md
cd <worktree> && vrg-commit --type docs --scope site --message "write build and test operations guide"
```

---

### Task 8: Operations — Resource Tuning

**Files:**
- Create: `docs/site/docs/operations/resource-tuning.md`

- [ ] **Step 1: Create resource-tuning.md**

Create `docs/site/docs/operations/resource-tuning.md`:

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
cd <worktree> && vrg-git add docs/site/docs/operations/resource-tuning.md
cd <worktree> && vrg-commit --type docs --scope site --message "write resource tuning operations guide"
```

---

### Task 9: Operations — Troubleshooting

**Files:**
- Create: `docs/site/docs/operations/troubleshooting.md`

- [ ] **Step 1: Create troubleshooting.md**

Create `docs/site/docs/operations/troubleshooting.md`:

```markdown
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

The `/projects` mount requires an absolute host path set at creation
time via `--set`. Common issues:

- **Relative path** — the `--set` value must be an absolute path
  (e.g., `/Users/you/projects`, not `~/projects`)
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
```

- [ ] **Step 2: Commit**

```bash
cd <worktree> && vrg-git add docs/site/docs/operations/troubleshooting.md
cd <worktree> && vrg-commit --type docs --scope site --message "write troubleshooting guide"
```

---

### Task 10: README.md overview

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README.md Overview section**

Replace the `## Overview` section (currently just "TODO") with:

```markdown
## Overview

Vergil-vm defines Lima VM templates that create isolated Ubuntu 24.04
execution environments for Vergil AI agent sessions. Each VM includes
rootless containerd, core development tools, Claude Code, and GitHub App
credential provisioning — everything an agent identity needs to operate
independently.

See the [documentation site](https://vergil-project.github.io/vergil-vm/)
for the full guide.
```

The rest of the README (Status, Getting Started link, License) stays
unchanged.

- [ ] **Step 2: Commit**

```bash
cd <worktree> && vrg-git add README.md
cd <worktree> && vrg-commit --type docs --scope readme --message "fill in README overview section"
```
