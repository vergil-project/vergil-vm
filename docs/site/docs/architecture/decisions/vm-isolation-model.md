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
