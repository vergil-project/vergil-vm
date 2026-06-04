# Per-Repo VM Profiles — Plan 3: Observability & Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `vrg-vm list` into an observability surface — configured footprint, live `AGENTS`/`HUMANS` occupancy (by process-tree classification, not arithmetic), and a per-VM `SPEC` health column (`ok` / `NEEDS-REBUILD` / `not-created` / `orphaned` / `under`) — and close the dedicated-VM lifecycle by surfacing and removing orphans.

**Architecture:** `lib/lima.py` gains `vm_occupancy(instance)` which runs an in-VM classifier (each logind user tty/pty session is an agent if its process subtree roots `claude`, else a human) and returns `(agents, humans)`. `bin/vrg_vm.py` gains `discover_dedicated(...)` (union of `<identity>--*` instances and spec-bearing repos → rows with state) and a rewritten `_cmd_list` rendering the new columns; `destroy` is taught to remove orphan instances by name.

**Tech Stack:** Python 3.14, `pytest` + `unittest.mock`, Bash (in-VM classifier). Validation via `vrg-container-run -- vrg-validate`.

---

## Plan set (this is 3 of 3) — prerequisites

Plans 1 and 2 complete. Consumes their API: `parse_instance_name`, `instance_name`,
`compose_vm_spec`, `ComposedSpec`, `spec_fingerprint`, `vm_spec_status`, `read_config().vm`,
`Identity.overrides`, `Target`/`_resolve_target`.

## Execution context

All of Plan 3 is in **`vergil-tooling`** — work in `.worktrees/vm-profiles` (branch
`feature/vm-profiles`). `vrg-git`/`vrg-commit`; commits reference `vergil-vm#99`.

**Verification convention (repo policy):** `vrg-container-run -- vrg-validate` is the only
sanctioned validation command (runs the whole suite). Run it **once per task** as the green
gate; the per-step run lines describe expected red/green. Do not invoke `pytest` directly.

---

## File structure (Plan 3)

- **Modify** `src/vergil_tooling/lib/lima.py` — add `vm_occupancy`.
- **Modify** `src/vergil_tooling/bin/vrg_vm.py` — add `discover_dedicated`, the
  `DedicatedRow` dataclass, rewrite `_cmd_list`, and the orphan-aware destroy.
- **Modify** `tests/vergil_tooling/test_lima.py`, `tests/vergil_tooling/test_vrg_vm.py`.

`DedicatedRow` (Task 2): `org: str | None`, `repo: str | None`, `instance: str`,
`state: str` (`"present"` | `"orphaned"` | `"not-created"`).

---

## Task 1: `vm_occupancy` — process-tree AGENTS/HUMANS *(vergil-tooling)*

**Files:**
- Modify: `src/vergil_tooling/lib/lima.py`
- Test: `tests/vergil_tooling/test_lima.py`

The Python side runs the classifier in the VM and parses `agents=N humans=M`. The classifier
walks each logind user tty/pty session's process subtree for `claude` — a direct count of
each class, with no "total minus agents" subtraction (per the spec's Finding 2 resolution).

- [ ] **Step 1: Write the failing tests (parsing)**

Add to `tests/vergil_tooling/test_lima.py`:

```python
from vergil_tooling.lib.lima import vm_occupancy


class TestOccupancy:
    @patch("vergil_tooling.lib.lima.shell_run")
    def test_parses_agents_and_humans(self, mock_shell: MagicMock) -> None:
        mock_shell.return_value = subprocess.CompletedProcess([], 0, stdout="agents=2 humans=1\n", stderr="")
        assert vm_occupancy("inst") == (2, 1)

    @patch("vergil_tooling.lib.lima.shell_run")
    def test_zero_when_idle(self, mock_shell: MagicMock) -> None:
        mock_shell.return_value = subprocess.CompletedProcess([], 0, stdout="agents=0 humans=0\n", stderr="")
        assert vm_occupancy("inst") == (0, 0)

    @patch("vergil_tooling.lib.lima.shell_run")
    def test_unparseable_output_is_zeros(self, mock_shell: MagicMock) -> None:
        mock_shell.return_value = subprocess.CompletedProcess([], 0, stdout="garbage\n", stderr="")
        assert vm_occupancy("inst") == (0, 0)
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_lima.py::TestOccupancy -v`
Expected: FAIL — `ImportError: cannot import name 'vm_occupancy'`.

- [ ] **Step 3: Implement `vm_occupancy` + the classifier**

Append to `src/vergil_tooling/lib/lima.py`:

```python
import re as _re

# In-VM classifier: count agent vs human login sessions by walking each logind
# user tty/pty session's process subtree for `claude`. Direct counts, no subtraction.
_OCCUPANCY_SCRIPT = r"""
set -u
has_claude() {
  local pids="$1" p comm next
  while [ -n "$pids" ]; do
    next=""
    for p in $pids; do
      comm=$(cat "/proc/$p/comm" 2>/dev/null || echo "")
      [ "$comm" = "claude" ] && return 0
      next="$next $(pgrep -P "$p" 2>/dev/null || true)"
    done
    pids="$next"
  done
  return 1
}
agents=0; humans=0
for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
  cls=$(loginctl show-session "$s" -p Class --value 2>/dev/null || echo "")
  typ=$(loginctl show-session "$s" -p Type --value 2>/dev/null || echo "")
  [ "$cls" = "user" ] || continue
  case "$typ" in tty|pty) ;; *) continue ;; esac
  leader=$(loginctl show-session "$s" -p Leader --value 2>/dev/null || echo "")
  [ -n "$leader" ] || continue
  if has_claude "$leader"; then agents=$((agents+1)); else humans=$((humans+1)); fi
done
echo "agents=$agents humans=$humans"
"""

_OCCUPANCY_RE = _re.compile(r"agents=(\d+)\s+humans=(\d+)")


def vm_occupancy(instance: str) -> tuple[int, int]:
    """Return (agents, humans) for a running VM by process-tree classification.

    Agents are login sessions whose subtree roots `claude`; humans are interactive
    user tty/pty sessions that are not agent-hosting. Returns (0, 0) on any parse/exec
    failure rather than guessing.
    """
    try:
        result = shell_run(instance, "bash", "-c", _OCCUPANCY_SCRIPT)
    except subprocess.CalledProcessError:
        return (0, 0)
    match = _OCCUPANCY_RE.search(result.stdout)
    if match is None:
        return (0, 0)
    return (int(match.group(1)), int(match.group(2)))
```

> The `import re as _re` goes with the other stdlib imports at the top of `lima.py`; placing
> it inline as shown also works but prefer the top of the module to match house style.

- [ ] **Step 4: Run them to confirm they pass**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_lima.py::TestOccupancy -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
vrg-git add src/vergil_tooling/lib/lima.py tests/vergil_tooling/test_lima.py
vrg-commit --type feat --scope lima \
  --message "add process-tree AGENTS/HUMANS occupancy (vergil-vm#99)" \
  --body "vm_occupancy runs an in-VM classifier that walks each logind user tty/pty session's subtree for claude, counting agent vs human sessions directly (no subtraction); returns (0,0) on failure."
```

---

## Task 2: `discover_dedicated` — instances ∪ spec-bearing repos *(vergil-tooling)*

**Files:**
- Modify: `src/vergil_tooling/bin/vrg_vm.py`
- Test: `tests/vergil_tooling/test_vrg_vm.py`

- [ ] **Step 1: Write the failing tests**

Add to `tests/vergil_tooling/test_vrg_vm.py`:

```python
from vergil_tooling.bin.vrg_vm import DedicatedRow, discover_dedicated


class TestDiscoverDedicated:
    def _repo_with_vm(self, projects: Path, org: str, repo: str) -> None:
        d = projects / org / repo
        d.mkdir(parents=True)
        (d / "vergil.toml").write_text(
            '[project]\nrepository-type = "tooling"\nversioning-scheme = "semver"\n'
            'branching-model = "library-release"\nrelease-model = "tagged-release"\n'
            '[vm]\npackages = ["qemu-system-x86"]\n',
            encoding="utf-8",
        )

    def test_present_orphan_and_not_created(self, tmp_path: Path) -> None:
        self._repo_with_vm(tmp_path, "org", "present")   # has spec AND instance -> present
        self._repo_with_vm(tmp_path, "org", "todo")      # has spec, NO instance -> not-created
        instances = [
            "vergil-user--org--present",
            "vergil-user--org--gone",                    # instance, NO spec -> orphaned
        ]
        rows = discover_dedicated("vergil-user", instances, str(tmp_path))
        by_repo = {r.repo: r for r in rows}
        assert by_repo["present"].state == "present"
        assert by_repo["gone"].state == "orphaned"
        assert by_repo["todo"].state == "not-created"
        assert all(isinstance(r, DedicatedRow) for r in rows)

    def test_other_identity_instances_ignored(self, tmp_path: Path) -> None:
        rows = discover_dedicated("vergil-user", ["vergil-audit--org--repo"], str(tmp_path))
        assert rows == []
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py::TestDiscoverDedicated -v`
Expected: FAIL — `ImportError: cannot import name 'DedicatedRow'`.

- [ ] **Step 3: Implement `DedicatedRow` + `discover_dedicated`**

Add to `vrg_vm.py` (import `parse_instance_name` from `lib.vm_spec`, and `ConfigError` from
`lib.config`):

```python
@dataclass
class DedicatedRow:
    org: str | None
    repo: str | None
    instance: str
    state: str  # "present" | "orphaned" | "not-created"


def _repo_has_vm_spec(projects_dir: str, org: str, repo: str) -> bool:
    path = Path(projects_dir) / org / repo / "vergil.toml"
    if not path.exists():
        return False
    try:
        return read_config(path).vm is not None
    except ConfigError:
        return False


def discover_dedicated(
    identity_name: str, instances: list[str], projects_dir: str
) -> list[DedicatedRow]:
    """Reconcile existing <identity>--* instances with spec-bearing local repos.

    - instance + spec  -> present
    - instance, no spec -> orphaned
    - spec, no instance -> not-created
    """
    rows: list[DedicatedRow] = []
    seen: set[tuple[str, str]] = set()

    for name in instances:
        try:
            ident, org, repo = parse_instance_name(name)
        except ValueError:
            continue
        if ident != identity_name or org is None or repo is None:
            continue
        seen.add((org, repo))
        state = "present" if _repo_has_vm_spec(projects_dir, org, repo) else "orphaned"
        rows.append(DedicatedRow(org, repo, name, state))

    # spec-bearing repos with no instance yet -> not-created
    root = Path(projects_dir)
    if root.is_dir():
        for org_dir in sorted(p for p in root.iterdir() if p.is_dir()):
            for repo_dir in sorted(p for p in org_dir.iterdir() if p.is_dir()):
                org, repo = org_dir.name, repo_dir.name
                if (org, repo) in seen:
                    continue
                if _repo_has_vm_spec(projects_dir, org, repo):
                    rows.append(
                        DedicatedRow(org, repo, instance_name(identity_name, org, repo),
                                     "not-created")
                    )
    return rows
```

- [ ] **Step 4: Run them to confirm they pass**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py::TestDiscoverDedicated -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
vrg-git add src/vergil_tooling/bin/vrg_vm.py tests/vergil_tooling/test_vrg_vm.py
vrg-commit --type feat --scope vrg-vm \
  --message "discover dedicated VMs and orphans (vergil-vm#99)" \
  --body "discover_dedicated reconciles <identity>--* instances with spec-bearing repos under projects_dir: present / orphaned (instance without spec) / not-created (spec without instance)."
```

---

## Task 3: Rewrite `_cmd_list` with the observability columns *(vergil-tooling)*

**Files:**
- Modify: `src/vergil_tooling/bin/vrg_vm.py`
- Test: `tests/vergil_tooling/test_vrg_vm.py`

`--sessions` keeps its existing behaviour (`_list_sessions`). Only the default VM view changes.

- [ ] **Step 1: Write the failing test (row builder)**

We test the pure row-builder, `_list_rows`, separately from printing:

```python
class TestListRows:
    def _identity(self) -> Identity:
        return Identity(vm_instance="vergil-user", projects_dir="/projects",
                        cpus=4, memory="4GiB", disk="50GiB")

    @patch("vergil_tooling.bin.vrg_vm.vm_occupancy", return_value=(2, 1))
    @patch("vergil_tooling.bin.vrg_vm.vm_spec_status", return_value="ok")
    def test_base_and_present_rows(self, _spec, _occ, tmp_path: Path) -> None:
        ident = self._identity()
        dedic = [DedicatedRow("org", "repo", "vergil-user--org--repo", "present")]
        status = {"vergil-user": "Running", "vergil-user--org--repo": "Running"}
        rows = _list_rows("vergil-user", ident, dedic, status,
                          stanza_for=lambda o, r: _mq_stanza())
        base = next(x for x in rows if x["scope"] == "base")
        ded = next(x for x in rows if x["scope"] == "org/repo")
        assert base["cpus"] == 4 and base["agents"] == 2 and base["humans"] == 1
        assert ded["cpus"] == 12 and ded["spec"] == "ok"

    def test_orphan_and_not_created_rows(self, tmp_path: Path) -> None:
        ident = self._identity()
        dedic = [
            DedicatedRow("o", "gone", "vergil-user--o--gone", "orphaned"),
            DedicatedRow("o", "todo", "vergil-user--o--todo", "not-created"),
        ]
        status = {"vergil-user": "Running"}  # neither dedicated instance running
        rows = _list_rows("vergil-user", ident, dedic, status, stanza_for=lambda o, r: None)
        spec_by_repo = {x["scope"]: x["spec"] for x in rows}
        assert spec_by_repo["o/gone"] == "orphaned"
        assert spec_by_repo["o/todo"] == "not-created"
```

Add a module-level `_mq_stanza()` helper mirroring Plan 1's fixture (packages + a
`vergil-user` role overlay at 12/64GiB/300GiB/stale_days 7).

- [ ] **Step 2: Run them to confirm they fail**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py::TestListRows -v`
Expected: FAIL — `ImportError: cannot import name '_list_rows'`.

- [ ] **Step 3: Implement `_list_rows` and rewrite `_cmd_list`**

Add `_list_rows` to `vrg_vm.py`:

```python
def _list_rows(
    identity_name: str,
    identity: Identity,
    dedicated: list[DedicatedRow],
    status: dict[str, str],
    *,
    stanza_for,
) -> list[dict[str, object]]:
    """Build display rows for one identity: the base VM plus each dedicated row.

    `stanza_for(org, repo)` returns the repo's VmStanza or None (injected for testability).
    """
    rows: list[dict[str, object]] = []
    base = _base_footprint(identity)

    def occupancy(instance: str) -> tuple[str, str]:
        if status.get(instance) == "Running":
            agents, humans = vm_occupancy(instance)
            return str(agents), str(humans)
        return "—", "—"

    # Base row
    b_agents, b_humans = occupancy(identity.vm_instance)
    rows.append({
        "scope": "base", "instance": identity.vm_instance,
        "status": status.get(identity.vm_instance, "Not Created"),
        "cpus": int(base["cpus"]), "memory": str(base["memory"]), "disk": str(base["disk"]),
        "agents": b_agents, "humans": b_humans, "spec": "ok",
    })

    for d in dedicated:
        scope = f"{d.org}/{d.repo}"
        if d.state == "orphaned":
            st = status.get(d.instance, "Not Created")
            ag, hu = occupancy(d.instance)
            rows.append({"scope": scope, "instance": d.instance, "status": st,
                         "cpus": "—", "memory": "—", "disk": "—",
                         "agents": ag, "humans": hu, "spec": "orphaned"})
            continue
        if d.state == "not-created":
            rows.append({"scope": scope, "instance": d.instance, "status": "Not Created",
                         "cpus": "—", "memory": "—", "disk": "—",
                         "agents": "—", "humans": "—", "spec": "not-created"})
            continue
        # present: compose to get footprint + fingerprint + under
        stanza = stanza_for(d.org, d.repo)
        override = identity.overrides.get((d.org, d.repo))
        spec = compose_vm_spec(identity=identity_name, base=base, stanza=stanza, override=override)
        st = status.get(d.instance, "Not Created")
        ag, hu = occupancy(d.instance)
        if st == "Running":
            spec_state = vm_spec_status(d.instance, spec_fingerprint(spec))
            spec_state = "NEEDS-REBUILD" if spec_state == "needs-rebuild" else "ok"
            if spec.under:
                spec_state = f"{spec_state} ⚠ under ({','.join(spec.under)})"
        else:
            spec_state = "ok"
        rows.append({"scope": scope, "instance": d.instance, "status": st,
                     "cpus": spec.cpus, "memory": spec.memory, "disk": spec.disk,
                     "agents": ag, "humans": hu, "spec": spec_state})
    return rows
```

Now rewrite the default branch of `_cmd_list` (keep the `if args.sessions:` branch calling
`_list_sessions`). Replace the VM-listing body with:

```python
    vms = list_vms()
    status = {vm["name"]: vm["status"] for vm in vms}
    instances = [vm["name"] for vm in vms]

    header = (
        f"{'IDENTITY':<14} {'SCOPE':<40} {'STATUS':<8} {'CPUS':<5} {'MEM':<7} "
        f"{'DISK':<7} {'AGENTS':<7} {'HUMANS':<7} {'SPEC':<22}"
    )
    print(header)
    print("─" * len(header))

    def _stanza_for(projects_dir: str):
        def inner(org: str, repo: str):
            path = Path(projects_dir) / org / repo / "vergil.toml"
            if not path.exists():
                return None
            try:
                return read_config(path).vm
            except ConfigError:
                return None
        return inner

    for id_name, identity in config.identities.items():
        dedic = discover_dedicated(id_name, instances, identity.projects_dir)
        for r in _list_rows(id_name, identity, dedic, status,
                            stanza_for=_stanza_for(identity.projects_dir)):
            print(
                f"{id_name:<14} {r['scope']!s:<40} {r['status']!s:<8} "
                f"{r['cpus']!s:<5} {r['memory']!s:<7} {r['disk']!s:<7} "
                f"{r['agents']!s:<7} {r['humans']!s:<7} {r['spec']!s:<22}"
            )
    return 0
```

- [ ] **Step 4: Run them to confirm they pass**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py::TestListRows -v`
Expected: PASS.

- [ ] **Step 5: Run the list-sessions regression**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py -k "list or session" -v`
Expected: PASS — `--sessions` behaviour unchanged.

- [ ] **Step 6: Commit**

```bash
vrg-git add src/vergil_tooling/bin/vrg_vm.py tests/vergil_tooling/test_vrg_vm.py
vrg-commit --type feat --scope vrg-vm \
  --message "rewrite list with footprint, occupancy, and SPEC columns (vergil-vm#99)" \
  --body "Default list view shows IDENTITY/SCOPE/STATUS/CPUS/MEM/DISK/AGENTS/HUMANS/SPEC: composed footprint, process-tree occupancy for running VMs, and SPEC states ok/NEEDS-REBUILD/not-created/orphaned plus the under flag. --sessions unchanged."
```

---

## Task 4: Orphan-aware destroy *(vergil-tooling)*

**Files:**
- Modify: `src/vergil_tooling/bin/vrg_vm.py`
- Test: `tests/vergil_tooling/test_vrg_vm.py`

Plan 2's destroy routes through `_resolve_target`, whose instance for a *no-longer-spec'd*
repo collapses to the base VM. To remove an orphan, destroy must target the literal
`instance_name(identity, org, repo)` when a workspace is given.

- [ ] **Step 1: Write the failing test**

```python
class TestDestroyOrphan:
    @patch("vergil_tooling.bin.vrg_vm.delete_vm")
    @patch("vergil_tooling.bin.vrg_vm.vm_status", return_value="Stopped")
    def test_destroy_removes_orphan_by_name(self, _status, mock_delete) -> None:
        ident = Identity(vm_instance="vergil-user", projects_dir="/projects")
        args = MagicMock(workspace="org/gone", identity="vergil-user", config=None)
        with patch("vergil_tooling.bin.vrg_vm._resolve",
                   return_value=("vergil-user", ident, _config_with(ident))):
            rc = _cmd_destroy(args)
        assert rc == 0
        mock_delete.assert_called_once_with("vergil-user--org--gone")
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py::TestDestroyOrphan -v`
Expected: FAIL — destroy targets the base instance (no spec → `_resolve_target` collapses).

- [ ] **Step 3: Make destroy resolve the instance name directly when given a workspace**

Replace `_cmd_destroy` so it computes the instance by name (so orphans are reachable):

```python
def _cmd_destroy(args: argparse.Namespace) -> int:
    name, identity, _config = _resolve(args)
    workspace = getattr(args, "workspace", None)
    if workspace:
        org, repo = _split_workspace(workspace)
        instance = instance_name(name, org, repo)
    else:
        instance = identity.vm_instance

    status = vm_status(instance)
    if not status:
        print(f"VM '{instance}' does not exist.", file=sys.stderr)
        return 1

    print(f"Destroying VM '{instance}' (identity: {name})...")
    delete_vm(instance)
    print(f"VM '{instance}' destroyed.")
    return 0
```

- [ ] **Step 4: Run it to confirm it passes**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py::TestDestroyOrphan -v`
Expected: PASS.

- [ ] **Step 5: Confirm the Plan 2 dedicated-destroy test still passes**

Run: `vrg-container-run -- pytest tests/vergil_tooling/test_vrg_vm.py -k destroy -v`
Expected: PASS — a spec'd repo and an orphan both resolve to the same `<id>--org--repo`
instance name, so both destroy tests are satisfied by the name-based resolution.

- [ ] **Step 6: Commit**

```bash
vrg-git add src/vergil_tooling/bin/vrg_vm.py tests/vergil_tooling/test_vrg_vm.py
vrg-commit --type fix --scope vrg-vm \
  --message "destroy targets the dedicated instance by name, incl. orphans (vergil-vm#99)" \
  --body "destroy <org>/<repo> resolves instance_name(identity, org, repo) directly, so an orphaned dedicated VM (repo dropped its [vm]) can still be removed."
```

---

## Task 5: Full validation + docs touch-up *(vergil-tooling)*

**Files:**
- Modify: `src/vergil_tooling/bin/vrg_vm.py` (argparse `--help` text), docs if present.

- [ ] **Step 1: Update `list` help and document the AGENTS/HUMANS meaning**

In `main()`, update the `p_list` help to mention the new columns, and ensure the `list`
help text defines AGENTS (harness instances) vs HUMANS (open human-held interactive shells;
a tally of shells, not distinct people). Add a short paragraph to the `vrg-vm` docs page if
one exists (search):

Run: `vrg-container-run -- grep -rln "vrg-vm list" docs/ 2>/dev/null`
Update any user-facing doc that lists columns; if none, skip.

- [ ] **Step 2: Full validation gate**

Run: `vrg-container-run -- vrg-validate`
Expected: PASS — full lint + type-check + entire suite green.

- [ ] **Step 3: Commit**

```bash
vrg-git add -A
vrg-commit --type docs --scope vrg-vm \
  --message "document list observability columns (vergil-vm#99)" \
  --body "Help/docs define AGENTS (harness instances) vs HUMANS (open human-held interactive shells; a count of shells, not people) and the SPEC states."
```

---

## Done criteria (Plan 3)

- `vm_occupancy` returns `(agents, humans)` by process-tree classification, `(0,0)` on failure.
- `discover_dedicated` classifies instances/repos as present / orphaned / not-created.
- `vrg-vm list` shows CPUS/MEM/DISK + AGENTS/HUMANS (running only) + SPEC
  (`ok`/`NEEDS-REBUILD`/`not-created`/`orphaned`/`under`); `--sessions` unchanged.
- `destroy <org>/<repo>` removes orphans by instance name.
- `vrg-validate` is green.

## Integration note (all three plans)

Unit tests mock `limactl`/in-VM execution. The end-to-end behaviours — the template's
param provisioning, the in-VM fingerprint marker, and the occupancy classifier — are
validated by an actual VM build (the `vergil-vm` CI build test / a manual
`vrg-vm create logical-minds-foundry/mq-cluster-tooling`), per the spec's acceptance
criteria. Flag this in the PR so a human runs at least one real dedicated-VM build before merge.
