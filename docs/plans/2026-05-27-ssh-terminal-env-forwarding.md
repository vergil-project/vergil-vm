# SSH Terminal Environment Forwarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configure the VM's sshd to accept terminal environment variables (`TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, `COLORTERM`) so that Claude Code can detect the host terminal's keyboard protocol support over SSH, restoring shift+enter and alt+enter behavior.

**Architecture:** Add a system-mode provisioning step to the Lima template that writes an sshd drop-in config accepting the three terminal environment variables. Add an acceptance test verifying the config is present. The client-side forwarding (vergil-tooling's `vrg-vm session` wrapper) is a separate issue in that repo — this plan covers only the vergil-vm server side.

**Tech Stack:** Lima YAML, sshd_config, Bash (acceptance tests)

**Spec:** `docs/specs/2026-05-27-ssh-terminal-env-forwarding-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `templates/agent.yaml` | Modify | Add sshd drop-in provisioning to system-mode script |
| `tests/test_ssh.sh` | Create | Verify sshd AcceptEnv configuration |

---

## Task 0: Manual verification gate

Before writing any code, confirm that the environment variables are the
actual fix.

- [ ] **Step 1: Launch Claude Code with terminal env vars set**

Run inside the VM (over SSH):

```bash
TERM_PROGRAM=iTerm.app TERM_PROGRAM_VERSION=3.7.3 COLORTERM=truecolor claude
```

- [ ] **Step 2: Test shift+enter**

In the Claude Code prompt, press shift+enter. Expected: a newline is inserted
in the input area, the prompt is NOT submitted.

- [ ] **Step 3: Test alt+enter**

Press alt+enter. Expected: a newline is inserted in the input area.

**If both work:** proceed to Task 1.
**If either fails:** stop. The hypothesis is wrong — investigate further
before writing code.

---

## Task 1: Write the acceptance test

**Files:**
- Create: `tests/test_ssh.sh`

- [ ] **Step 1: Write the test**

Create `tests/test_ssh.sh`:

```bash
#!/bin/bash
# tests/test_ssh.sh — Verify SSH terminal environment forwarding.
set -euo pipefail

CONF="/etc/ssh/sshd_config.d/10-acceptenv-terminal.conf"

# Drop-in config file exists
test -f "$CONF"

# Accepts COLORTERM
grep -q 'AcceptEnv.*COLORTERM' "$CONF"

# Accepts TERM_PROGRAM (trailing space prevents matching only TERM_PROGRAM_VERSION)
grep -q 'AcceptEnv.*TERM_PROGRAM ' "$CONF"

# Accepts TERM_PROGRAM_VERSION
grep -q 'AcceptEnv.*TERM_PROGRAM_VERSION' "$CONF"

echo "test_ssh: all checks passed"
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
cd /projects/vergil-project/vergil-vm/.worktrees/issue-39-ssh-terminal-env && bash tests/test_ssh.sh
```

Expected: FAIL — the file `/etc/ssh/sshd_config.d/10-acceptenv-terminal.conf`
does not exist yet. The test should fail at the `test -f "$CONF"` line.

- [ ] **Step 3: Commit the failing test**

```bash
cd /projects/vergil-project/vergil-vm/.worktrees/issue-39-ssh-terminal-env && vrg-git add tests/test_ssh.sh && vrg-git commit -m "test(ssh): add acceptance test for terminal env AcceptEnv config"
```

---

## Task 2: Add sshd AcceptEnv provisioning to the VM template

**Files:**
- Modify: `templates/agent.yaml:48-88` (system-mode provision script)

- [ ] **Step 1: Add the sshd drop-in config step**

In `templates/agent.yaml`, inside the existing `- mode: system` provision
block's `script: |` section, add the following after the `chsh` line
(line 85) and before the `apt-get clean` line (line 87):

```yaml
    # sshd: accept terminal env vars so Claude Code detects keyboard
    # protocol support when accessed over SSH
    cat > /etc/ssh/sshd_config.d/10-acceptenv-terminal.conf << 'SSHD_CONF'
    AcceptEnv COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION
    SSHD_CONF
```

This goes inside the existing system-mode provision script — it is additional
shell commands, not a new provision entry. The heredoc content must NOT be
indented (sshd_config is whitespace-sensitive for directives).

After this edit, lines 85-91 of `templates/agent.yaml` should read:

```yaml
    chsh -s /bin/zsh "{{.User}}"

    # sshd: accept terminal env vars so Claude Code detects keyboard
    # protocol support when accessed over SSH
    cat > /etc/ssh/sshd_config.d/10-acceptenv-terminal.conf << 'SSHD_CONF'
    AcceptEnv COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION
    SSHD_CONF

    apt-get clean
    rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 2: Validate YAML syntax**

Run:

```bash
cd /projects/vergil-project/vergil-vm/.worktrees/issue-39-ssh-terminal-env && vrg-container-run -- vrg-validate
```

Expected: validation passes.

- [ ] **Step 3: Run the acceptance test to verify it passes**

The test runs inside the VM, but `10-acceptenv-terminal.conf` doesn't exist
yet in the running VM (the provisioning only runs at VM creation time). To
verify the test logic is correct against the expected file content, create the
file manually, run the test, then remove it:

```bash
sudo bash -c 'cat > /etc/ssh/sshd_config.d/10-acceptenv-terminal.conf << EOF
AcceptEnv COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION
EOF'

cd /projects/vergil-project/vergil-vm/.worktrees/issue-39-ssh-terminal-env && bash tests/test_ssh.sh

sudo rm /etc/ssh/sshd_config.d/10-acceptenv-terminal.conf
```

Expected: `test_ssh: all checks passed`

- [ ] **Step 4: Commit the provisioning change**

```bash
cd /projects/vergil-project/vergil-vm/.worktrees/issue-39-ssh-terminal-env && vrg-git add templates/agent.yaml && vrg-git commit -m "feat(ssh): accept terminal env vars for keyboard protocol detection

Adds an sshd drop-in config that accepts COLORTERM, TERM_PROGRAM,
and TERM_PROGRAM_VERSION from SSH clients. This allows Claude Code
to detect the host terminal's kitty keyboard protocol support,
restoring shift+enter and alt+enter behavior over SSH.

Closes #39"
```

---

## Task 3: Final validation and PR

- [ ] **Step 1: Run full validation**

```bash
cd /projects/vergil-project/vergil-vm/.worktrees/issue-39-ssh-terminal-env && vrg-container-run -- vrg-validate
```

Expected: all checks pass.

- [ ] **Step 2: Submit PR**

Use the `vergil:pr-workflow` skill or create the PR manually:

```bash
cd /projects/vergil-project/vergil-vm/.worktrees/issue-39-ssh-terminal-env && vrg-git push -u origin feature/39-ssh-terminal-env
```

Then create the PR against `develop` referencing issue #39.

---

## Follow-up (separate repo)

After this PR merges, file an issue in vergil-tooling to configure the
`vrg-vm session` wrapper to forward `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`,
and `COLORTERM` via SSH `SendEnv`. The server-side AcceptEnv from this PR
is the prerequisite — without it, the client-side forwarding has no effect.
