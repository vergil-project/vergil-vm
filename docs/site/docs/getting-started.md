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
