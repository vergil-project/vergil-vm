# SSH Terminal Environment Forwarding Design

**Issue:** [#39 — shift+enter does not insert newline in Claude Code over SSH into VM](https://github.com/vergil-project/vergil-vm/issues/39)

**Date:** 2026-05-27

## Problem

When running Claude Code over SSH into the Lima VM, shift+enter and alt+enter
submit the prompt instead of inserting a newline. Multi-line input is not
possible.

Locally, iTerm2 (and other modern terminals) set environment variables like
`TERM_PROGRAM=iTerm.app`, `TERM_PROGRAM_VERSION=3.7.3`, and
`COLORTERM=truecolor`. Claude Code uses these to detect support for the kitty
keyboard protocol, which encodes modifier+key combinations as distinct escape
sequences. For iTerm.app specifically, Claude Code gates keyboard protocol
support on version >= 3.6.6 via `TERM_PROGRAM_VERSION`. Without these
variables, shift+enter and alt+enter are indistinguishable from plain
enter — they all send `\r`.

SSH does not forward these variables by default. The client must `SendEnv` and
the server must `AcceptEnv` for each variable. Currently:

- The VM's sshd has no provisioned `AcceptEnv` for `TERM_PROGRAM`,
  `TERM_PROGRAM_VERSION`, or `COLORTERM` (an ad-hoc `AcceptEnv COLORTERM`
  exists in the running VM but is not in the `agent.yaml` template — it
  won't survive a rebuild).
- The `vrg-vm session` wrapper in vergil-tooling passes no SSH environment
  forwarding options to `limactl shell`.

Since vergil-tooling owns the session launch wrapper (`vrg-vm session`) and
vergil-vm owns the VM template, we control both sides and can fix this
completely — users do not need to configure anything.

## Verification gate

Before implementing, manually confirm the hypothesis in a running VM:

```bash
TERM_PROGRAM=iTerm.app TERM_PROGRAM_VERSION=3.7.3 COLORTERM=truecolor claude
```

If shift+enter inserts a newline, the fix is validated — proceed with
implementation. If it does not, investigate further before writing code.

## Design

### 1. Server side: sshd AcceptEnv (vergil-vm)

Add a system-mode provisioning step in `templates/agent.yaml` that creates an
sshd drop-in config accepting terminal environment variables:

```bash
cat > /etc/ssh/sshd_config.d/10-acceptenv-terminal.conf << 'EOF'
AcceptEnv COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION
EOF
```

This replaces the ad-hoc `10-acceptenv-colorterm.conf` with a single drop-in
that covers all three variables. The file name `10-acceptenv-terminal.conf`
groups all terminal-related AcceptEnv directives together.

This fix takes effect on next VM creation. Existing VMs require a rebuild
(`limactl delete` + `limactl create`) to pick up the new sshd configuration.

### 2. Client side: session wrapper (vergil-tooling)

In `vrg_vm.py`'s `_cmd_session()` function, configure Lima's SSH to forward
terminal environment variables before the `os.execvp()` call. Two options:

**Option A (Lima YAML):** Add `sendLocalEnv` to the Lima template's `ssh`
section:

```yaml
ssh:
  forwardAgent: false
  sendLocalEnv:
    COLORTERM: true
    TERM_PROGRAM: true
    TERM_PROGRAM_VERSION: true
```

**Option B (SSH options):** If Lima's `sendLocalEnv` doesn't support
per-variable control, the wrapper can set `LIMA_SSH_OPTS` or equivalent to
pass `-o SendEnv=TERM_PROGRAM -o SendEnv=TERM_PROGRAM_VERSION -o SendEnv=COLORTERM`
to the underlying SSH.

Option A is preferred if Lima supports it. Option B is the fallback.

**Scope note:** The vergil-tooling change is tracked as a separate issue in
that repository. This spec covers the vergil-vm side (sshd AcceptEnv +
acceptance test) and defines the interface contract (which variables the
server accepts) that the tooling side implements against.

### 3. Acceptance test (vergil-vm)

Add a test that verifies the sshd configuration accepts the required terminal
environment variables:

```bash
grep -q 'AcceptEnv.*COLORTERM' /etc/ssh/sshd_config.d/10-acceptenv-terminal.conf
grep -q 'AcceptEnv.*TERM_PROGRAM ' /etc/ssh/sshd_config.d/10-acceptenv-terminal.conf
grep -q 'AcceptEnv.*TERM_PROGRAM_VERSION' /etc/ssh/sshd_config.d/10-acceptenv-terminal.conf
```

This fits the existing test pattern in `tests/`.

## Changes summary

| Repo | Change | Blocking |
|------|--------|----------|
| vergil-vm | sshd AcceptEnv drop-in in agent.yaml provisioning | Yes |
| vergil-vm | Acceptance test for sshd config | Yes |
| vergil-tooling | `vrg-vm session` forwards TERM_PROGRAM, TERM_PROGRAM_VERSION, and COLORTERM | Yes (separate issue) |

## Out of scope

- Modifying the user's host SSH config or terminal emulator settings
- Forwarding all environment variables (security risk — only terminal-related
  variables are forwarded)
- Fixing the issue for users who bypass `vrg-vm session` and use raw
  `limactl shell` directly (documented as a known limitation)
