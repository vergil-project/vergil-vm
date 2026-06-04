# Per-Repo VM Profiles — Plan 2: VM Lifecycle Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Plan 1's pure logic into the real VM lifecycle — provision dedicated VMs with their declared packages, run the repo provision hook, stamp a spec fingerprint into each VM, and teach `vrg-vm`'s commands the optional `<org>/<repo>` positional with the base-vs-dedicated resolution, the drift/abort gate, tunable staleness, and the loud under-provisioning warning.

**Architecture:** The `vergil-vm` `templates/agent.yaml` gains a `param:`-driven provisioning step (packages + hook + fingerprint marker). `vergil-tooling`'s `lib/lima.py` `create_vm` threads those params through `limactl --set=.param.*`, and gains fingerprint read/compare helpers. `bin/vrg_vm.py` gains a single `_resolve_target` helper (using `compose_vm_spec`/`instance_name`/`spec_fingerprint` from Plan 1) that every command routes through; dedicated targets build/validate from the composed spec while the base path stays byte-for-byte unchanged.

**Tech Stack:** Python 3.14, `tomllib`, `hashlib`, `pytest` + `unittest.mock`; Lima 2.0 `param:` templating; Bash provisioning. Validation via `vrg-container-run -- vrg-validate`.

---

## Plan set (this is 2 of 3) — prerequisites

Plan 1 (`2026-06-04-vm-profiles-plan-1-spec-foundation.md`) MUST be complete and merged
(or on the same branch). This plan consumes its frozen API:

- `vergil_tooling.lib.config`: `parse_vm_stanza`, `VmStanza`, `read_config`.
- `vergil_tooling.lib.identity`: `Identity.overrides`.
- `vergil_tooling.lib.vm_spec`: `compose_vm_spec`, `ComposedSpec`, `instance_name`,
  `parse_instance_name`, `spec_fingerprint`.

## Execution context (cross-repo)

- **Tasks 1** edits `vergil-vm` (`templates/agent.yaml` + a structural test) — work in the
  **`vergil-vm` worktree** `.worktrees/issue-99-per-repo-vm-profiles` (where these plans
  live). Commit there with `vrg-commit`.
- **Tasks 2–7** edit `vergil-tooling` — work in the **`vergil-tooling` worktree**
  `.worktrees/vm-profiles` (branch `feature/vm-profiles`, created in Plan 1). Commit
  there with `vrg-commit`.
- Git policy: `vrg-git` for git, `vrg-commit` for commits. Commits reference `vergil-vm#99`.
- **Verification convention (repo policy):** `vrg-container-run -- vrg-validate` is the only
  sanctioned validation command (runs the whole suite). Run it **once per task** as the green
  gate; the per-step run lines describe expected red/green. Do not invoke `pytest`/`ruff`/`ty`
  directly. (vergil-vm tasks: the shell tests run directly, then `vrg-validate` as the gate.)

---

## File structure (Plan 2)

- **Modify** `templates/agent.yaml` *(vergil-vm)* — add a `param:` block
  (`EXTRA_PACKAGES`, `PROVISION_HOOK`, `SPEC_FINGERPRINT`) and a provisioning step that
  writes the fingerprint marker, installs the packages, and runs the hook.
- **Create** `tests/test_vm_profile_template.sh` *(vergil-vm)* — structural assertions on
  the template (param keys present, provisioning step references them, fingerprint path).
- **Create** `tests/test_vm_profile_e2e.sh` *(vergil-vm)* — Task 8 end-to-end CI build test
  (package layered + hook ran + fingerprint marker stamped).
- **Modify** `src/vergil_tooling/lib/lima.py` *(vergil-tooling)* — extend `create_vm`;
  add `read_fingerprint`, `vm_spec_status`.
- **Modify** `src/vergil_tooling/bin/vrg_vm.py` *(vergil-tooling)* — add `_resolve_target`
  and the `Target` dataclass; route `create`/`rebuild`/`session`/`start`/`stop`/`restart`/
  `destroy`/`update` through it; abort gate; staleness; under-warning.
- **Modify** `tests/vergil_tooling/test_lima.py`, `tests/vergil_tooling/test_vrg_vm.py`
  *(vergil-tooling)* — unit tests with mocked `_limactl`/lima functions.

`Target` dataclass (defined in Task 4, referenced after):

- `identity_name: str`, `identity: Identity`, `config: IdentityConfig`
- `org: str | None`, `repo: str | None`
- `spec: ComposedSpec`, `instance: str`, `fingerprint: str`  (`""` for base)

---

## Task 1: Template provisioning — params, packages, hook, fingerprint *(vergil-vm)*

**Files:**
- Modify: `templates/agent.yaml`
- Test: `tests/test_vm_profile_template.sh`

- [ ] **Step 1: Write the failing structural test**

Create `tests/test_vm_profile_template.sh`:

```bash
#!/usr/bin/env bash
# Structural checks for the per-repo VM profile provisioning contract in agent.yaml.
set -euo pipefail
TEMPLATE="$(dirname "$0")/../templates/agent.yaml"
fail() { echo "FAIL: $1" >&2; exit 1; }

grep -q '^param:' "$TEMPLATE" || fail "missing param: block"
for key in EXTRA_PACKAGES PROVISION_HOOK SPEC_FINGERPRINT; do
  grep -q "  $key:" "$TEMPLATE" || fail "missing param default for $key"
done
grep -q '/etc/vergil/vm-spec.fingerprint' "$TEMPLATE" || fail "fingerprint marker not written"
grep -q '{{.Param.EXTRA_PACKAGES}}' "$TEMPLATE" || fail "provisioning does not consume EXTRA_PACKAGES"
grep -q '{{.Param.PROVISION_HOOK}}' "$TEMPLATE" || fail "provisioning does not consume PROVISION_HOOK"
grep -q '{{.Param.SPEC_FINGERPRINT}}' "$TEMPLATE" || fail "provisioning does not consume SPEC_FINGERPRINT"
echo "PASS: vm profile template contract"
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_vm_profile_template.sh`
Expected: `FAIL: missing param: block`.

- [ ] **Step 3: Add the `param:` block**

In `templates/agent.yaml`, after the `disk: "50GiB"` line (the resource block), add:

```yaml

# Per-repo VM profile parameters (issue #99). Overridden at create time by
# vrg-vm via `--set=.param.<KEY>`. Empty defaults keep the base box unchanged.
param:
  EXTRA_PACKAGES: ""          # space-separated apt package list, layered additively
  PROVISION_HOOK: ""          # absolute path (inside the VM) to a repo provision.sh
  SPEC_FINGERPRINT: ""        # composed-spec fingerprint, stamped into the VM
```

- [ ] **Step 4: Add the profile provisioning step**

In `templates/agent.yaml`, add a new `mode: system` provisioning block at the END of the
`provision:` list (after the service-minimization block), so packages/hook layer on top of
the fully built base:

```yaml
# --- Per-repo VM profile layering (issue #99) ------------------------------
# Stamp the spec fingerprint, install the profile's additive apt packages, then
# run the repo's provisioning hook (TOOLING only — never lab/box building). All
# three are no-ops when their param is empty, so the base box is unaffected.
- mode: system
  script: |
    #!/bin/bash
    set -eux -o pipefail
    export DEBIAN_FRONTEND=noninteractive

    mkdir -p /etc/vergil
    printf '%s\n' '{{.Param.SPEC_FINGERPRINT}}' > /etc/vergil/vm-spec.fingerprint

    PKGS="{{.Param.EXTRA_PACKAGES}}"
    if [ -n "$PKGS" ]; then
      apt-get update
      # shellcheck disable=SC2086  # word-splitting the package list is intended
      apt-get install -y --no-install-recommends $PKGS
      apt-get clean
      rm -rf /var/lib/apt/lists/*
    fi

    HOOK="{{.Param.PROVISION_HOOK}}"
    if [ -n "$HOOK" ]; then
      if [ -f "$HOOK" ]; then
        bash "$HOOK"
      else
        echo "ERROR: provision hook not found: $HOOK" >&2
        exit 1
      fi
    fi
```

- [ ] **Step 5: Run the structural test to confirm it passes**

Run: `bash tests/test_vm_profile_template.sh`
Expected: `PASS: vm profile template contract`.

- [ ] **Step 6: Run full validation**

Run: `vrg-container-run -- vrg-validate`
Expected: PASS (yaml lints clean; the new shell test is discovered/clean). If the test
runner needs registration, add `tests/test_vm_profile_template.sh` to the test list the
same way the existing `tests/test_services.sh` is registered (check `tests/run-tests.sh`).

- [ ] **Step 7: Commit** *(in the vergil-vm worktree)*

```bash
vrg-git add templates/agent.yaml tests/test_vm_profile_template.sh
vrg-commit --type feat --scope template \
  --message "layer profile packages, hook, and fingerprint at provision time (#99)" \
  --body "Add a param-driven provisioning step (EXTRA_PACKAGES/PROVISION_HOOK/SPEC_FINGERPRINT): stamp /etc/vergil/vm-spec.fingerprint, install additive apt packages, run the repo provision hook (tooling only). All no-ops when params are empty, so the base box is unchanged."
```

---

## Task 2: `create_vm` threads packages / hook / fingerprint *(vergil-tooling)*

**Files:**
- Modify: `src/vergil_tooling/lib/lima.py`
- Test: `tests/vergil_tooling/test_lima.py`

- [ ] **Step 1: Write the failing test**

Add to `tests/vergil_tooling/test_lima.py`:

```python
class TestCreateVmProfileParams:
    @patch("vergil_tooling.lib.lima._limactl")
    def test_profile_params_passed_via_set(self, mock_limactl: MagicMock, tmp_path: Path) -> None:
        template = tmp_path / "agent.yaml"
        template.write_text("dummy", encoding="utf-8")
        create_vm(
            "vergil-user--org--repo",
            template,
            "/projects",
            cpus=12,
            memory="64GiB",
            disk="300GiB",
            packages=["qemu-system-x86", "libvirt-clients"],
            provision_hook="/projects/org/repo/.vergil/provision.sh",
            fingerprint="abc123",
        )
        args = mock_limactl.call_args[0]
        joined = "\n".join(args)
        assert '--set=.param.EXTRA_PACKAGES = "qemu-system-x86 libvirt-clients"' in args
        assert '--set=.param.PROVISION_HOOK = "/projects/org/repo/.vergil/provision.sh"' in args
        assert '--set=.param.SPEC_FINGERPRINT = "abc123"' in args
        assert '--set=.cpus = 12' in args
        assert "create" in joined

    @patch("vergil_tooling.lib.lima._limactl")
    def test_base_create_adds_no_profile_params(self, mock_limactl: MagicMock, tmp_path: Path) -> None:
        template = tmp_path / "agent.yaml"
        template.write_text("dummy", encoding="utf-8")
        create_vm("vergil-user", template, "/projects")
        args = mock_limactl.call_args[0]
        assert not any("param.EXTRA_PACKAGES" in a for a in args)
        assert not any("param.PROVISION_HOOK" in a for a in args)
        assert not any("param.SPEC_FINGERPRINT" in a for a in args)
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_lima.py::TestCreateVmProfileParams -v`
Expected: FAIL — `create_vm() got an unexpected keyword argument 'packages'`.

- [ ] **Step 3: Extend `create_vm`**

In `src/vergil_tooling/lib/lima.py`, change the `create_vm` signature and footprint block.
Replace the signature:

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
```

with:

```python
def create_vm(
    instance: str,
    template: Path,
    projects_dir: str,
    *,
    cpus: int | None = None,
    memory: str | None = None,
    disk: str | None = None,
    packages: list[str] | None = None,
    provision_hook: str | None = None,
    fingerprint: str | None = None,
) -> None:
```

Then, immediately before `args.append(str(template))`, insert:

```python
    if packages:
        args.append(f'--set=.param.EXTRA_PACKAGES = "{" ".join(packages)}"')
    if provision_hook:
        args.append(f'--set=.param.PROVISION_HOOK = "{provision_hook}"')
    if fingerprint:
        args.append(f'--set=.param.SPEC_FINGERPRINT = "{fingerprint}"')
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_lima.py::TestCreateVmProfileParams -v`
Expected: PASS (both).

- [ ] **Step 5: Run the full lima test module (no regressions)**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_lima.py -v`
Expected: PASS (existing `create_vm` callers pass `packages=None` by default → unchanged args).

- [ ] **Step 6: Commit**

```bash
vrg-git add src/vergil_tooling/lib/lima.py tests/vergil_tooling/test_lima.py
vrg-commit --type feat --scope lima \
  --message "thread profile packages/hook/fingerprint into create_vm (vergil-vm#99)" \
  --body "create_vm gains packages/provision_hook/fingerprint kwargs, passed to the template via --set=.param.*; base creates (params None) emit no extra --set, keeping behaviour unchanged."
```

---

## Task 3: Fingerprint read + drift status *(vergil-tooling)*

**Files:**
- Modify: `src/vergil_tooling/lib/lima.py`
- Test: `tests/vergil_tooling/test_lima.py`

- [ ] **Step 1: Write the failing tests**

Add to `tests/vergil_tooling/test_lima.py`:

```python
from vergil_tooling.lib.lima import read_fingerprint, vm_spec_status


class TestFingerprintHelpers:
    @patch("vergil_tooling.lib.lima.shell_run")
    def test_read_fingerprint_returns_stamped_value(self, mock_shell: MagicMock) -> None:
        mock_shell.return_value = subprocess.CompletedProcess([], 0, stdout="abc123\n", stderr="")
        assert read_fingerprint("vergil-user--org--repo") == "abc123"

    @patch("vergil_tooling.lib.lima.shell_run")
    def test_read_fingerprint_missing_marker_is_none(self, mock_shell: MagicMock) -> None:
        mock_shell.side_effect = subprocess.CalledProcessError(1, "cat")
        assert read_fingerprint("vergil-user") is None

    @patch("vergil_tooling.lib.lima.read_fingerprint")
    def test_vm_spec_status_ok_on_match(self, mock_read: MagicMock) -> None:
        mock_read.return_value = "abc123"
        assert vm_spec_status("inst", "abc123") == "ok"

    @patch("vergil_tooling.lib.lima.read_fingerprint")
    def test_vm_spec_status_needs_rebuild_on_drift(self, mock_read: MagicMock) -> None:
        mock_read.return_value = "old"
        assert vm_spec_status("inst", "new") == "needs-rebuild"
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_lima.py::TestFingerprintHelpers -v`
Expected: FAIL — `ImportError: cannot import name 'read_fingerprint'`.

- [ ] **Step 3: Implement the helpers**

Append to `src/vergil_tooling/lib/lima.py`:

```python
_FINGERPRINT_PATH = "/etc/vergil/vm-spec.fingerprint"


def read_fingerprint(instance: str) -> str | None:
    """Return the spec fingerprint stamped into the VM, or None if absent/unreadable."""
    try:
        result = shell_run(instance, "cat", _FINGERPRINT_PATH)
    except subprocess.CalledProcessError:
        return None
    value = result.stdout.strip()
    return value or None


def vm_spec_status(instance: str, expected_fingerprint: str) -> str:
    """Compare the VM's stamped fingerprint to the freshly composed one.

    Returns 'ok' on match, 'needs-rebuild' on drift (including a missing marker on a
    box that should carry one).
    """
    actual = read_fingerprint(instance)
    return "ok" if actual == expected_fingerprint else "needs-rebuild"
```

- [ ] **Step 4: Run them to confirm they pass**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_lima.py::TestFingerprintHelpers -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
vrg-git add src/vergil_tooling/lib/lima.py tests/vergil_tooling/test_lima.py
vrg-commit --type feat --scope lima \
  --message "add fingerprint read + drift status (vergil-vm#99)" \
  --body "read_fingerprint reads /etc/vergil/vm-spec.fingerprint (None when absent); vm_spec_status compares against the expected composed fingerprint -> ok | needs-rebuild."
```

---

## Task 4: `_resolve_target` — one resolution path for every command *(vergil-tooling)*

**Files:**
- Modify: `src/vergil_tooling/bin/vrg_vm.py`
- Test: `tests/vergil_tooling/test_vrg_vm.py`

- [ ] **Step 1: Write the failing tests**

Add to `tests/vergil_tooling/test_vrg_vm.py` (create the file if absent, with the standard
header `from __future__ import annotations` and imports):

```python
from unittest.mock import MagicMock, patch

from vergil_tooling.bin.vrg_vm import Target, _resolve_target
from vergil_tooling.lib.config import RoleOverlay, VmStanza
from vergil_tooling.lib.identity import Identity, IdentityConfig


def _config_with(identity: Identity, name: str = "vergil-user") -> IdentityConfig:
    return IdentityConfig(identities={name: identity}, default_identity=name)


class TestResolveTarget:
    def _identity(self, **over) -> Identity:
        base = dict(vm_instance="vergil-user", projects_dir="/projects",
                    cpus=4, memory="4GiB", disk="50GiB")
        base.update(over)
        return Identity(**base)

    @patch("vergil_tooling.bin.vrg_vm.read_config")
    def test_no_workspace_is_base(self, mock_read: MagicMock) -> None:
        ident = self._identity()
        args = MagicMock(workspace=None, identity="vergil-user", config=None)
        with patch("vergil_tooling.bin.vrg_vm._resolve",
                   return_value=("vergil-user", ident, _config_with(ident))):
            target = _resolve_target(args)
        assert isinstance(target, Target)
        assert target.org is None and target.repo is None
        assert target.instance == "vergil-user"
        assert target.spec.dedicated is False
        assert target.fingerprint == ""
        mock_read.assert_not_called()

    @patch("vergil_tooling.bin.vrg_vm.read_config")
    def test_spec_repo_is_dedicated(self, mock_read: MagicMock) -> None:
        ident = self._identity()
        stanza = VmStanza(
            packages=["qemu-system-x86"], cpus=None, memory=None, disk=None,
            stale_days=None, provision=".vergil/provision.sh",
            roles={"vergil-user": RoleOverlay(
                packages=[], cpus=12, memory="64GiB", disk="300GiB",
                stale_days=7, provision=None)},
        )
        mock_read.return_value = MagicMock(vm=stanza)  # read_config returns a config exposing .vm
        args = MagicMock(workspace="logical-minds-foundry/mq-cluster-tooling",
                         identity="vergil-user", config=None)
        with patch("vergil_tooling.bin.vrg_vm._resolve",
                   return_value=("vergil-user", ident, _config_with(ident))):
            target = _resolve_target(args)
        assert target.org == "logical-minds-foundry"
        assert target.repo == "mq-cluster-tooling"
        assert target.instance == "vergil-user--logical-minds-foundry--mq-cluster-tooling"
        assert target.spec.dedicated is True
        assert target.spec.cpus == 12
        assert target.fingerprint != ""

    @patch("vergil_tooling.bin.vrg_vm.read_config")
    def test_editing_provision_hook_changes_fingerprint(
        self, mock_read: MagicMock, tmp_path: Path
    ) -> None:
        # Real on-disk hook so _resolve_target hashes its CONTENT; editing it must
        # change the fingerprint (the security checkpoint).
        ident = self._identity(projects_dir=str(tmp_path))
        hook = tmp_path / "org" / "repo" / ".vergil" / "provision.sh"
        hook.parent.mkdir(parents=True)
        stanza = VmStanza(
            packages=["x"], cpus=None, memory=None, disk=None, stale_days=None,
            provision=".vergil/provision.sh",
            roles={"vergil-user": RoleOverlay(
                packages=[], cpus=12, memory="64GiB", disk="300GiB", stale_days=7,
                provision=None)},
        )
        mock_read.return_value = MagicMock(vm=stanza)
        args = MagicMock(workspace="org/repo", identity="vergil-user", config=None)

        def resolve_target():
            with patch("vergil_tooling.bin.vrg_vm._resolve",
                       return_value=("vergil-user", ident, _config_with(ident))):
                return _resolve_target(args)

        hook.write_text("echo v1\n", encoding="utf-8")
        fp1 = resolve_target().fingerprint
        hook.write_text("echo v2  # edited\n", encoding="utf-8")
        fp2 = resolve_target().fingerprint
        assert fp1 != fp2
```

> Note: `read_config` here returns an object exposing `.vm: VmStanza | None`. Plan 1 Task 1
> added `parse_vm_stanza`; in Task 4 Step 3 we attach its result to the config object (or
> call `parse_vm_stanza` on the raw TOML). The test mocks `read_config` to return a stand-in
> with `.vm`, so the production code MUST read the stanza via `read_config(...).vm`.

- [ ] **Step 2: Run them to confirm they fail**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py::TestResolveTarget -v`
Expected: FAIL — `ImportError: cannot import name 'Target'`.

- [ ] **Step 3: Expose `.vm` on the parsed config, then add `Target` + `_resolve_target`**

First ensure `read_config` surfaces the stanza. In `src/vergil_tooling/lib/config.py`, add a
`vm: VmStanza | None` field to `VergilConfig` and populate it in `_parse_raw_config`:

```python
@dataclass
class VergilConfig:
    project: ProjectConfig
    dependencies: dict[str, str]
    markdownlint: MarkdownlintConfig
    ci: CiConfig
    publish: PublishConfig
    container: ContainerConfig
    vm: "VmStanza | None"
```

and at the end of `_parse_raw_config`, where the `VergilConfig(...)` is constructed, pass
`vm=parse_vm_stanza(raw)`.

> If `read_config` is the public entry (it wraps `_parse_raw_config`), no signature change is
> needed — callers get `.vm` for free. Update any `VergilConfig(...)` construction in existing
> tests to include `vm=None`.

Now in `src/vergil_tooling/bin/vrg_vm.py`, add imports near the top:

```python
from dataclasses import dataclass

from vergil_tooling.lib.config import read_config
from vergil_tooling.lib.vm_spec import (
    ComposedSpec,
    compose_vm_spec,
    instance_name,
    spec_fingerprint,
)
```

Also add `import hashlib` to the stdlib imports and `replace` to the dataclass import
(`from dataclasses import dataclass, replace`).

and add the dataclass + resolver (after `_resolve`):

```python
_BASE_CPUS = 4
_BASE_MEMORY = "4GiB"
_BASE_DISK = "50GiB"


@dataclass
class Target:
    identity_name: str
    identity: Identity
    config: IdentityConfig
    org: str | None
    repo: str | None
    spec: ComposedSpec
    instance: str
    fingerprint: str


def _base_footprint(identity: Identity) -> dict[str, object]:
    return {
        "cpus": identity.cpus if identity.cpus is not None else _BASE_CPUS,
        "memory": identity.memory if identity.memory is not None else _BASE_MEMORY,
        "disk": identity.disk if identity.disk is not None else _BASE_DISK,
    }


def _split_workspace(workspace: str) -> tuple[str, str]:
    parts = workspace.strip("/").split("/")
    if len(parts) != 2:
        print(
            f"ERROR: workspace must be '<org>/<repo>', got {workspace!r}",
            file=sys.stderr,
        )
        raise SystemExit(1)
    return parts[0], parts[1]


def _resolve_target(args: argparse.Namespace) -> Target:
    """Resolve (identity, optional org/repo) to a base or dedicated VM target."""
    name, identity, config = _resolve(args)
    workspace = getattr(args, "workspace", None)
    base = _base_footprint(identity)

    if not workspace:
        spec = compose_vm_spec(identity=name, base=base, stanza=None, override=None)
        return Target(name, identity, config, None, None, spec, identity.vm_instance, "")

    org, repo = _split_workspace(workspace)
    repo_dir = Path(resolve_workspace(workspace, identity.projects_dir))
    stanza = read_config(repo_dir / "vergil.toml").vm
    override = identity.overrides.get((org, repo))
    spec = compose_vm_spec(identity=name, base=base, stanza=stanza, override=override)

    if not spec.dedicated:
        return Target(name, identity, config, org, repo, spec, identity.vm_instance, "")

    # Fold the provision hook's CONTENT hash into the fingerprint, so editing the
    # script (same path) flips NEEDS-REBUILD — the security review checkpoint the spec
    # promises. The hook is source-controlled and normally present; if it is absent at
    # resolve time we fall back to the path (the template enforces presence at build).
    if spec.provision:
        hook_path = repo_dir / spec.provision
        if hook_path.exists():
            digest = hashlib.sha256(hook_path.read_bytes()).hexdigest()
            spec = replace(spec, provision_hash=digest)

    inst = instance_name(name, org, repo)
    return Target(name, identity, config, org, repo, spec, inst, spec_fingerprint(spec))
```

> `read_config` takes the path to a `vergil.toml`; confirm its signature in `lib/config.py`
> and pass the file path accordingly (it may accept a directory or a file — match the
> existing usage in `vrg_repo_profile.py`).

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py::TestResolveTarget -v`
Expected: PASS.

- [ ] **Step 5: Add the `workspace` positional to the relevant subparsers**

In `main()` in `vrg_vm.py`, add an optional positional to `create`, `rebuild`, `destroy`,
`start`, `stop`, `restart`, `update` (session already has `workspace`). For each, add:

```python
    p_create.add_argument(
        "workspace", nargs="?", default=None,
        help="Optional <org>/<repo> to target a dedicated VM (default: the base VM)",
    )
```

(repeat with the matching parser variable for each command).

- [ ] **Step 6: Run the full vrg_vm + config test modules**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py tests/vergil_tooling/test_config.py -v`
Expected: PASS (update any `VergilConfig(...)` in existing tests to include `vm=None`).

- [ ] **Step 7: Commit**

```bash
vrg-git add src/vergil_tooling/bin/vrg_vm.py src/vergil_tooling/lib/config.py tests/vergil_tooling/test_vrg_vm.py tests/vergil_tooling/test_config.py
vrg-commit --type feat --scope vrg-vm \
  --message "add _resolve_target base-vs-dedicated resolution (vergil-vm#99)" \
  --body "Every command routes through _resolve_target: no workspace -> base VM; a spec'd repo -> dedicated instance with composed footprint, packages, provision hook, and fingerprint. Surfaces VmStanza via VergilConfig.vm."
```

---

## Task 5: Wire `create` and `rebuild` to build dedicated VMs *(vergil-tooling)*

**Files:**
- Modify: `src/vergil_tooling/bin/vrg_vm.py`
- Test: `tests/vergil_tooling/test_vrg_vm.py`

- [ ] **Step 1: Write the failing test (dedicated create passes spec through)**

Add to `tests/vergil_tooling/test_vrg_vm.py`:

```python
class TestCreateDedicated:
    @patch("vergil_tooling.bin.vrg_vm.install_tooling")
    @patch("vergil_tooling.bin.vrg_vm.inject_credentials")
    @patch("vergil_tooling.bin.vrg_vm.link_claude_dirs")
    @patch("vergil_tooling.bin.vrg_vm.start_vm")
    @patch("vergil_tooling.bin.vrg_vm.create_vm")
    @patch("vergil_tooling.bin.vrg_vm.fetch_template")
    @patch("vergil_tooling.bin.vrg_vm.vm_status", return_value="")
    def test_dedicated_create_passes_packages_and_fingerprint(
        self, _status, mock_fetch, mock_create, *_mocks, tmp_path: Path
    ) -> None:
        mock_fetch.return_value = tmp_path / "tpl.yaml"
        (tmp_path / "tpl.yaml").write_text("x", encoding="utf-8")
        target = _dedicated_target_fixture()  # helper building a dedicated Target (see below)
        with patch("vergil_tooling.bin.vrg_vm._resolve_target", return_value=target), \
             patch("vergil_tooling.bin.vrg_vm.resolve_vergil_version", return_value="v2.1"), \
             patch("vergil_tooling.bin.vrg_vm.resolve_vm_tag", return_value="v2.1"):
            rc = _cmd_create(MagicMock(workspace="org/repo", identity="vergil-user",
                                       config=None, tag=""))
        assert rc == 0
        kwargs = mock_create.call_args.kwargs
        assert kwargs["packages"] == list(target.spec.packages)
        assert kwargs["fingerprint"] == target.fingerprint
        assert kwargs["cpus"] == target.spec.cpus
```

Add the fixture helper at module top:

```python
def _dedicated_target_fixture() -> Target:
    from vergil_tooling.lib.vm_spec import ComposedSpec
    ident = Identity(vm_instance="vergil-user", projects_dir="/projects",
                     cpus=4, memory="4GiB", disk="50GiB")
    spec = ComposedSpec(cpus=12, memory="64GiB", disk="300GiB", stale_days=7,
                        packages=("libvirt-clients", "qemu-system-x86"),
                        provision=".vergil/provision.sh", dedicated=True, under=())
    return Target("vergil-user", ident, _config_with(ident),
                  "org", "repo", spec,
                  "vergil-user--org--repo", "fp123")
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py::TestCreateDedicated -v`
Expected: FAIL — `_cmd_create` does not pass `packages`/`fingerprint` (it still uses the
identity footprint path).

- [ ] **Step 3: Rewrite `_cmd_create` to branch on the target**

Replace the body of `_cmd_create` in `vrg_vm.py` with:

```python
def _cmd_create(args: argparse.Namespace) -> int:
    target = _resolve_target(args)
    name, identity, config = target.identity_name, target.identity, target.config
    vergil_version = resolve_vergil_version(config, identity)
    tag = args.tag if args.tag else resolve_vm_tag(config, identity)

    status = vm_status(target.instance)
    if status:
        print(
            f"ERROR: VM '{target.instance}' already exists (status: {status})",
            file=sys.stderr,
        )
        return 1

    if not identity.projects_dir:
        print(f"ERROR: identity '{name}' has no projects_dir configured", file=sys.stderr)
        return 1

    print(f"Creating VM '{target.instance}' for identity '{name}'...")
    print(f"  Fetching template ({tag})...")
    template = fetch_template(tag)

    try:
        print(f"  Creating VM with projects mount: {identity.projects_dir}")
        if target.spec.dedicated:
            hook = _provision_hook_path(identity, target) if target.spec.provision else None
            create_vm(
                target.instance, template, identity.projects_dir,
                cpus=target.spec.cpus, memory=target.spec.memory, disk=target.spec.disk,
                packages=list(target.spec.packages),
                provision_hook=hook,
                fingerprint=target.fingerprint,
            )
        else:
            create_vm(
                target.instance, template, identity.projects_dir,
                cpus=identity.cpus, memory=identity.memory, disk=identity.disk,
            )
        print("  Starting VM...")
        start_vm(target.instance)
        print("  Linking Claude config directories...")
        link_claude_dirs(target.instance, Path.home() / ".claude")
        print("Injecting credentials...")
        inject_credentials(target.instance, identity)
        install_tooling(target.instance, vergil_version)
    finally:
        template.unlink(missing_ok=True)

    print(f"\nVM '{target.instance}' is ready.")
    return 0
```

Add the hook-path helper near `_resolve_target`:

```python
def _provision_hook_path(identity: Identity, target: Target) -> str:
    """Absolute path INSIDE the VM to the repo's provision hook."""
    workspace = f"{target.org}/{target.repo}"
    repo_abs = os.path.normpath(resolve_workspace(workspace, identity.projects_dir))
    return os.path.join(repo_abs, target.spec.provision or "")
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py::TestCreateDedicated -v`
Expected: PASS.

- [ ] **Step 5: Apply the same branch to `_cmd_rebuild`**

Mirror the create branch inside `_cmd_rebuild` (it already destroys then recreates). Replace
its `create_vm(...)` call with the same `if target.spec.dedicated: … else: …` block from
Step 3, resolving the target at the top via `target = _resolve_target(args)` and using
`target.instance` throughout instead of `identity.vm_instance`.

- [ ] **Step 6: Write + run a rebuild regression test**

Add a test mirroring `TestCreateDedicated` for `_cmd_rebuild` (patch `delete_vm`,
`vm_status` returns `"Stopped"` so the "exists" guard passes), asserting `create_vm` is
called with `packages`/`fingerprint`. Run:

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py -v`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
vrg-git add src/vergil_tooling/bin/vrg_vm.py tests/vergil_tooling/test_vrg_vm.py
vrg-commit --type feat --scope vrg-vm \
  --message "build dedicated VMs from the composed spec (vergil-vm#99)" \
  --body "create/rebuild branch on target.spec.dedicated: dedicated boxes pass composed footprint + packages + provision hook + fingerprint; the base path is byte-for-byte unchanged."
```

---

## Task 6: Abort gate, staleness, and the under-provisioning warning *(vergil-tooling)*

**Files:**
- Modify: `src/vergil_tooling/bin/vrg_vm.py`
- Test: `tests/vergil_tooling/test_vrg_vm.py`

- [ ] **Step 1: Write the failing tests**

Add to `tests/vergil_tooling/test_vrg_vm.py`:

```python
class TestSessionGate:
    @patch("vergil_tooling.bin.vrg_vm.vm_status", return_value="")
    def test_session_aborts_when_dedicated_vm_missing(self, _status) -> None:
        target = _dedicated_target_fixture()
        with patch("vergil_tooling.bin.vrg_vm._resolve_target", return_value=target):
            rc = _preflight_target(target)
        assert rc == 1  # missing -> abort with create hint

    @patch("vergil_tooling.bin.vrg_vm.vm_spec_status", return_value="needs-rebuild")
    @patch("vergil_tooling.bin.vrg_vm.vm_status", return_value="Running")
    def test_session_aborts_on_drift(self, _status, _spec) -> None:
        target = _dedicated_target_fixture()
        rc = _preflight_target(target)
        assert rc == 1  # drift -> abort with rebuild hint

    @patch("vergil_tooling.bin.vrg_vm.vm_spec_status", return_value="ok")
    @patch("vergil_tooling.bin.vrg_vm.vm_status", return_value="Running")
    def test_session_ok_when_match(self, _status, _spec) -> None:
        target = _dedicated_target_fixture()
        assert _preflight_target(target) == 0

    def test_under_warning_emitted(self, capsys) -> None:
        from vergil_tooling.lib.vm_spec import ComposedSpec
        ident = Identity(vm_instance="vergil-user", projects_dir="/projects",
                         cpus=4, memory="4GiB", disk="50GiB")
        spec = ComposedSpec(cpus=12, memory="32GiB", disk="300GiB", stale_days=7,
                            packages=(), provision=None, dedicated=True, under=("mem",))
        target = Target("vergil-user", ident, _config_with(ident), "org", "repo",
                        spec, "vergil-user--org--repo", "fp")
        _warn_under(target)
        assert "probably will not work" in capsys.readouterr().err.lower() or \
               "under" in capsys.readouterr().err.lower()
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py::TestSessionGate -v`
Expected: FAIL — `ImportError: cannot import name '_preflight_target'`.

- [ ] **Step 3: Implement `_preflight_target` and `_warn_under`**

Add to `vrg_vm.py` (import `vm_spec_status` from `lib.lima`):

```python
from vergil_tooling.lib.lima import vm_spec_status  # add to the existing lima import block


def _warn_under(target: Target) -> None:
    """Loudly warn when a host override sized a scalar below the repo's declared value."""
    if not target.spec.under:
        return
    fields = ", ".join(target.spec.under)
    print(
        f"WARNING: VM '{target.instance}' is under-provisioned for "
        f"{target.org}/{target.repo} (below declared: {fields}). "
        f"This probably will not work — the repo asked for more than this box has.",
        file=sys.stderr,
    )


def _preflight_target(target: Target) -> int:
    """Validate a dedicated target before session/start. Base targets always pass.

    Returns 0 to proceed, 1 to abort (after printing the remediation command).
    """
    if not target.spec.dedicated:
        return 0

    status = vm_status(target.instance)
    workspace = f"{target.org}/{target.repo}"
    if not status:
        print(
            f"ERROR: VM '{target.instance}' does not exist — this repo requires a "
            f"dedicated VM.\nBuild it: vrg-vm create {workspace} --identity {target.identity_name}",
            file=sys.stderr,
        )
        return 1
    if vm_spec_status(target.instance, target.fingerprint) == "needs-rebuild":
        print(
            f"ERROR: VM '{target.instance}' no longer meets {workspace}'s spec.\n"
            f"Rebuild it: vrg-vm rebuild {workspace} --identity {target.identity_name}",
            file=sys.stderr,
        )
        return 1
    _warn_under(target)
    return 0
```

- [ ] **Step 4: Run them to confirm they pass**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py::TestSessionGate -v`
Expected: PASS.

- [ ] **Step 5: Call the gate from `_cmd_session` and `_cmd_start`**

In `_cmd_session`, replace the opening `name, identity, config = _resolve(args)` with
`target = _resolve_target(args)` and, before the existing staleness check, add:

```python
    if _preflight_target(target) != 0:
        return 1
```

Then use `target.instance`/`target.identity`/`target.identity_name`/`target.config`
throughout the rest of the function in place of the old locals (the resolver returns all of
them). Use `target.spec.stale_days` as the staleness threshold instead of the hard-coded
`_DEFAULT_STALENESS_DAYS` for the VM-age check. Apply the same `target = _resolve_target(args)`
+ `_preflight_target` + `target.spec.stale_days` change in `_cmd_start`.

> The `workspace` positional already exists on `session`; `start` gained it in Task 4 Step 5.

- [ ] **Step 6: Run the full module**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py -v`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
vrg-git add src/vergil_tooling/bin/vrg_vm.py tests/vergil_tooling/test_vrg_vm.py
vrg-commit --type feat --scope vrg-vm \
  --message "add session/start abort gate, tunable staleness, under-warning (vergil-vm#99)" \
  --body "session/start preflight a dedicated target: missing -> abort with create; drift -> abort with rebuild; below-declared host override -> loud warning (sovereign, not blocked). Staleness uses the composed stale_days."
```

---

## Task 7: Lifecycle commands accept the positional *(vergil-tooling)*

**Files:**
- Modify: `src/vergil_tooling/bin/vrg_vm.py`
- Test: `tests/vergil_tooling/test_vrg_vm.py`

- [ ] **Step 1: Write the failing test (destroy targets the dedicated instance)**

```python
class TestLifecyclePositional:
    @patch("vergil_tooling.bin.vrg_vm.delete_vm")
    @patch("vergil_tooling.bin.vrg_vm.vm_status", return_value="Stopped")
    def test_destroy_targets_dedicated_instance(self, _status, mock_delete) -> None:
        target = _dedicated_target_fixture()
        with patch("vergil_tooling.bin.vrg_vm._resolve_target", return_value=target):
            rc = _cmd_destroy(MagicMock(workspace="org/repo", identity="vergil-user", config=None))
        assert rc == 0
        mock_delete.assert_called_once_with("vergil-user--org--repo")
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py::TestLifecyclePositional -v`
Expected: FAIL — `_cmd_destroy` still uses `identity.vm_instance`.

- [ ] **Step 3: Route `destroy`/`stop`/`restart`/`update` through the target**

In each of `_cmd_destroy`, `_cmd_stop`, `_cmd_restart`, `_cmd_update`, replace the opening
`name, identity, _config = _resolve(args)` (or `_resolve`) with
`target = _resolve_target(args)` and use `target.instance` in every `vm_status`/`stop_vm`/
`delete_vm`/`start_vm`/`inject_credentials`/`update_tooling` call, and `target.identity` /
`target.identity_name` / `target.config` where those were used.

- [ ] **Step 4: Run it to confirm it passes**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py::TestLifecyclePositional -v`
Expected: PASS.

- [ ] **Step 5: Full validation gate**

Run: `vrg-container-run -- vrg-validate`
Expected: PASS — full lint + type-check + the entire suite green, including all new tests.

- [ ] **Step 6: Commit**

```bash
vrg-git add src/vergil_tooling/bin/vrg_vm.py tests/vergil_tooling/test_vrg_vm.py
vrg-commit --type feat --scope vrg-vm \
  --message "route stop/restart/destroy/update through the resolved target (vergil-vm#99)" \
  --body "All lifecycle commands accept the optional <org>/<repo> positional and act on the resolved base-or-dedicated instance."
```

---

## Task 8: End-to-end profile build (CI integration) *(vergil-vm)*

**Files:**
- Create: `tests/test_vm_profile_e2e.sh` *(vergil-vm)*
- Modify: the CI build-test workflow that already builds a VM and runs `tests/`.

This is the spec's acceptance criterion — *"a tiny test spec with one extra package proves
the layering end-to-end; a second case proves the provision hook runs"* — as an automated,
right-sized CI test (small footprint, one cheap package). It exercises the **template's
param provisioning** directly via `limactl`, so it does not need credentials or the full
`vrg-vm` CLI. Work in the **`vergil-vm` worktree**.

- [ ] **Step 1: Write the integration test (runs against a profile-built VM)**

Create `tests/test_vm_profile_e2e.sh`:

```bash
#!/usr/bin/env bash
# End-to-end: build a tiny profile VM via the template's params and assert that the
# package layered, the provision hook ran, and the fingerprint marker was stamped.
# Usage: tests/test_vm_profile_e2e.sh  (builds + tears down its own throwaway instance)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$HERE/../templates/agent.yaml"
INSTANCE="vergil-profile-e2e"
WORK="$(mktemp -d)"
FP="testfp123"

cleanup() { limactl delete --force "$INSTANCE" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

# A trivial, self-contained provision hook (TOOLING only — here it just drops a sentinel).
mkdir -p "$WORK/.vergil"
cat > "$WORK/.vergil/provision.sh" <<'HOOK'
#!/bin/bash
set -eux
touch /tmp/vergil-hook-ran
HOOK

limactl create --name="$INSTANCE" --tty=false \
  --set='.mounts[0].location = "'"$WORK"'"' \
  --set='.mounts[0].mountPoint = "'"$WORK"'"' \
  --set='.param.EXTRA_PACKAGES = "cowsay"' \
  --set='.param.PROVISION_HOOK = "'"$WORK"'/.vergil/provision.sh"' \
  --set='.param.SPEC_FINGERPRINT = "'"$FP"'"' \
  "$TEMPLATE"
limactl start "$INSTANCE" --tty=false

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. The extra package layered (base image does not ship cowsay).
limactl shell "$INSTANCE" -- bash -lc 'command -v cowsay' >/dev/null \
  || fail "extra package 'cowsay' not installed"
# 2. The provision hook ran.
limactl shell "$INSTANCE" -- test -f /tmp/vergil-hook-ran \
  || fail "provision hook did not run (sentinel missing)"
# 3. The fingerprint marker was stamped with the injected value.
got=$(limactl shell "$INSTANCE" -- cat /etc/vergil/vm-spec.fingerprint | tr -d '[:space:]')
[ "$got" = "$FP" ] || fail "fingerprint marker is '$got', expected '$FP'"

echo "PASS: vm profile end-to-end (package + hook + fingerprint marker)"
```

- [ ] **Step 2: Run it locally (or in CI) to confirm it passes against a real build**

Run: `bash tests/test_vm_profile_e2e.sh`
Expected: `PASS: vm profile end-to-end (package + hook + fingerprint marker)`.
(This builds a real VM — minutes. It is the slow integration guard, run in CI, not per-edit.)

- [ ] **Step 3: Wire it into the CI build-test path**

Find the workflow/script that builds the agent VM and runs the `tests/` suite (the same one
that runs `tests/test_services.sh` against a built instance — see `tests/run-tests.sh` and
`.github/`). Add `tests/test_vm_profile_e2e.sh` so CI runs it. It manages its own throwaway
instance, so it does not depend on the main build instance.

- [ ] **Step 4: Commit** *(in the vergil-vm worktree)*

```bash
vrg-git add tests/test_vm_profile_e2e.sh
vrg-commit --type test --scope template \
  --message "end-to-end profile build: package + hook + fingerprint (#99)" \
  --body "CI integration test builds a tiny profile VM (cowsay + sentinel hook + test fingerprint) via the template params and asserts all three landed in the VM — the spec's end-to-end acceptance criterion, automated and right-sized."
```

## Done criteria (Plan 2)

- A dedicated `create`/`rebuild` provisions the box with its composed footprint, packages,
  provision hook, and a stamped fingerprint; base create/rebuild is unchanged.
- Editing a repo's `provision.sh` (same path) changes the composed fingerprint
  (`_resolve_target` hashes the hook's contents), so `session`/`start` flag `NEEDS-REBUILD`.
- The end-to-end CI test proves a real profile VM gets its package, runs its hook, and is
  stamped with the fingerprint marker.
- `read_fingerprint`/`vm_spec_status` detect drift.
- `session`/`start` abort with the exact `create`/`rebuild` command when a dedicated VM is
  missing or drifted, warn loudly on a below-declared override, and honour composed
  `stale_days`.
- `stop`/`restart`/`destroy`/`update` accept `<org>/<repo>` and act on the right instance.
- `vrg-validate` is green.

API consumed by Plan 3: `Target`, `_resolve_target`, `vm_spec_status`, `read_fingerprint`,
`instance_name`/`parse_instance_name`, `ComposedSpec`.
