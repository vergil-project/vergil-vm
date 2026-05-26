# VM Resource Sizing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-identity VM resource overrides (cpus, memory, disk) in `identities.toml`, validated at config load time and applied during VM creation.

**Architecture:** The Identity dataclass in vergil-tooling gains three optional fields parsed from identities.toml. A validation function catches syntax errors at load time. The `create_vm()` function accepts the overrides and passes them as Lima `--set` flags. The vergil-vm template gets updated defaults (4 GiB memory) and a comment documenting the override mechanism.

**Tech Stack:** Python 3.12+, Lima, TOML, pytest

**Repos:**
- `vergil-tooling` at `/Users/pmoore/dev/projects/vergil-project/vergil-tooling`
- `vergil-vm` at `/Users/pmoore/dev/projects/vergil-project/vergil-vm` (worktree: `.worktrees/issue-34-vm-resource-sizing/`)

---

## File Map

### vergil-tooling

| File | Action | Responsibility |
|------|--------|---------------|
| `src/vergil_tooling/lib/identity.py` | Modify | Add `cpus`, `memory`, `disk` fields to `Identity`, parse in `load_config`, add `_validate_identity_resources` |
| `src/vergil_tooling/lib/lima.py` | Modify | Add `cpus`, `memory`, `disk` kwargs to `create_vm` |
| `src/vergil_tooling/bin/vrg_vm.py` | Modify | Pass identity resource fields through in `_cmd_create` and `_cmd_rebuild` |
| `tests/vergil_tooling/test_identity.py` | Modify | Tests for parsing, defaults, and validation |
| `tests/vergil_tooling/test_lima.py` | Modify | Tests for `create_vm` with resource overrides |
| `tests/vergil_tooling/test_vrg_vm.py` | Modify | Tests for create/rebuild passing overrides through |

### vergil-vm

| File | Action | Responsibility |
|------|--------|---------------|
| `templates/agent.yaml` | Modify | Update memory default to 4 GiB, add resource budget comment |

---

## Task 1: Add resource fields to Identity dataclass and parse them

**Files:**
- Modify: `vergil-tooling/src/vergil_tooling/lib/identity.py:12-19` (Identity dataclass)
- Modify: `vergil-tooling/src/vergil_tooling/lib/identity.py:31-60` (load_config)
- Test: `vergil-tooling/tests/vergil_tooling/test_identity.py`

- [ ] **Step 1: Write tests for parsing resource fields from TOML**

Add to `tests/vergil_tooling/test_identity.py`:

```python
def test_resource_fields_parsed(tmp_path: Path) -> None:
    p = tmp_path / "identities.toml"
    p.write_text(
        textwrap.dedent("""\
        [identities.vergil]
        vm_instance = "vergil-agent"
        cpus = 12
        memory = "32GiB"
        disk = "100GiB"
    """)
    )
    cfg = load_config(p)
    ident = cfg.identities["vergil"]
    assert ident.cpus == 12
    assert ident.memory == "32GiB"
    assert ident.disk == "100GiB"


def test_resource_fields_default_none(config_file: Path) -> None:
    cfg = load_config(config_file)
    ident = cfg.identities["vergil"]
    assert ident.cpus is None
    assert ident.memory is None
    assert ident.disk is None
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/pmoore/dev/projects/vergil-project/vergil-tooling && uv run pytest tests/vergil_tooling/test_identity.py::test_resource_fields_parsed tests/vergil_tooling/test_identity.py::test_resource_fields_default_none -v`

Expected: FAIL — `Identity` has no `cpus`, `memory`, or `disk` attributes.

- [ ] **Step 3: Add resource fields to Identity dataclass and load_config**

In `src/vergil_tooling/lib/identity.py`, add fields to the `Identity` dataclass:

```python
@dataclass
class Identity:
    vm_instance: str
    auth_type: str = "app"
    app_id: str = ""
    private_key_path: str = ""
    claude_token_path: str = ""
    projects_dir: str = ""
    vergil: str = ""
    vergil_vm: str = ""
    cpus: int | None = None
    memory: str | None = None
    disk: str | None = None
```

In `load_config`, add the three fields to the `Identity()` constructor call inside the loop:

```python
        identities[name] = Identity(
            vm_instance=data["vm_instance"],
            auth_type=data.get("auth_type", "app"),
            app_id=str(data.get("app_id", "")),
            private_key_path=data.get("private_key_path", ""),
            claude_token_path=data.get("claude_token_path", ""),
            projects_dir=data.get("projects_dir", ""),
            vergil=data.get("vergil", ""),
            vergil_vm=data.get("vergil-vm", ""),
            cpus=data.get("cpus"),
            memory=data.get("memory"),
            disk=data.get("disk"),
        )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/pmoore/dev/projects/vergil-project/vergil-tooling && uv run pytest tests/vergil_tooling/test_identity.py -v`

Expected: ALL PASS (including existing tests — no regressions).

- [ ] **Step 5: Commit**

```bash
cd /Users/pmoore/dev/projects/vergil-project/vergil-tooling && \
vrg-git add src/vergil_tooling/lib/identity.py tests/vergil_tooling/test_identity.py && \
vrg-git commit -m "feat(identity): add cpus, memory, disk resource fields"
```

---

## Task 2: Add resource validation

**Files:**
- Modify: `vergil-tooling/src/vergil_tooling/lib/identity.py`
- Test: `vergil-tooling/tests/vergil_tooling/test_identity.py`

- [ ] **Step 1: Write tests for validation**

Add to `tests/vergil_tooling/test_identity.py`:

```python
def test_resource_validation_rejects_negative_cpus(tmp_path: Path) -> None:
    p = tmp_path / "identities.toml"
    p.write_text(
        textwrap.dedent("""\
        [identities.vergil]
        vm_instance = "vergil-agent"
        cpus = -1
    """)
    )
    with pytest.raises(SystemExit):
        load_config(p)


def test_resource_validation_rejects_zero_cpus(tmp_path: Path) -> None:
    p = tmp_path / "identities.toml"
    p.write_text(
        textwrap.dedent("""\
        [identities.vergil]
        vm_instance = "vergil-agent"
        cpus = 0
    """)
    )
    with pytest.raises(SystemExit):
        load_config(p)


def test_resource_validation_rejects_string_cpus(tmp_path: Path) -> None:
    p = tmp_path / "identities.toml"
    p.write_text(
        textwrap.dedent("""\
        [identities.vergil]
        vm_instance = "vergil-agent"
        cpus = "four"
    """)
    )
    with pytest.raises(SystemExit):
        load_config(p)


def test_resource_validation_rejects_bad_memory(tmp_path: Path) -> None:
    p = tmp_path / "identities.toml"
    p.write_text(
        textwrap.dedent("""\
        [identities.vergil]
        vm_instance = "vergil-agent"
        memory = "32GB"
    """)
    )
    with pytest.raises(SystemExit):
        load_config(p)


def test_resource_validation_rejects_bad_disk(tmp_path: Path) -> None:
    p = tmp_path / "identities.toml"
    p.write_text(
        textwrap.dedent("""\
        [identities.vergil]
        vm_instance = "vergil-agent"
        disk = "lots"
    """)
    )
    with pytest.raises(SystemExit):
        load_config(p)


def test_resource_validation_accepts_valid_values(tmp_path: Path) -> None:
    p = tmp_path / "identities.toml"
    p.write_text(
        textwrap.dedent("""\
        [identities.vergil]
        vm_instance = "vergil-agent"
        cpus = 12
        memory = "32GiB"
        disk = "100GiB"
    """)
    )
    cfg = load_config(p)
    assert cfg.identities["vergil"].cpus == 12


def test_resource_validation_error_message(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    p = tmp_path / "identities.toml"
    p.write_text(
        textwrap.dedent("""\
        [identities.vergil]
        vm_instance = "vergil-agent"
        memory = "32GB"
    """)
    )
    with pytest.raises(SystemExit):
        load_config(p)
    captured = capsys.readouterr()
    assert "vergil" in captured.err
    assert "memory" in captured.err
    assert "<number>GiB" in captured.err
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/pmoore/dev/projects/vergil-project/vergil-tooling && uv run pytest tests/vergil_tooling/test_identity.py -k "resource_validation" -v`

Expected: FAIL — no validation exists yet, so bad values are silently accepted.

- [ ] **Step 3: Add validation function and call it from load_config**

Add to `src/vergil_tooling/lib/identity.py`, after the imports:

```python
import re

_SIZE_PATTERN = re.compile(r"^\d+GiB$")
```

Add the validation function before `load_config`:

```python
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
                f' (e.g., "32GiB"), got {value!r}',
                file=sys.stderr,
            )
            raise SystemExit(1)
```

Call it in `load_config`, after constructing each Identity, inside the `for name, data in ...` loop:

```python
        identities[name] = Identity(
            # ...existing fields...
        )
        _validate_identity_resources(name, identities[name])
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/pmoore/dev/projects/vergil-project/vergil-tooling && uv run pytest tests/vergil_tooling/test_identity.py -v`

Expected: ALL PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/pmoore/dev/projects/vergil-project/vergil-tooling && \
vrg-git add src/vergil_tooling/lib/identity.py tests/vergil_tooling/test_identity.py && \
vrg-git commit -m "feat(identity): validate cpus, memory, disk syntax at config load"
```

---

## Task 3: Wire resource overrides through create_vm

**Files:**
- Modify: `vergil-tooling/src/vergil_tooling/lib/lima.py:147-154` (create_vm)
- Test: `vergil-tooling/tests/vergil_tooling/test_lima.py`

- [ ] **Step 1: Write tests for create_vm with resource overrides**

Add to `tests/vergil_tooling/test_lima.py`, inside `class TestCreateVm`:

```python
    @patch("vergil_tooling.lib.lima._limactl")
    def test_passes_cpu_override(self, mock: MagicMock) -> None:
        tpl = Path("/tmp/template.yaml")  # noqa: S108
        create_vm("vergil-agent", tpl, "/home/user/projects", cpus=12)
        args = mock.call_args[0]
        cpu_args = [a for a in args if "cpus" in a]
        assert len(cpu_args) == 1
        assert "--set=.cpus = 12" == cpu_args[0]

    @patch("vergil_tooling.lib.lima._limactl")
    def test_passes_memory_override(self, mock: MagicMock) -> None:
        tpl = Path("/tmp/template.yaml")  # noqa: S108
        create_vm("vergil-agent", tpl, "/home/user/projects", memory="32GiB")
        args = mock.call_args[0]
        mem_args = [a for a in args if "memory" in a]
        assert len(mem_args) == 1
        assert '--set=.memory = "32GiB"' == mem_args[0]

    @patch("vergil_tooling.lib.lima._limactl")
    def test_passes_disk_override(self, mock: MagicMock) -> None:
        tpl = Path("/tmp/template.yaml")  # noqa: S108
        create_vm("vergil-agent", tpl, "/home/user/projects", disk="100GiB")
        args = mock.call_args[0]
        disk_args = [a for a in args if "disk" in a]
        assert len(disk_args) == 1
        assert '--set=.disk = "100GiB"' == disk_args[0]

    @patch("vergil_tooling.lib.lima._limactl")
    def test_omits_none_overrides(self, mock: MagicMock) -> None:
        tpl = Path("/tmp/template.yaml")  # noqa: S108
        create_vm("vergil-agent", tpl, "/home/user/projects")
        args = mock.call_args[0]
        assert not any("cpus" in a for a in args)
        assert not any("memory" in a for a in args)
        assert not any("disk" in a for a in args)

    @patch("vergil_tooling.lib.lima._limactl")
    def test_passes_all_overrides(self, mock: MagicMock) -> None:
        tpl = Path("/tmp/template.yaml")  # noqa: S108
        create_vm(
            "vergil-agent", tpl, "/home/user/projects",
            cpus=8, memory="24GiB", disk="100GiB",
        )
        args = mock.call_args[0]
        assert "--set=.cpus = 8" in args
        assert '--set=.memory = "24GiB"' in args
        assert '--set=.disk = "100GiB"' in args
        assert str(tpl) == args[-1]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/pmoore/dev/projects/vergil-project/vergil-tooling && uv run pytest tests/vergil_tooling/test_lima.py::TestCreateVm -v`

Expected: FAIL — `create_vm` does not accept `cpus`, `memory`, or `disk` kwargs.

- [ ] **Step 3: Update create_vm to accept and apply resource overrides**

Replace the `create_vm` function in `src/vergil_tooling/lib/lima.py`:

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

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/pmoore/dev/projects/vergil-project/vergil-tooling && uv run pytest tests/vergil_tooling/test_lima.py -v`

Expected: ALL PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/pmoore/dev/projects/vergil-project/vergil-tooling && \
vrg-git add src/vergil_tooling/lib/lima.py tests/vergil_tooling/test_lima.py && \
vrg-git commit -m "feat(lima): accept resource overrides in create_vm"
```

---

## Task 4: Pass identity resources through vrg-vm create and rebuild

**Files:**
- Modify: `vergil-tooling/src/vergil_tooling/bin/vrg_vm.py:77` (_cmd_create)
- Modify: `vergil-tooling/src/vergil_tooling/bin/vrg_vm.py:229` (_cmd_rebuild)
- Test: `vergil-tooling/tests/vergil_tooling/test_vrg_vm.py`

- [ ] **Step 1: Write tests for create and rebuild passing resource overrides**

Add to `tests/vergil_tooling/test_vrg_vm.py`, inside `class TestCreate`:

```python
    @patch("vergil_tooling.bin.vrg_vm.install_tooling")
    @patch("vergil_tooling.bin.vrg_vm.inject_credentials")
    @patch("vergil_tooling.bin.vrg_vm.start_vm")
    @patch("vergil_tooling.bin.vrg_vm.create_vm")
    @patch("vergil_tooling.bin.vrg_vm.fetch_template")
    @patch("vergil_tooling.bin.vrg_vm.vm_status", return_value="")
    def test_create_passes_resource_overrides(
        self,
        _status: MagicMock,
        mock_fetch: MagicMock,
        mock_create: MagicMock,
        _start: MagicMock,
        _inject: MagicMock,
        _install: MagicMock,
        tmp_path: Path,
    ) -> None:
        p = tmp_path / "identities.toml"
        p.write_text(
            textwrap.dedent("""\
            vergil = "v2.0"

            [identities.vergil]
            vm_instance = "vergil-agent"
            projects_dir = "/home/user/projects"
            cpus = 12
            memory = "32GiB"
            disk = "100GiB"
        """)
        )
        template = tmp_path / "template.yaml"
        template.write_text("cpus: 4")
        mock_fetch.return_value = template

        result = main(["create", "--config", str(p)])
        assert result == 0
        mock_create.assert_called_once_with(
            "vergil-agent",
            template,
            "/home/user/projects",
            cpus=12,
            memory="32GiB",
            disk="100GiB",
        )
```

Add inside `class TestRebuild`:

```python
    @patch("vergil_tooling.bin.vrg_vm.copy_claude_config")
    @patch("vergil_tooling.bin.vrg_vm.install_tooling")
    @patch("vergil_tooling.bin.vrg_vm.inject_credentials")
    @patch("vergil_tooling.bin.vrg_vm.start_vm")
    @patch("vergil_tooling.bin.vrg_vm.create_vm")
    @patch("vergil_tooling.bin.vrg_vm.fetch_template")
    @patch("vergil_tooling.bin.vrg_vm.delete_vm")
    @patch("vergil_tooling.bin.vrg_vm.vm_status", return_value="Running")
    def test_rebuild_passes_resource_overrides(
        self,
        _status: MagicMock,
        _delete: MagicMock,
        mock_fetch: MagicMock,
        mock_create: MagicMock,
        _start: MagicMock,
        _inject: MagicMock,
        _install: MagicMock,
        _copy: MagicMock,
        tmp_path: Path,
    ) -> None:
        p = tmp_path / "identities.toml"
        p.write_text(
            textwrap.dedent("""\
            vergil = "v2.0"

            [identities.vergil]
            vm_instance = "vergil-agent"
            projects_dir = "/home/user/projects"
            cpus = 8
            memory = "24GiB"
        """)
        )
        template = tmp_path / "template.yaml"
        template.write_text("cpus: 4")
        mock_fetch.return_value = template

        result = main(["rebuild", "--config", str(p)])
        assert result == 0
        mock_create.assert_called_once_with(
            "vergil-agent",
            template,
            "/home/user/projects",
            cpus=8,
            memory="24GiB",
            disk=None,
        )
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/pmoore/dev/projects/vergil-project/vergil-tooling && uv run pytest tests/vergil_tooling/test_vrg_vm.py::TestCreate::test_create_passes_resource_overrides tests/vergil_tooling/test_vrg_vm.py::TestRebuild::test_rebuild_passes_resource_overrides -v`

Expected: FAIL — `create_vm` called without resource kwargs.

- [ ] **Step 3: Update _cmd_create and _cmd_rebuild to pass resource fields**

In `src/vergil_tooling/bin/vrg_vm.py`, update the `create_vm` call in `_cmd_create` (line ~77):

```python
        create_vm(
            identity.vm_instance,
            template,
            identity.projects_dir,
            cpus=identity.cpus,
            memory=identity.memory,
            disk=identity.disk,
        )
```

Update the `create_vm` call in `_cmd_rebuild` (line ~229):

```python
        create_vm(
            identity.vm_instance,
            template,
            identity.projects_dir,
            cpus=identity.cpus,
            memory=identity.memory,
            disk=identity.disk,
        )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/pmoore/dev/projects/vergil-project/vergil-tooling && uv run pytest tests/vergil_tooling/test_vrg_vm.py -v`

Expected: ALL PASS.

- [ ] **Step 5: Run the full vergil-tooling test suite**

Run: `cd /Users/pmoore/dev/projects/vergil-project/vergil-tooling && vrg-docker-run -- vrg-validate`

Expected: ALL PASS — no regressions across the entire suite.

- [ ] **Step 6: Commit**

```bash
cd /Users/pmoore/dev/projects/vergil-project/vergil-tooling && \
vrg-git add src/vergil_tooling/bin/vrg_vm.py tests/vergil_tooling/test_vrg_vm.py && \
vrg-git commit -m "feat(vm): pass identity resource overrides through create and rebuild"
```

---

## Task 5: Update vergil-vm template defaults

**Files:**
- Modify: `vergil-vm/.worktrees/issue-34-vm-resource-sizing/templates/agent.yaml:23-25`

- [ ] **Step 1: Update template defaults and add comment block**

In `templates/agent.yaml`, replace the resource block (lines 23–25):

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

- [ ] **Step 2: Validate the YAML is syntactically valid**

Run: `cd /Users/pmoore/dev/projects/vergil-project/vergil-vm/.worktrees/issue-34-vm-resource-sizing && python3 -c "import yaml; yaml.safe_load(open('templates/agent.yaml'))"`

Expected: No error output (exits cleanly).

- [ ] **Step 3: Run vergil-vm validation**

Run: `cd /Users/pmoore/dev/projects/vergil-project/vergil-vm/.worktrees/issue-34-vm-resource-sizing && vrg-docker-run -- vrg-validate`

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd /Users/pmoore/dev/projects/vergil-project/vergil-vm/.worktrees/issue-34-vm-resource-sizing && \
vrg-git add templates/agent.yaml && \
vrg-git commit -m "feat(template): update resource defaults and document override mechanism"
```
