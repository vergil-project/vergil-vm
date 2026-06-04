# Per-Repo VM Profiles — Plan 1: Spec Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure-logic foundation for per-repo VM profiles in `vergil-tooling` — parse a repo's `vergil.toml [vm]` cascade, compose the effective VM spec across the five precedence tiers, derive/parse reversible instance names, and fingerprint a composed spec — all fully unit-tested with no Lima/VM side effects.

**Architecture:** Three new pure modules/extensions in `vergil-tooling`, each one responsibility: (1) `lib/config.py` gains a `[vm]` cascade parser; (2) `lib/identity.py` gains parsing for the nested `[identities.<id>.<org>.<repo>]` host-override tables; (3) a new `lib/vm_spec.py` holds the composition resolver, instance-name codec, and fingerprint. Everything is a deterministic function over parsed data, so it is tested entirely with in-memory dicts and `tmp_path` TOML fixtures.

**Tech Stack:** Python 3.14, `tomllib`, `dataclasses`, `hashlib` (stdlib only), `pytest`. Validation via `vrg-container-run -- vrg-validate`.

---

## Plan set (this is 1 of 3)

This feature is split into three dependency-ordered plans. Implement in order:

1. **Plan 1 — Spec foundation (this document):** parsing, composition, naming, fingerprint. Pure logic in `vergil-tooling`. No VM side effects.
2. **Plan 2 — VM lifecycle integration:** `lib/lima.py` provisioning (packages + provision hook + fingerprint marker), `vergil-vm` `templates/agent.yaml` changes, and `bin/vrg_vm.py` CLI (optional `<org>/<repo>` positional, base-vs-dedicated resolution, abort gate, create/rebuild/destroy/start/stop/session/update wiring, the loud under-provisioning warning).
3. **Plan 3 — Observability & lifecycle:** extended `vrg-vm list` (CPUS/MEM/DISK + process-tree AGENTS/HUMANS + SPEC states including `orphaned` and `under`), orphan enumeration/cleanup, staleness display.

**Source spec:** `vergil-vm/docs/specs/2026-06-04-per-repo-vm-profiles-design.md`.

## Execution context (cross-repo) — read before Task 1

This feature spans two repos. **Plan 1 is entirely in `vergil-tooling`.**

- Work happens in a **`vergil-tooling` worktree** on a feature branch — *not* in the
  `vergil-vm` worktree where this plan document lives.
- Set up once before Task 1:

  ```bash
  cd /Users/pmoore/dev/projects/vergil-project/vergil-tooling
  vrg-git worktree add .worktrees/vm-profiles -b feature/vm-profiles
  cd .worktrees/vm-profiles
  ```

  (No local vergil-tooling issue number exists; commits reference `vergil-vm#99`.)
- **Git policy (both repos):** use `vrg-git` for git, `vrg-commit` (NOT `git commit`)
  for commits. `vrg-commit` signature:
  `vrg-commit --type <feat|fix|docs|…> --scope <scope> --message "<subject>" [--body "<body>"]`.
- **Run tests / validation** from inside the worktree:
  `vrg-container-run -- vrg-validate` is the only validation command. To run a single
  test fast during a step: `vrg-container-run -- pytest tests/vergil_tooling/<file>::<test> -v`.
- Every commit step below uses `vrg-commit`; the literal `git add` shown is run via
  `vrg-git add`.

---

## File structure (Plan 1)

- **Modify** `src/vergil_tooling/lib/config.py` — add `[vm]` cascade parsing + a
  `VmStanza` dataclass; extend the section/key allow-list so `[vm]` and `[vm.<role>]`
  are recognized (the parser warns on unknown sections today).
- **Modify** `src/vergil_tooling/lib/identity.py` — parse nested
  `[identities.<id>.<org>.<repo>]` host-override tables into the `Identity`.
- **Create** `src/vergil_tooling/lib/vm_spec.py` — `ComposedSpec`, `compose_vm_spec`,
  `instance_name`, `parse_instance_name`, `spec_fingerprint`.
- **Create** `tests/vergil_tooling/test_vm_spec.py` — unit tests for `vm_spec.py`.
- **Modify** `tests/vergil_tooling/test_config.py` — tests for the `[vm]` parser.
- **Modify** `tests/vergil_tooling/test_identity.py` — tests for override parsing.
- **Modify** `docs/site/docs/guides/account-setup.md` — identity-key normalization
  (`[identities.user]` → `[identities.vergil-user]`, etc.).

Data model used across tasks (defined in Task 1 and Task 3, referenced everywhere):

- `VmStanza` (config.py): `packages: list[str]`, `cpus: int | None`,
  `memory: str | None`, `disk: str | None`, `stale_days: int | None`,
  `provision: str | None`, `roles: dict[str, RoleOverlay]`.
- `RoleOverlay` (config.py): `packages: list[str]`, `cpus: int | None`,
  `memory: str | None`, `disk: str | None`, `stale_days: int | None`,
  `provision: str | None` (same fields, all optional, no nested `roles`).
- `ComposedSpec` (vm_spec.py): `cpus: int`, `memory: str`, `disk: str`,
  `stale_days: int`, `packages: tuple[str, ...]` (sorted, deduped),
  `provision: str | None`, `dedicated: bool`, `under: tuple[str, ...]`
  (names of scalars a host override pushed below the repo's declared value).

---

## Task 1: Parse the `[vm]` cascade in `lib/config.py`

**Files:**
- Modify: `src/vergil_tooling/lib/config.py`
- Test: `tests/vergil_tooling/test_config.py`

- [ ] **Step 1: Write the failing test for a flat `[vm]` stanza**

Add to `tests/vergil_tooling/test_config.py`:

```python
from vergil_tooling.lib.config import VmStanza, parse_vm_stanza


class TestParseVmStanza:
    def test_absent_vm_section_returns_none(self) -> None:
        assert parse_vm_stanza({}) is None

    def test_flat_vm_packages_and_footprint(self) -> None:
        raw = {
            "vm": {
                "packages": ["qemu-system-x86", "libvirt-clients"],
                "provision": ".vergil/provision.sh",
            }
        }
        stanza = parse_vm_stanza(raw)
        assert isinstance(stanza, VmStanza)
        assert stanza.packages == ["qemu-system-x86", "libvirt-clients"]
        assert stanza.provision == ".vergil/provision.sh"
        assert stanza.cpus is None
        assert stanza.roles == {}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_config.py::TestParseVmStanza -v`
Expected: FAIL — `ImportError: cannot import name 'VmStanza'`.

- [ ] **Step 3: Add the `VmStanza`/`RoleOverlay` dataclasses and a parser**

In `src/vergil_tooling/lib/config.py`, after the existing dataclasses, add:

```python
@dataclass
class RoleOverlay:
    packages: list[str]
    cpus: int | None
    memory: str | None
    disk: str | None
    stale_days: int | None
    provision: str | None


@dataclass
class VmStanza:
    packages: list[str]
    cpus: int | None
    memory: str | None
    disk: str | None
    stale_days: int | None
    provision: str | None
    roles: dict[str, RoleOverlay]


_VM_SCALAR_KEYS = frozenset({"cpus", "memory", "disk", "stale_days", "provision", "packages"})


def _parse_role_overlay(name: str, raw: dict[str, Any]) -> RoleOverlay:
    for key in raw:
        if key not in _VM_SCALAR_KEYS:
            print(f"{CONFIG_FILE}: unrecognized key '{key}' in [vm.{name}]", file=sys.stderr)
    return RoleOverlay(
        packages=list(raw.get("packages", [])),
        cpus=raw.get("cpus"),
        memory=raw.get("memory"),
        disk=raw.get("disk"),
        stale_days=raw.get("stale_days"),
        provision=raw.get("provision"),
    )


def parse_vm_stanza(raw: dict[str, Any]) -> VmStanza | None:
    """Parse the repo `[vm]` cascade. Returns None when no `[vm]` section exists."""
    vm_raw = raw.get("vm")
    if vm_raw is None:
        return None
    roles: dict[str, RoleOverlay] = {}
    scalars: dict[str, Any] = {}
    for key, value in vm_raw.items():
        if isinstance(value, dict):
            roles[key] = _parse_role_overlay(key, value)
        elif key in _VM_SCALAR_KEYS:
            scalars[key] = value
        else:
            print(f"{CONFIG_FILE}: unrecognized key '{key}' in [vm]", file=sys.stderr)
    return VmStanza(
        packages=list(scalars.get("packages", [])),
        cpus=scalars.get("cpus"),
        memory=scalars.get("memory"),
        disk=scalars.get("disk"),
        stale_days=scalars.get("stale_days"),
        provision=scalars.get("provision"),
        roles=roles,
    )
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_config.py::TestParseVmStanza -v`
Expected: PASS.

- [ ] **Step 5: Write the failing test for the role cascade**

Add to `TestParseVmStanza`:

```python
    def test_role_overlay_parsed(self) -> None:
        raw = {
            "vm": {
                "packages": ["qemu-system-x86"],
                "vergil-user": {"cpus": 12, "memory": "64GiB", "stale_days": 7},
            }
        }
        stanza = parse_vm_stanza(raw)
        assert stanza is not None
        assert stanza.packages == ["qemu-system-x86"]
        assert "vergil-user" in stanza.roles
        overlay = stanza.roles["vergil-user"]
        assert overlay.cpus == 12
        assert overlay.memory == "64GiB"
        assert overlay.stale_days == 7
        assert overlay.packages == []
```

- [ ] **Step 6: Run it to confirm it passes (parser already handles it)**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_config.py::TestParseVmStanza -v`
Expected: PASS (the Step-3 parser already routes dict values to `roles`).

- [ ] **Step 7: Teach the section/key allow-list about `[vm]`**

The existing `_warn_unrecognized_keys` would print `unrecognized section [vm]`. Update the
allow-list constants in `src/vergil_tooling/lib/config.py`:

Change:

```python
_KNOWN_SECTIONS = frozenset(
    {"project", "dependencies", "markdownlint", "ci", "publish", "container"},
)
```

to:

```python
_KNOWN_SECTIONS = frozenset(
    {"project", "dependencies", "markdownlint", "ci", "publish", "container", "vm"},
)
```

The `[vm]` section's keys are validated by `parse_vm_stanza` (which prints its own
per-key warnings, including for `[vm.<role>]` subtables), so add `vm` to the
allow-list but do **not** add it to `_KNOWN_KEYS` — instead make `_warn_unrecognized_keys`
skip per-key checks for `vm`. Locate this loop body in `_warn_unrecognized_keys`:

```python
        known = _KNOWN_KEYS.get(section, frozenset())
        for key in raw[section]:
            if key not in known:
```

and guard it:

```python
        if section == "vm":
            continue  # [vm] keys (incl. [vm.<role>] subtables) are validated in parse_vm_stanza
        known = _KNOWN_KEYS.get(section, frozenset())
        for key in raw[section]:
            if key not in known:
```

- [ ] **Step 8: Write the failing test proving `[vm]` produces no spurious warning**

Add to `tests/vergil_tooling/test_config.py`:

```python
    def test_vm_section_not_flagged_unrecognized(self, capsys) -> None:
        from vergil_tooling.lib.config import _warn_unrecognized_keys

        _warn_unrecognized_keys({"vm": {"packages": [], "vergil-user": {"cpus": 4}}})
        err = capsys.readouterr().err
        assert "unrecognized section [vm]" not in err
        assert "unrecognized key" not in err
```

- [ ] **Step 9: Run the full config test module**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_config.py -v`
Expected: PASS (all, including pre-existing tests).

- [ ] **Step 10: Commit**

```bash
vrg-git add src/vergil_tooling/lib/config.py tests/vergil_tooling/test_config.py
vrg-commit --type feat --scope config \
  --message "parse repo [vm] cascade in vergil.toml (vergil-vm#99)" \
  --body "Add VmStanza/RoleOverlay and parse_vm_stanza for the [vm] + [vm.<role>] cascade; allow the [vm] section in the config allow-list with key validation delegated to the stanza parser."
```

---

## Task 2: Parse nested host-override tables in `lib/identity.py`

**Files:**
- Modify: `src/vergil_tooling/lib/identity.py`
- Test: `tests/vergil_tooling/test_identity.py`

The host override is `[identities.<id>.<org>.<repo>]` with optional `cpus`/`memory`/
`disk`/`stale_days`. In TOML this appears as nested dict values *inside* an identity's
table, alongside scalar identity fields. We collect them into
`Identity.overrides: dict[tuple[str, str], dict[str, Any]]` keyed by `(org, repo)`.

- [ ] **Step 1: Write the failing test**

Add to `tests/vergil_tooling/test_identity.py`:

```python
def test_identity_parses_host_overrides(tmp_path) -> None:
    from vergil_tooling.lib.identity import load_config

    cfg = tmp_path / "identities.toml"
    cfg.write_text(
        """
default_identity = "vergil-user"

[identities.vergil-user]
vm_instance = "vergil-user"

[identities.vergil-user."logical-minds-foundry"."mq-cluster-tooling"]
memory = "32GiB"
""",
        encoding="utf-8",
    )
    config = load_config(cfg)
    ident = config.identities["vergil-user"]
    assert ident.overrides[("logical-minds-foundry", "mq-cluster-tooling")] == {
        "memory": "32GiB"
    }
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_identity.py::test_identity_parses_host_overrides -v`
Expected: FAIL — `AttributeError: 'Identity' object has no attribute 'overrides'` (or a
parse error, since nested tables currently land in `data` and are passed to fields).

- [ ] **Step 3: Add the `overrides` field and parse nested tables**

In `src/vergil_tooling/lib/identity.py`, add to the `Identity` dataclass (after `disk`):

```python
    overrides: dict[tuple[str, str], dict[str, object]] = field(default_factory=dict)
```

Add the import at the top (the module already imports `dataclass`):

```python
from dataclasses import dataclass, field
```

In `load_config`, where each identity is built from `data`, extract nested
`[org][repo]` tables before constructing the `Identity`. Replace the
`identities[name] = Identity(...)` construction block with:

```python
        overrides: dict[tuple[str, str], dict[str, object]] = {}
        for org_key, org_val in data.items():
            if not isinstance(org_val, dict):
                continue
            for repo_key, repo_val in org_val.items():
                if isinstance(repo_val, dict):
                    overrides[(org_key, repo_key)] = repo_val

        identities[name] = Identity(
            vm_instance=data["vm_instance"],
            auth_type=data.get("auth_type", "app"),
            app_id=str(data.get("app_id", "")),
            private_key_path=data.get("private_key_path", ""),
            claude_token_path=data.get("claude_token_path", ""),
            projects_dir=data.get("projects_dir", ""),
            vergil=data.get("vergil", ""),
            vergil_vm=data.get("vergil-vm", ""),
            model=data.get("model", ""),
            session_stale_days=data.get("session_stale_days"),
            session_archive_days=data.get("session_archive_days"),
            cpus=data.get("cpus"),
            memory=data.get("memory"),
            disk=data.get("disk"),
            overrides=overrides,
        )
```

(The nested `[org][repo]` tables are dicts-of-dicts in `data`; scalar identity fields
like `cpus` are non-dict and are skipped by the `isinstance(org_val, dict)` guard.)

- [ ] **Step 4: Run the test to confirm it passes**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_identity.py::test_identity_parses_host_overrides -v`
Expected: PASS.

- [ ] **Step 5: Run the full identity test module (guard against regressions)**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_identity.py -v`
Expected: PASS (all). Existing identities with no nested tables get `overrides == {}`.

- [ ] **Step 6: Commit**

```bash
vrg-git add src/vergil_tooling/lib/identity.py tests/vergil_tooling/test_identity.py
vrg-commit --type feat --scope identity \
  --message "parse nested host-override tables in identities.toml (vergil-vm#99)" \
  --body "Identity gains an overrides map keyed by (org, repo), populated from nested [identities.<id>.<org>.<repo>] tables; scalar identity fields are unaffected."
```

---

## Task 3: The composition resolver in a new `lib/vm_spec.py`

**Files:**
- Create: `src/vergil_tooling/lib/vm_spec.py`
- Test: `tests/vergil_tooling/test_vm_spec.py`

`compose_vm_spec` overlays the five tiers into a `ComposedSpec`. Inputs are already-parsed
data (no I/O): the identity's base footprint, the repo `VmStanza` (or `None`), the
identity name, and the host override dict (or `None`). Output decides base-vs-dedicated
and flags any scalar an override pushed below the repo's declared value.

- [ ] **Step 1: Write the failing test for the empty case (→ base)**

Create `tests/vergil_tooling/test_vm_spec.py`:

```python
"""Tests for vergil_tooling.lib.vm_spec."""

from __future__ import annotations

from vergil_tooling.lib.config import RoleOverlay, VmStanza
from vergil_tooling.lib.vm_spec import ComposedSpec, compose_vm_spec

BASE = {"cpus": 4, "memory": "4GiB", "disk": "50GiB"}


class TestComposeVmSpec:
    def test_no_stanza_no_override_is_base(self) -> None:
        spec = compose_vm_spec(
            identity="vergil-user", base=BASE, stanza=None, override=None
        )
        assert isinstance(spec, ComposedSpec)
        assert spec.dedicated is False
        assert spec.cpus == 4
        assert spec.memory == "4GiB"
        assert spec.packages == ()
        assert spec.under == ()
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vm_spec.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'vergil_tooling.lib.vm_spec'`.

- [ ] **Step 3: Implement `ComposedSpec` and `compose_vm_spec`**

Create `src/vergil_tooling/lib/vm_spec.py`:

```python
"""Compose, name, and fingerprint per-repo VM specs (pure logic, no I/O)."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from vergil_tooling.lib.config import VmStanza

_DEFAULT_STALE_DAYS = 3

# Memory/disk are "<N>GiB" strings; compare by the integer prefix.
def _gib(value: str | None) -> int | None:
    if value is None:
        return None
    return int(value.removesuffix("GiB"))


@dataclass
class ComposedSpec:
    cpus: int
    memory: str
    disk: str
    stale_days: int
    packages: tuple[str, ...]
    provision: str | None
    dedicated: bool
    under: tuple[str, ...]


def compose_vm_spec(
    *,
    identity: str,
    base: dict[str, object],
    stanza: VmStanza | None,
    override: dict[str, object] | None,
) -> ComposedSpec:
    """Overlay the five precedence tiers into the effective spec for one (identity, repo)."""
    # Tier 1+2: built-in/base footprint from the identity.
    cpus = int(base["cpus"])
    memory = str(base["memory"])
    disk = str(base["disk"])
    stale_days = _DEFAULT_STALE_DAYS
    provision: str | None = None
    packages: list[str] = []

    customized = False

    # Tier 3: repo [vm] (all-identity).
    if stanza is not None:
        if stanza.packages:
            packages.extend(stanza.packages)
            customized = True
        for attr in ("cpus", "memory", "disk", "stale_days", "provision"):
            val = getattr(stanza, attr)
            if val is not None:
                customized = True
        cpus = stanza.cpus if stanza.cpus is not None else cpus
        memory = stanza.memory if stanza.memory is not None else memory
        disk = stanza.disk if stanza.disk is not None else disk
        stale_days = stanza.stale_days if stanza.stale_days is not None else stale_days
        provision = stanza.provision if stanza.provision is not None else provision

        # Tier 4: repo [vm.<identity>] role overlay.
        role = stanza.roles.get(identity)
        if role is not None:
            customized = True
            packages.extend(role.packages)
            cpus = role.cpus if role.cpus is not None else cpus
            memory = role.memory if role.memory is not None else memory
            disk = role.disk if role.disk is not None else disk
            stale_days = role.stale_days if role.stale_days is not None else stale_days
            provision = role.provision if role.provision is not None else provision

    # Record the repo-declared footprint (tiers 3+4) before the host override,
    # so we can flag a below-declared override.
    declared_cpus, declared_mem, declared_disk = cpus, _gib(memory), _gib(disk)

    # Tier 5: host override (wins).
    under: list[str] = []
    if override:
        customized = True
        if "cpus" in override:
            cpus = int(override["cpus"])  # type: ignore[arg-type]
            if cpus < declared_cpus:
                under.append("cpus")
        if "memory" in override:
            memory = str(override["memory"])
            if declared_mem is not None and _gib(memory) < declared_mem:
                under.append("mem")
        if "disk" in override:
            disk = str(override["disk"])
            if declared_disk is not None and _gib(disk) < declared_disk:
                under.append("disk")
        if "stale_days" in override:
            stale_days = int(override["stale_days"])  # type: ignore[arg-type]

    return ComposedSpec(
        cpus=cpus,
        memory=memory,
        disk=disk,
        stale_days=stale_days,
        packages=tuple(sorted(set(packages))),
        provision=provision,
        dedicated=customized,
        under=tuple(under),
    )
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vm_spec.py -v`
Expected: PASS.

- [ ] **Step 5: Write the failing tests for dedicated, audit-packages-only, and override-under**

Add to `TestComposeVmSpec` in `tests/vergil_tooling/test_vm_spec.py`:

```python
    def _mq_stanza(self) -> VmStanza:
        return VmStanza(
            packages=["libvirt-clients", "qemu-system-x86"],
            cpus=None, memory=None, disk=None, stale_days=None, provision=".vergil/provision.sh",
            roles={
                "vergil-user": RoleOverlay(
                    packages=[], cpus=12, memory="64GiB", disk="300GiB",
                    stale_days=7, provision=None,
                ),
            },
        )

    def test_user_gets_tuned_dedicated_box(self) -> None:
        spec = compose_vm_spec(
            identity="vergil-user", base=BASE, stanza=self._mq_stanza(), override=None
        )
        assert spec.dedicated is True
        assert spec.cpus == 12
        assert spec.memory == "64GiB"
        assert spec.disk == "300GiB"
        assert spec.stale_days == 7
        assert spec.packages == ("libvirt-clients", "qemu-system-x86")
        assert spec.provision == ".vergil/provision.sh"
        assert spec.under == ()

    def test_audit_gets_packages_only_at_base_footprint(self) -> None:
        spec = compose_vm_spec(
            identity="vergil-audit", base=BASE, stanza=self._mq_stanza(), override=None
        )
        assert spec.dedicated is True          # packages customize it
        assert spec.cpus == 4 and spec.memory == "4GiB"   # base footprint
        assert spec.packages == ("libvirt-clients", "qemu-system-x86")
        assert spec.stale_days == 3            # role overlay didn't apply

    def test_host_override_below_declared_flags_under(self) -> None:
        spec = compose_vm_spec(
            identity="vergil-user", base=BASE, stanza=self._mq_stanza(),
            override={"memory": "32GiB"},
        )
        assert spec.dedicated is True
        assert spec.memory == "32GiB"          # override wins
        assert spec.under == ("mem",)          # but flagged: 32 < declared 64
```

- [ ] **Step 6: Run them to confirm they pass**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vm_spec.py::TestComposeVmSpec -v`
Expected: PASS (all four).

- [ ] **Step 7: Commit**

```bash
vrg-git add src/vergil_tooling/lib/vm_spec.py tests/vergil_tooling/test_vm_spec.py
vrg-commit --type feat --scope vm \
  --message "add compose_vm_spec five-tier overlay (vergil-vm#99)" \
  --body "ComposedSpec + compose_vm_spec: base -> repo [vm] -> [vm.<role>] -> host override; packages union, scalars last-wins; flags scalars an override pushed below the repo-declared value; decides base vs dedicated by whether any tier customized the box."
```

---

## Task 4: Reversible instance-name codec

**Files:**
- Modify: `src/vergil_tooling/lib/vm_spec.py`
- Test: `tests/vergil_tooling/test_vm_spec.py`

`--` separates the three tiers; single dashes live inside identity/org/repo names.

- [ ] **Step 1: Write the failing tests**

Add to `tests/vergil_tooling/test_vm_spec.py`:

```python
from vergil_tooling.lib.vm_spec import instance_name, parse_instance_name


class TestInstanceName:
    def test_base_is_bare_identity(self) -> None:
        assert instance_name("vergil-user", None, None) == "vergil-user"

    def test_dedicated_is_double_dash_joined(self) -> None:
        assert (
            instance_name("vergil-user", "logical-minds-foundry", "mq-cluster-tooling")
            == "vergil-user--logical-minds-foundry--mq-cluster-tooling"
        )

    def test_roundtrip_dedicated(self) -> None:
        name = "vergil-user--logical-minds-foundry--mq-cluster-tooling"
        assert parse_instance_name(name) == (
            "vergil-user", "logical-minds-foundry", "mq-cluster-tooling"
        )

    def test_roundtrip_base(self) -> None:
        assert parse_instance_name("vergil-user") == ("vergil-user", None, None)
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vm_spec.py::TestInstanceName -v`
Expected: FAIL — `ImportError: cannot import name 'instance_name'`.

- [ ] **Step 3: Implement the codec**

Append to `src/vergil_tooling/lib/vm_spec.py`:

```python
_TIER_SEP = "--"


def instance_name(identity: str, org: str | None, repo: str | None) -> str:
    """Derive the Lima instance name. Bare identity = base box; `--`-joined = dedicated."""
    if org is None or repo is None:
        return identity
    return _TIER_SEP.join((identity, org, repo))


def parse_instance_name(name: str) -> tuple[str, str | None, str | None]:
    """Reverse instance_name. Returns (identity, org, repo); org/repo are None for base."""
    parts = name.split(_TIER_SEP)
    if len(parts) == 1:
        return parts[0], None, None
    if len(parts) == 3:
        return parts[0], parts[1], parts[2]
    msg = f"unparseable VM instance name: {name!r}"
    raise ValueError(msg)
```

- [ ] **Step 4: Run them to confirm they pass**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vm_spec.py::TestInstanceName -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
vrg-git add src/vergil_tooling/lib/vm_spec.py tests/vergil_tooling/test_vm_spec.py
vrg-commit --type feat --scope vm \
  --message "add reversible -- instance-name codec (vergil-vm#99)" \
  --body "instance_name/parse_instance_name use -- as the tier delimiter so identity/org/repo round-trip exactly; bare identity denotes the base box."
```

---

## Task 5: Spec fingerprint

**Files:**
- Modify: `src/vergil_tooling/lib/vm_spec.py`
- Test: `tests/vergil_tooling/test_vm_spec.py`

The fingerprint covers the *declaration* — footprint + sorted package set + provision-hook
identity + stale_days — not the resulting image bytes. It must be stable and
order-independent for packages.

- [ ] **Step 1: Write the failing tests**

Add to `tests/vergil_tooling/test_vm_spec.py`:

```python
from vergil_tooling.lib.vm_spec import spec_fingerprint


class TestFingerprint:
    def _spec(self, **over) -> ComposedSpec:
        base = dict(
            cpus=12, memory="64GiB", disk="300GiB", stale_days=7,
            packages=("a", "b"), provision=".vergil/provision.sh",
            dedicated=True, under=(),
        )
        base.update(over)
        return ComposedSpec(**base)

    def test_stable_for_same_declaration(self) -> None:
        assert spec_fingerprint(self._spec()) == spec_fingerprint(self._spec())

    def test_package_order_does_not_matter(self) -> None:
        assert spec_fingerprint(self._spec(packages=("a", "b"))) == spec_fingerprint(
            self._spec(packages=("b", "a"))
        )

    def test_footprint_change_changes_fingerprint(self) -> None:
        assert spec_fingerprint(self._spec(memory="64GiB")) != spec_fingerprint(
            self._spec(memory="32GiB")
        )

    def test_package_addition_changes_fingerprint(self) -> None:
        assert spec_fingerprint(self._spec(packages=("a",))) != spec_fingerprint(
            self._spec(packages=("a", "b"))
        )
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vm_spec.py::TestFingerprint -v`
Expected: FAIL — `ImportError: cannot import name 'spec_fingerprint'`.

- [ ] **Step 3: Implement the fingerprint**

Append to `src/vergil_tooling/lib/vm_spec.py`:

```python
def spec_fingerprint(spec: ComposedSpec) -> str:
    """Stable SHA-256 over the declaration (NOT the resulting image bytes).

    `under` and `dedicated` are excluded: they are derived view-state, not part of
    what the VM is built from. Packages are sorted so order cannot change the hash.
    """
    payload = "\n".join(
        (
            f"cpus={spec.cpus}",
            f"memory={spec.memory}",
            f"disk={spec.disk}",
            f"stale_days={spec.stale_days}",
            f"provision={spec.provision or ''}",
            "packages=" + ",".join(sorted(spec.packages)),
        )
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()
```

- [ ] **Step 4: Run them to confirm they pass**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vm_spec.py::TestFingerprint -v`
Expected: PASS.

- [ ] **Step 5: Run the whole new test module**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vm_spec.py -v`
Expected: PASS (all classes).

- [ ] **Step 6: Commit**

```bash
vrg-git add src/vergil_tooling/lib/vm_spec.py tests/vergil_tooling/test_vm_spec.py
vrg-commit --type feat --scope vm \
  --message "add composed-spec fingerprint (vergil-vm#99)" \
  --body "spec_fingerprint hashes the declaration (footprint + sorted package set + provision + stale_days), excluding derived under/dedicated state; order-independent for packages. Drives the rebuild/drift gate in later plans."
```

---

## Task 6: Identity-key normalization (docs)

**Files:**
- Modify: `docs/site/docs/guides/account-setup.md`

The shipped guide uses bare-role keys (`[identities.user]`). Normalize the *keys* to
`vergil-<role>`; the `vm_instance` values and the GitHub App names are unchanged.

- [ ] **Step 1: Update the identities.toml example keys**

In `docs/site/docs/guides/account-setup.md`, change the dual-stanza example. Replace:

```toml
[identities.user]
vm_instance = "vergil-user"
```

with:

```toml
[identities.vergil-user]
vm_instance = "vergil-user"
```

and replace:

```toml
[identities.audit]
vm_instance = "vergil-audit"
```

with:

```toml
[identities.vergil-audit]
vm_instance = "vergil-audit"
```

- [ ] **Step 2: Update any `default_identity` and prose references**

In the same file, ensure `default_identity` (if present) reads `vergil-user`, and update
prose that names the keys `user`/`audit` to `vergil-user`/`vergil-audit`. Search:

Run: `vrg-container-run -- grep -n "identities.user\|identities.audit\|default_identity\|\"user\"\|\"audit\"" docs/site/docs/guides/account-setup.md`
Fix each key reference to the `vergil-<role>` form. Leave App names
(`<username>-vergil-<role>`) and `vm_instance` values unchanged.

- [ ] **Step 3: Validate docs build / markdown lint**

Run: `vrg-container-run -- vrg-validate`
Expected: PASS (markdownlint and any docs checks clean).

- [ ] **Step 4: Commit**

```bash
vrg-git add docs/site/docs/guides/account-setup.md
vrg-commit --type docs --scope account-setup \
  --message "normalize identities.toml keys to vergil-<role> (vergil-vm#99)" \
  --body "Identity keys become vergil-user/vergil-audit so the key equals the vm_instance base. App credential names (<username>-vergil-<role>) and vm_instance values are unchanged."
```

---

## Task 7: Full validation gate

- [ ] **Step 1: Run the complete validation suite**

Run: `vrg-container-run -- vrg-validate`
Expected: PASS — full lint + type-check + the entire pytest suite green, including the
new `test_vm_spec.py` and the extended `test_config.py` / `test_identity.py`.

- [ ] **Step 2: Confirm no regressions in pre-existing identity/config behaviour**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_identity.py tests/vergil_tooling/test_config.py -v`
Expected: PASS (all pre-existing tests still green; `overrides` defaults to `{}` for
identities without nested tables).

---

## Done criteria (Plan 1)

- `parse_vm_stanza` reads `[vm]` + `[vm.<role>]` from a repo `vergil.toml` without the
  config parser flagging spurious warnings.
- `Identity.overrides` carries `[identities.<id>.<org>.<repo>]` host overrides.
- `compose_vm_spec` overlays all five tiers, decides base-vs-dedicated, and flags
  below-declared overrides — covered by the empty/dedicated/audit/under tests.
- `instance_name`/`parse_instance_name` round-trip base and dedicated names.
- `spec_fingerprint` is stable, package-order-independent, and sensitive to
  footprint/package changes.
- `account-setup.md` uses `vergil-<role>` identity keys.
- `vrg-validate` is green.

These functions are the API Plan 2 (lima.py / template / CLI) and Plan 3 (list) consume:
`compose_vm_spec`, `instance_name`, `parse_instance_name`, `spec_fingerprint`,
`parse_vm_stanza`, and `Identity.overrides`.
