# Site Documentation Design

**Issue:** [#35](https://github.com/vergil-project/vergil-vm/issues/35)
**Date:** 2026-05-28

## Problem

The documentation site at `docs/site/` has MkDocs infrastructure in place
(Material theme, strict mode, extensions) but no real content — `index.md`
is a single welcome sentence and `getting-started.md` is a TODO stub. The
README Overview section is also empty.

## Audience

Both newcomers onboarding to Vergil and existing contributors working with
the VM layer. The home page and getting-started guide are accessible to
newcomers; architecture and operations pages assume ecosystem familiarity.

## Structural Approach

Mirror the vergil-docker documentation structure, which is the closest
analog — both are infrastructure repos with a build pipeline, a
template/image definition, and operational concerns. This gives a 5-tab
nav layout that maps cleanly to the content and leaves room to grow.

## Navigation Structure

```yaml
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

## Page Specifications

### Home (`index.md`)

Opening paragraph explains what vergil-vm is: Lima VM definitions that
create isolated Ubuntu 24.04 execution environments for Vergil AI agent
sessions.

Ecosystem context section (brief): vergil-tooling provides the CLI,
vergil-vm defines the VM, vergil-docker provides dev containers. These
are complementary — vergil-docker images are for CI and local validation;
vergil-vm instances are long-running agent execution environments.

Component table listing the four deliverables: VM template
(`templates/agent.yaml`), build script (`scripts/build.sh`), credential
provisioning (`scripts/vrg-vm-init.sh`), and test suite (`tests/`).

"What's in the box" summary: Ubuntu 24.04 LTS, rootless containerd,
core development tools (git, gh, jq, ripgrep, fzf), Node.js 22, Claude
Code, uv, zsh.

Quick links to Getting Started, Architecture, and Operations.

### Getting Started (`getting-started.md`)

Prerequisites: Lima 2.0+, macOS or Linux, host identity configuration
(`~/.config/vergil/identities.toml` or environment variables).

Step-by-step walkthrough:

1. Create a VM from the template (`limactl create` with `--set` for the
   projects mount path).
2. Start the VM and wait for the readiness probe.
3. Initialize credentials (`vrg-vm-init.sh <identity> <instance>`).
4. Shell into the VM, verify tools, launch Claude Code.

Each step includes the exact command and expected output or success
indicator.

Ends with links to Architecture for deeper understanding and Operations
for build/test workflows.

### Architecture Overview (`architecture/index.md`)

VM anatomy: Lima wraps QEMU to run an Ubuntu 24.04 guest with rootless
containerd. The host communicates via SSH; a single `/projects` mount
provides writable access to the host project directory.

Provisioning pipeline walkthrough in order:

1. System provisioning (root): OS packages, GitHub CLI, Node.js, Claude
   Code, yq, zsh default shell, sshd terminal env config.
2. User provisioning (lima user): uv, zsh config.
3. Readiness probe: waits for gh, uv, claude, and containerd.
4. Credential injection (post-creation, manual): `vrg-vm-init.sh`.

Installed tools table with tool name, source, and purpose.

Credential model: GitHub App authentication via `app.pem` and `app.env`
injected into `~/.config/vergil/`. Token acquisition happens dynamically
at runtime through `vrg-git` / `vrg-gh` wrappers provided by
vergil-tooling. Raw credentials never leave the VM.

SSH terminal environment forwarding: sshd drop-in config accepts
`COLORTERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION` so Claude Code can
detect keyboard protocol support (shift+enter, alt+enter) when accessed
over SSH.

### Design Decision: VM Isolation Model (`architecture/decisions/vm-isolation-model.md`)

ADR format following vergil-docker's pattern. Covers:

- Why full VMs (Lima/QEMU) instead of containers for agent execution —
  stronger isolation boundary, persistent state across sessions, full OS
  for installing arbitrary tools.
- Why rootless containerd (user mode, not system) — agents can pull and
  run containers without root privileges.
- Why Ubuntu 24.04 LTS — broad tool availability, long support window,
  familiar to most developers.

### Design Decision: Credential Injection (`architecture/decisions/credential-injection.md`)

ADR format. Covers:

- Why post-creation injection instead of baking credentials into the
  template — keeps the template generic and reusable across identities.
- Why GitHub App authentication instead of OAuth/PAT — apps have
  fine-grained permissions, installation tokens are short-lived, and
  each identity maps to a distinct app.
- Why dynamic token acquisition via wrappers — credentials at rest are
  the raw app key; tokens are minted on demand by `vrg-git` / `vrg-gh`,
  minimizing exposure window.

### Build and Test (`operations/build-and-test.md`)

How `build.sh` works: validates the Lima template, creates a temporary
VM named `vergil-agent-test` with the repo mounted at `/projects`, runs
the full test suite inside it, and cleans up on exit.

The `--keep` flag keeps the VM running after tests for debugging.

Test suite table listing each `test_*.sh` file, what it verifies, and
key assertions:

| Test | Verifies |
| ---- | -------- |
| `test_base.sh` | Ubuntu 24.04, zsh default shell, passwordless sudo |
| `test_containerd.sh` | Rootless containerd running, nerdctl pull/run |
| `test_credentials.sh` | Credential files exist with correct permissions |
| `test_ssh.sh` | sshd accepts terminal env vars |
| `test_tools.sh` | All dev tools installed (git, gh, uv, node, claude, etc.) |
| `test_vergil.sh` | vergil-tooling installs and vrg-* commands resolve |

How to run tests locally: `./scripts/build.sh` (or `--keep` for
debugging). How to add a new test: create `tests/test_<name>.sh`, the
runner picks it up automatically.

### Resource Tuning (`operations/resource-tuning.md`)

Default resources: 4 CPUs, 4 GiB memory, 50 GiB disk. Conservative
defaults suitable for modest hardware.

Three override mechanisms:

1. Per-identity in `~/.config/vergil/identities.toml` (cpus, memory,
   disk fields) — applied by `vrg-vm create`.
2. At create time: `limactl create ... --set='.cpus = N'`.
3. On a stopped VM: `limactl edit <instance>`.

### Troubleshooting (`operations/troubleshooting.md`)

Common issues with diagnostic steps:

- **Provisioning failures**: check cloud-init logs via
  `limactl shell <instance> -- cat /var/log/cloud-init-output.log`.
- **Readiness probe timeout** (30-minute limit): verify network
  connectivity inside VM, check that apt/npm/curl can reach external
  sources.
- **Credential verification failures**: run `vm-verify-credentials.sh`
  inside the VM, check file permissions and paths.
- **Containerd not starting**: verify `containerd.user = true` in
  template, check `systemctl --user status containerd`.
- **Mount issues**: verify the `--set` path was absolute and exists on
  the host.

### Releases (standard boilerplate)

- `changelog.md`: pointer to CHANGELOG.md on GitHub (matches
  vergil-docker and vergil-claude-plugin pattern).
- `releases/index.md`: placeholder noting release notes are generated
  during the release process.

### README.md Update

Fill in the Overview section with a condensed version of index.md: what
vergil-vm is (one sentence), what it provides (VM template, build
pipeline, credential provisioning, test suite), and a link to the full
documentation site.

## mkdocs.yml Changes

Update the existing `mkdocs.yml` to:

- Add `repo_name: vergil-project/vergil-vm` (missing from current config)
- Add `site_description` (missing from current config)
- Add `extra` block with `version.provider: mike` (matches sibling repos)
- Add `extra_css` for `stylesheets/extra.css` (matches sibling repos)
- Add `anchor_linenums: true` to `pymdownx.highlight` (matches siblings)
- Update `nav` to the full structure above

## New Files

```
docs/site/docs/
├── index.md                                    (rewrite)
├── getting-started.md                          (rewrite)
├── changelog.md                                (new)
├── releases/
│   └── index.md                                (new)
├── architecture/
│   ├── index.md                                (new)
│   └── decisions/
│       ├── vm-isolation-model.md               (new)
│       └── credential-injection.md             (new)
├── operations/
│   ├── build-and-test.md                       (new)
│   ├── resource-tuning.md                      (new)
│   └── troubleshooting.md                      (new)
└── stylesheets/
    └── extra.css                               (new)
```

Plus updates to `mkdocs.yml` and `README.md`.

## Out of Scope

- Automated API reference generation (no code API to document)
- Contributing guidelines (covered by vergil-tooling standards)
- CI/CD documentation (CI workflows are standard and self-explanatory)
