# Azure Off-Platform Provider — vergil-tooling Consumer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **This plan lives in vergil-vm (next to the authoritative spec) but EXECUTES in vergil-tooling.** At execution time, copy it into the vergil-tooling repo's `docs/plans/` and run it from a vergil-tooling worktree on the companion issue's feature branch.

**Goal:** Teach the `vrg-vm` off-platform backend to drive the Azure OpenTofu modules — selecting the provider, reaching the VM over a public-IP/NSG SSH transport, generating the keypair, and giving Azure its own credential, capacity/zone, read-enumerate, and lifecycle-parity paths — without regressing GCP.

**Architecture:** A small **provider-strategy** object isolates every GCP-specific seam (transport, preflight, capacity detection, zone enumeration, module path) behind one interface, with a GCP and an Azure implementation. The guest-side code (`vm_guest.py`) and dispatch (`vm_backend.py`) stay provider-neutral and unchanged.

**Tech Stack:** Python 3.12, pytest, `subprocess` over the `az` / `tofu` CLIs, the `azurerm` OpenTofu provider, `cryptography`/`ssh-keygen` for the keypair.

## Global Constraints

- **Dependency: vergil-vm #250 modules** must be released (the modules are fetched from the v-tag archive) before a real Azure `apply` works. Unit tests here mock the CLIs and need no cloud.
- **Dependency: #1831 (named instances)** — this work assumes `cloud_resource_name`/the backend carry the per-instance handle. **Confirm #1831 has landed and re-read `vm_cloud.py` / `vm_backend.py` / `vm_transport.py` before coding**; signatures below reflect the pre-#1831 source and may have gained a `name` parameter.
- **Validation:** vergil-tooling's own test/lint entrypoint (its `vrg-validate` / `pytest` suite). Run it after every task.
- **Git:** `vrg-git` / `vrg-commit`; feature-branch worktree; commit bodies end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **No GCP regression:** every change is provider-branched; the GCP path must behave byte-for-byte as before. Existing GCP tests stay green.
- **No silent non-GCP degradation:** the current `if provider != "gcp"` *skip* guard must become a real Azure branch (Task 6), never a silent no-op.

> **Code-completeness note.** Tasks 1–3 are stable seams with full code (the source is settled today). Tasks 4–7 give exact file/function anchors, the signatures to produce, and test intent, but intentionally defer final line-level code to execution time because they modify functions that #1831 is concurrently changing — writing literal diffs against soon-to-move code would be guesswork. Treat their "Implement" steps as: read the named function, then realize the specified behavior with a test written first.

---

### Task 1: Parameterize the module path on `spec.provider`

The four `modules_root / "gcp" / …` literals are the only thing pinning the dispatcher to GCP modules.

**Files:**
- Modify: `src/vergil_tooling/lib/vm_cloud.py` — `apply_volume`, `apply_vm`, `destroy_vm`, `destroy_volume` (the `modules_root / "gcp" / …` lines)
- Test: `tests/lib/test_vm_cloud.py` (or the existing cloud test module)

**Interfaces:**
- Consumes: `OffPlatformBackend.provider_label` (already set from `spec.provider`).
- Produces: module paths resolved as `modules_root / provider / {"vm","volume"}`.

- [ ] **Step 1: Write the failing test**

```python
def test_module_path_uses_spec_provider(tmp_path):
    # apply_* must resolve the module dir under the spec's provider, not a hardcoded "gcp".
    from vergil_tooling.lib import vm_cloud
    calls = []
    # Stub _run_tofu / _tofu_output to capture the module_dir the function chose.
    vm_cloud._run_tofu = lambda module_dir, *a, **k: calls.append(module_dir)
    vm_cloud._tofu_output = lambda *a, **k: {"volume_id": "x", "zone": "1"}
    vm_cloud.apply_volume(  # adjust kwargs to the current signature
        tmp_path, tmp_path, name="n", region="eastus", size_gib=64, labels={}, zone="1",
        provider="azure",
    )
    assert calls[0] == tmp_path / "azure" / "volume"
```

- [ ] **Step 2: Run it — fails (hardcoded "gcp" or missing `provider` kwarg)**

Run: `pytest tests/lib/test_vm_cloud.py::test_module_path_uses_spec_provider -v`
Expected: FAIL.

- [ ] **Step 3: Thread `provider` through the four functions**

In `vm_cloud.py`, add a `provider: str` parameter (keyword) to `apply_volume`, `apply_vm`, `destroy_vm`, `destroy_volume`, and replace each `modules_root / "gcp" / "volume"` / `"vm"` with `modules_root / provider / "volume"` / `"vm"`. Update the call sites in `vrg_vm.py` to pass `backend.provider_label`.

- [ ] **Step 4: Run the test + the existing GCP cloud tests — all pass**

Run: `pytest tests/lib/test_vm_cloud.py -v`
Expected: PASS (new test green; GCP tests unaffected — they pass `provider="gcp"`).

- [ ] **Step 5: Commit**

```bash
vrg-commit --type refactor --scope off-platform \
  --message "resolve the off-platform module path from spec.provider (#<tooling-issue>)" \
  --body "Replace the four hardcoded gcp module-path literals with the spec's provider so the dispatcher can drive azure/{vm,volume}.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `SshTransport` — plain ssh over the public IP

Mirror `IapTransport`'s surface exactly so all of `vm_guest.py` is reused. Public IP + private key; the NSG refresh is Task 3.

**Files:**
- Modify: `src/vergil_tooling/lib/vm_transport.py` (add `SshTransport`)
- Test: `tests/lib/test_vm_transport.py`

**Interfaces:**
- Consumes: `host` (public IP), `ssh_user`, `key_path` (the persisted private key from Task 3).
- Produces: a `Transport` (`run`/`pipe`/`popen`/`exec_session`) the backend returns for Azure.

- [ ] **Step 1: Write the failing test**

```python
def test_ssh_transport_base_command(monkeypatch):
    from vergil_tooling.lib.vm_transport import SshTransport
    captured = {}
    def fake_run(argv, **kwargs):
        captured["argv"] = argv
        import subprocess
        return subprocess.CompletedProcess(argv, 0, "", "")
    monkeypatch.setattr("subprocess.run", fake_run)
    t = SshTransport(host="20.1.2.3", ssh_user="ubuntu", key_path="/k/id_ed25519")
    t.run("echo", "hi", workdir="/vergil")
    argv = captured["argv"]
    assert argv[0] == "ssh"
    assert "ubuntu@20.1.2.3" in argv
    assert "/k/id_ed25519" in argv                    # -i <key>
    assert any("cd /vergil && echo hi" in a for a in argv)
    assert "StrictHostKeyChecking=accept-new" in " ".join(argv)
```

- [ ] **Step 2: Run it — fails (SshTransport undefined)**

Run: `pytest tests/lib/test_vm_transport.py::test_ssh_transport_base_command -v`
Expected: FAIL with ImportError.

- [ ] **Step 3: Implement `SshTransport`** (append to `vm_transport.py`)

```python
class SshTransport:
    """Transport over plain ``ssh`` to a public-IP host (Azure off-platform).

    The vm module exposes a routable public IP (``host``) and the box is reached as
    ``ssh -i <key> <ssh_user>@<host>``. The NSG that fronts port 22 is locked to the
    operator's current /32, refreshed at session start (see vm_cloud.nsg_refresh).
    Same run/pipe/popen/exec_session surface as the other transports.
    """

    def __init__(self, host: str, ssh_user: str, key_path: str) -> None:
        self.host = host
        self.ssh_user = ssh_user
        self.key_path = key_path

    def _base(self) -> list[str]:
        return [
            "ssh",
            "-i", self.key_path,
            # accept-new: trust the key on first contact (the box is freshly created and
            # its host key is unknown), but still detect a changed key thereafter.
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=~/.config/vergil/known_hosts",
            f"{self.ssh_user}@{self.host}",
        ]

    def run(
        self, *args: str, workdir: str = _DEFAULT_WORKDIR, quiet: bool = False
    ) -> subprocess.CompletedProcess[str]:
        remote = f"cd {shlex.quote(workdir)} && {shlex.join(args)}"
        try:
            return subprocess.run(  # noqa: S603
                [*self._base(), remote],
                check=True,
                capture_output=True,
                text=True,
            )
        except subprocess.CalledProcessError as exc:
            if exc.stderr and not quiet:
                print(exc.stderr, end="", file=sys.stderr)
            raise

    def pipe(self, cmd: str, input_data: str, *, workdir: str = _DEFAULT_WORKDIR) -> None:
        remote = f"cd {shlex.quote(workdir)} && {cmd}"
        try:
            subprocess.run(  # noqa: S603
                [*self._base(), remote],
                check=True,
                input=input_data,
                capture_output=True,
                text=True,
            )
        except subprocess.CalledProcessError as exc:
            if exc.stderr:
                print(exc.stderr, end="", file=sys.stderr)
            raise

    def popen(self, *args: str, workdir: str = _DEFAULT_WORKDIR) -> subprocess.Popen[str]:
        remote = f"cd {shlex.quote(workdir)} && {shlex.join(args)}"
        return subprocess.Popen(  # noqa: S603
            [*self._base(), remote],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )

    def exec_session(self, workdir: str, inner: str) -> NoReturn:
        remote = f"cd {workdir} && {inner}"
        cmd = [*self._base(), "-t", remote]
        os.execvp(cmd[0], cmd)  # noqa: S606, S607
```

- [ ] **Step 4: Run the test — passes**

Run: `pytest tests/lib/test_vm_transport.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
vrg-commit --type feat --scope off-platform \
  --message "add SshTransport for the azure public-IP backend (#<tooling-issue>)" \
  --body "Plain-ssh transport mirroring IapTransport's surface, so all guest-side credential/provisioning code is reused unchanged. NSG refresh lands separately.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Keypair generation/persistence + NSG source-rule refresh

The `host` is public; the box must be reachable only from the operator's current IP, and the SSH keypair must exist before the VM is created (its public half is passed to the module as `ssh_public_key`).

**Files:**
- Modify: `src/vergil_tooling/lib/vm_cloud.py` (keypair helper; `vm_vars` to include `ssh_public_key`; an `nsg_refresh` helper)
- Test: `tests/lib/test_vm_cloud.py`

**Interfaces:**
- Produces:
  - `ensure_keypair(state_dir: Path) -> tuple[Path, str]` → `(private_key_path, public_key_openssh)`, generated once per instance state dir, reused thereafter.
  - `vm_vars(...)` gains `"ssh_public_key": <public_key_openssh>` (Azure) / `""` (GCP).
  - `nsg_refresh(resource_group: str, nsg_name: str, rule: str) -> None` → sets the rule's source to the operator's current public IP via `az network nsg rule update`.

- [ ] **Step 1: Write the failing tests**

```python
def test_ensure_keypair_is_idempotent(tmp_path, monkeypatch):
    from vergil_tooling.lib import vm_cloud
    monkeypatch.setattr(vm_cloud, "_run_keygen", lambda priv: (priv.write_text("PRIV"),
                                                               (priv.with_suffix(".pub")).write_text("ssh-ed25519 AAAA")))
    p1, pub1 = vm_cloud.ensure_keypair(tmp_path)
    p2, pub2 = vm_cloud.ensure_keypair(tmp_path)   # second call must NOT regenerate
    assert p1 == p2 and pub1 == pub2 == "ssh-ed25519 AAAA"

def test_nsg_refresh_sets_current_ip(monkeypatch):
    from vergil_tooling.lib import vm_cloud
    monkeypatch.setattr(vm_cloud, "_operator_public_ip", lambda: "203.0.113.5")
    seen = {}
    monkeypatch.setattr("subprocess.run", lambda argv, **k: seen.setdefault("argv", argv) or _ok())
    vm_cloud.nsg_refresh("n-rg", "n-nsg", "ssh-operator")
    argv = seen["argv"]
    assert "az" == argv[0] and "203.0.113.5/32" in " ".join(argv)
    assert "--source-address-prefixes" in argv
```

- [ ] **Step 2: Run — both fail**

Run: `pytest tests/lib/test_vm_cloud.py -k "keypair or nsg_refresh" -v`
Expected: FAIL.

- [ ] **Step 3: Implement**

- `ensure_keypair(state_dir)`: if `state_dir/id_ed25519` exists, read `.pub` and return; else `ssh-keygen -t ed25519 -N "" -f <state_dir>/id_ed25519` (via a `_run_keygen` seam) and return the path + the `.pub` contents stripped. ed25519 (short public key, modern default).
- `_operator_public_ip()`: query a stable echo endpoint (e.g. `curl -fsS https://api.ipify.org`) with a short timeout; raise a clear error on failure (no silent fallback to a wide-open rule).
- `nsg_refresh(resource_group, nsg_name, rule)`: `az network nsg rule update -g <rg> --nsg-name <nsg> -n <rule> --source-address-prefixes <ip>/32`.
- In `vm_vars`, add `"ssh_public_key"`: the Azure path passes `ensure_keypair(...)`'s public key; the GCP path passes `""`. (This is where the provider strategy from Task 4 chooses.)

- [ ] **Step 4: Wire `nsg_refresh` into the Azure transport acquisition**

In the backend's `transport()` for Azure: derive `resource_group` from the persisted volume_id (same parse as the module), call `nsg_refresh(...)` before returning the `SshTransport`. (GCP's `transport()` is unchanged — IAP needs no refresh.)

- [ ] **Step 5: Run the tests + GCP regression**

Run: `pytest tests/lib/test_vm_cloud.py -v`
Expected: PASS; GCP `vm_vars` now emits `ssh_public_key=""` (assert this in the existing GCP test).

- [ ] **Step 6: Commit**

```bash
vrg-commit --type feat --scope off-platform \
  --message "azure keypair + session-time NSG source refresh (#<tooling-issue>)" \
  --body "Generate/persist an ed25519 keypair per instance, pass the public key to the module as ssh_public_key, and rewrite the NSG inbound-22 source to the operator's current /32 before each session (the roaming fix replacing IAP).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Provider-strategy seam + Azure preflight/credentials

Extract the GCP-specific branch points behind one strategy object with a GCP and an Azure implementation, then give Azure its preflight + credential resolution.

**Files:**
- Create: `src/vergil_tooling/lib/vm_provider.py` (the strategy: `GcpStrategy`, `AzureStrategy`, a `strategy_for(provider)` factory)
- Modify: `src/vergil_tooling/lib/vm_cloud.py` (`preflight`, `_tofu_env`/`_resolve_project`, `transport()` selection) to call the strategy
- Test: `tests/lib/test_vm_provider.py`

**Interfaces (the strategy protocol — produce exactly this):**
- `preflight() -> None`
- `tofu_env() -> dict[str, str]` (GCP injects `GOOGLE_CLOUD_PROJECT`; Azure injects `ARM_SUBSCRIPTION_ID`)
- `transport(outputs, state_dir) -> Transport`
- `zone_enum(region) -> list[str]`
- `is_capacity_error(exc) -> bool`
- `ssh_public_key(state_dir) -> str` (GCP `""`; Azure the generated key)

- [ ] **Step 1: Write failing tests** for `AzureStrategy.preflight` (asserts it checks `az` present + `az account get-access-token`, raising SystemExit with remediation when absent) and `tofu_env` (asserts `ARM_SUBSCRIPTION_ID` resolved from `AZURE_SUBSCRIPTION_ID` or `az account show --query id`). Mock `shutil.which` / `subprocess.run`.

- [ ] **Step 2: Run — fail.**

- [ ] **Step 3: Implement** `AzureStrategy`:
  - `preflight`: `tofu` ≥ 1.8 (reuse the shared check); `shutil.which("az")`; `az account get-access-token` succeeds or abort with `az login`.
  - `tofu_env`: resolve subscription from `AZURE_SUBSCRIPTION_ID` else `az account show --query id -o tsv`; set `ARM_SUBSCRIPTION_ID`; abort clearly if empty (mirror `_resolve_project`'s no-silent-failure shape).
  - Move the existing GCP logic into `GcpStrategy` unchanged; `strategy_for(provider)` returns the right one.

- [ ] **Step 4: Replace the `if provider != "gcp"` skip and the inlined GCP CLI calls in `vm_cloud.py` with `strategy_for(provider).<method>()`.** No behavior change for GCP.

- [ ] **Step 5: Run all cloud + provider tests — GCP unchanged, Azure covered.**

- [ ] **Step 6: Commit** (`feat(off-platform): provider-strategy seam + azure preflight/credentials`).

---

### Task 5: Azure capacity detection + zone fallback

Reuse `apply_vm_with_zone_fallback`; give Azure the three GCP-coupled pieces it lacks.

**Files:**
- Modify: `src/vergil_tooling/lib/vm_cloud.py` — `region_zones` (→ strategy `zone_enum`), `is_zone_capacity_error` (→ strategy `is_capacity_error`), and the zone-suffix logic; `apply_vm_with_zone_fallback` to call the strategy
- Test: `tests/lib/test_vm_cloud.py`

**Interfaces:**
- `AzureStrategy.zone_enum(region)` → `["1","2","3"]` filtered to AZs the region+SKU actually offer (via `az vm list-skus -l <region> --query "...zones"`); returns `[]` for a zoneless region (regional deployment, no fallback).
- `AzureStrategy.is_capacity_error(exc)` → true for `SkuNotAvailable` / `ZonalAllocationFailed` / `OverconstrainedAllocationRequest` in the tofu/az error text.

- [ ] **Step 1: Write failing tests** — `is_capacity_error` matches each Azure stockout string and rejects unrelated errors; `zone_enum` returns bare integers and `[]` for a zoneless region; `apply_vm_with_zone_fallback` sweeps Azure zones using these (mock the apply to fail-capacity on zone "1", succeed on "2").

- [ ] **Step 2: Run — fail.**

- [ ] **Step 3: Implement** the two `AzureStrategy` methods; route `region_zones`/`is_zone_capacity_error` through the strategy; ensure the empty-zone (regional) case skips the sweep cleanly. The zone-pinned empty-volume recreate stays, keyed off the Azure disk's `zone`.

- [ ] **Step 4: Run all — Azure sweep works, GCP sweep unchanged.**

- [ ] **Step 5: Commit** (`feat(off-platform): azure capacity detection + availability-zone fallback`).

---

### Task 6: Read & enumerate surface (status / list / volumes / zones)

Every read path that shells to `gcloud` gets an Azure branch. No silent non-GCP degradation.

**Files:**
- Modify: `src/vergil_tooling/lib/vm_cloud.py` — `OffPlatformBackend.status()` and any `gcloud`-direct enumerations
- Modify: `src/vergil_tooling/bin/vrg_vm.py` — `list` / session-listing / `update --all` paths that branch on provider
- Test: `tests/lib/test_vm_cloud.py`, `tests/bin/test_vrg_vm.py`

**Interfaces:**
- `AzureStrategy.status(name, resource_group)` → maps `az vm get-instance-view`/`az vm show` power-state to the same status strings the GCP path returns.

- [ ] **Step 1: Write a failing test** that `OffPlatformBackend.status()` for an `azure` spec invokes `az vm` (not `gcloud`) and maps `PowerState/running` → the running status string; and that the `provider != "gcp"` zone-status guard now executes the Azure branch rather than skipping.

- [ ] **Step 2: Run — fail.**

- [ ] **Step 3: Implement** the Azure `status` mapping in the strategy; replace the skip-guard with `strategy_for(provider).status(...)`; branch the `list`/`volumes`/`update --all` enumerations through the strategy.

- [ ] **Step 4: Run — Azure status/list resolve; GCP unchanged.**

- [ ] **Step 5: Commit** (`feat(off-platform): azure read & enumerate surface (status/list/volumes)`).

---

### Task 7: Lifecycle parity — in-place update + orphan rollback

Replicate the two GCP-hardened behaviors for Azure so they don't silently regress.

**Files:**
- Modify: `src/vergil_tooling/lib/vm_cloud.py` — the in-place-update path (#1815) to run over the Azure transport; `apply_vm`'s failed-apply rollback to cover the Azure ephemeral set
- Test: `tests/lib/test_vm_cloud.py`

**Interfaces:**
- In-place update: the existing update path uses `backend.transport()`, which now returns `SshTransport` for Azure — confirm the update verb does NOT fall back to rebuild for Azure.
- Rollback: on a failed Azure `apply_vm`, `tofu destroy` the VM state so a half-created **public IP / NIC / VM** plus any stale **NSG source rule** are rolled back, leaving retries clean (mirrors the GCP orphan-firewall rollback).

- [ ] **Step 1: Write failing tests** — (a) `update` on an `azure` spec dispatches over `SshTransport` rather than rebuilding; (b) a forced `apply_vm` failure triggers the rollback `tofu destroy` against the Azure vm state and re-raises the original error.

- [ ] **Step 2: Run — fail.**

- [ ] **Step 3: Implement** the Azure branches: ensure the in-place update path is transport-driven (provider-neutral), and that the existing `apply_vm` rollback (already present for GCP) applies to the Azure module path resolved in Task 1. Confirm no NSG rule is left pointing at a destroyed box.

- [ ] **Step 4: Run all — parity for Azure, GCP unchanged.**

- [ ] **Step 5: Commit** (`feat(off-platform): azure in-place update + failed-apply orphan rollback`).

---

## Self-Review (vergil-tooling plan)

**Spec coverage:** provider parameterization → T1; `SshTransport` + NSG refresh → T2/T3; keypair + `ssh_public_key` → T3; provider-strategy seam + preflight/credentials → T4; capacity + zone fallback (3 GCP-coupled pieces) → T5; read & enumerate surface + no-silent-degradation → T6; lifecycle parity (#1815/#1807) → T7. ✓

**Placeholder scan:** Tasks 1–3 are line-level complete. Tasks 4–7 are deliberately signature+test-intent level, flagged in the Code-completeness note because they edit functions #1831 is concurrently moving — final code is written test-first against current source at execution. This is an honest dependency, not a hidden TODO. ✓

**Type consistency:** the strategy protocol (`preflight`/`tofu_env`/`transport`/`zone_enum`/`is_capacity_error`/`ssh_public_key`/`status`) is named identically across Tasks 4–7; `ensure_keypair`/`nsg_refresh`/`_operator_public_ip` (T3) are referenced with the same signatures in T4. `ssh_public_key` matches the vergil-vm interface variable. ✓

**Cross-repo ordering:** execute the vergil-vm modules plan first (and release a tag so the modules are fetchable) and confirm #1831 has landed before Task 1 here.
