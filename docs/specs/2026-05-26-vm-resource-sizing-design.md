# VM Resource Sizing Design

**Issue:** [#34 — Reevaluate VM resource sizing for multi-agent Claude Code workloads](https://github.com/vergil-project/vergil-vm/issues/34)

**Date:** 2026-05-26

## Problem

The current VM template allocates 4 CPUs / 2 GiB RAM — far too little for
the target workload of 4 concurrent Claude Code sessions. Resource allocation
also has no per-user override mechanism; the template bakes in a single set
of values that every user gets.

## Design

Two changes across two repositories:

1. **vergil-vm** — update template defaults to conservative general-purpose values.
2. **vergil-tooling** — add optional per-identity resource overrides in
   `identities.toml`, wired through `create_vm()`.

### Release ordering

The two repos can be updated independently in either order:

- **New tooling + old template:** overrides are applied via `--set` flags on
  top of whatever the template contains. Works correctly.
- **New template + old tooling:** users get the updated defaults (4 GiB
  instead of 2 GiB) without override support. Still an improvement.

Both repos should be updated before documenting the override feature to
end users.

### Template defaults (vergil-vm)

`templates/agent.yaml` defines conservative defaults that work on modest
hardware (16 GB total RAM). Users with more powerful machines override
via `identities.toml`.

```yaml
cpus: 4
memory: "4GiB"
disk: "50GiB"
```

The `cpus` value stays at 4 (unchanged). Memory increases from 2 GiB to
4 GiB. Disk stays at 50 GiB.

A comment block documents the resource budget and override mechanism:

```yaml
# Resource allocation — conservative defaults for modest hardware.
#
# Override per-identity in ~/.config/vergil/identities.toml:
#   cpus = 12
#   memory = "32GiB"
#   disk = "100GiB"
#
# Or at create time:  limactl create ... --set='.cpus = N' --set='.memory = "XGiB"'
# On a stopped VM:    limactl edit <instance>
cpus: 4
memory: "4GiB"
disk: "50GiB"
```

### Identity-level overrides (vergil-tooling)

Per-user resource tuning belongs in `identities.toml` because VM sizing is
user-specific (hardware varies widely), not product-specific.

Example configuration for a 128 GB M5 MacBook Pro running Ollama (27B model)
alongside 4 concurrent Claude Code sessions:

```toml
[identities.vergil]
projects_dir = "/Users/user/dev/projects"
vm_instance = "vergil-agent"
auth_type = "app"
app_id = 12345
private_key_path = "~/.config/vergil/keys/key.pem"
claude_token_path = "~/.config/vergil/keys/claude-oauth-token"
cpus = 12
memory = "32GiB"
```

All three resource fields (`cpus`, `memory`, `disk`) are optional. When
absent, the template defaults apply.

Resource overrides apply at VM creation time only. To apply changed
overrides to an existing VM, run `vrg-vm rebuild`.

### Changes to vergil-tooling

**`identity.py` — Identity dataclass:**

Add three optional fields:

```python
@dataclass
class Identity:
    vm_instance: str
    # ...existing fields...
    cpus: int | None = None
    memory: str | None = None
    disk: str | None = None
```

**`identity.py` — load_config:**

Parse the new fields from the TOML data:

```python
identities[name] = Identity(
    # ...existing fields...
    cpus=data.get("cpus"),
    memory=data.get("memory"),
    disk=data.get("disk"),
)
```

**`identity.py` — validation:**

Validate resource fields at config load time with clear error messages.
This catches syntax errors early rather than letting them surface as
opaque Lima failures during VM creation.

- `cpus`: must be a positive integer
- `memory`: must match `<number>GiB` (e.g., `"4GiB"`, `"32GiB"`)
- `disk`: must match `<number>GiB` (e.g., `"50GiB"`, `"100GiB"`)

```python
import re

_SIZE_PATTERN = re.compile(r"^\d+GiB$")

def _validate_identity_resources(name: str, identity: Identity) -> None:
    if identity.cpus is not None:
        if not isinstance(identity.cpus, int) or identity.cpus < 1:
            print(
                f"ERROR: identity '{name}': cpus must be a positive integer,"
                f" got {identity.cpus!r}",
                file=sys.stderr,
            )
            raise SystemExit(1)
    for field in ("memory", "disk"):
        value = getattr(identity, field)
        if value is not None and not _SIZE_PATTERN.fullmatch(value):
            print(
                f"ERROR: identity '{name}': {field} must be '<number>GiB'"
                f" (e.g., \"32GiB\"), got {value!r}",
                file=sys.stderr,
            )
            raise SystemExit(1)
```

Called from `load_config` after constructing each `Identity`.

**`lima.py` — create_vm:**

Accept optional resource overrides and pass them as `--set` flags:

```python
def create_vm(
    instance: str,
    template: Path,
    projects_dir: str,
    *,
    cpus: int | None = None,
    memory: str | None = None,
    disk: str | None = None,
) -> None:
    args = [
        "create",
        f"--name={instance}",
        "--tty=false",
        f'--set=.mounts[0].location = "{projects_dir}"',
    ]
    if cpus is not None:
        args.append(f"--set=.cpus = {cpus}")
    if memory is not None:
        args.append(f'--set=.memory = "{memory}"')
    if disk is not None:
        args.append(f'--set=.disk = "{disk}"')
    args.append(str(template))
    _limactl(*args)
```

**`vrg_vm.py` — _cmd_create and _cmd_rebuild:**

Pass identity resource fields through to `create_vm`:

```python
create_vm(
    identity.vm_instance, template, identity.projects_dir,
    cpus=identity.cpus, memory=identity.memory, disk=identity.disk,
)
```

## Resource budget reference

For a 128 GB machine running Ollama + 4 Claude Code sessions:

| Component | Memory |
|-----------|--------|
| Ollama (27B Q4) | ~20–25 GiB |
| macOS + Safari + iTerm | ~8–10 GiB |
| **Host total** | **~30–35 GiB** |
| **VM (recommended)** | **32 GiB** |
| **Unallocated** | **~61–66 GiB** |

CPU: 12 of 18 cores to the VM, leaving 6 for Ollama inference + macOS UI.

This budget leaves substantial headroom for scaling up to larger LLM models
(a 70B model at Q4 needs ~40–45 GiB, still fitting within the unallocated
pool).

## Scope

This design covers only the resource override mechanism and updated defaults.
It does not change:

- VM provisioning scripts or installed packages
- Session management or credential injection
- Disk allocation (stays at 50 GiB unless overridden)
