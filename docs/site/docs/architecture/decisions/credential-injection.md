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

```text
url."https://github.com/".insteadOf "git@github.com:"
```

This forces all git operations through HTTPS, where the credential
helper can inject the installation token.

**Why?** SSH-based git access would require deploying SSH keys per
identity. HTTPS with the token credential helper is simpler and
leverages the existing App authentication flow. SSH agent forwarding
is explicitly disabled (`forwardAgent: false`) to prevent credential
leakage from the host.
