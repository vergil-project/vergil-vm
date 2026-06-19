# GCP OpenTofu Module Implementation Plan (Off-platform Phase 2, vergil-vm scope)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `vergil-vm`-owned GCP OpenTofu modules (a long-lived persistent **volume** module and an ephemeral **vm** module) that realize the provider-agnostic interface from the design, with cloud-init that reuses the backend-neutral `templates/provision/*.sh` from Phase 1 — proven by **offline** checks (`tofu fmt`/`init -backend=false`/`validate`, a cloud-init generation-freshness test, and an interface-contract test).

**Architecture:** Two modules under `opentofu/modules/gcp/`. `volume/` owns a zonal persistent disk and **outputs the zone it landed in** (state + label), so the ephemeral instance always follows the disk's zone. `vm/` creates a nested-virtualization-enabled instance, attaches the existing volume, sets SSH ingress to the create-initiator's origin address(es), and boots cloud-init. The cloud-init is generated (like Phase 1's `agent.yaml`) by `scripts/build-cloud-init.sh` from a skeleton + the **same** `templates/provision/*.sh`, mapping each script's manifest `context` to `runcmd` (`root`) or `sudo -iu "$VERGIL_USER"` (`user`). The cloud-init also mounts the persistent volume (format-on-first-use) before the provision scripts. The readiness *gate* (poll `cloud-init status` + check the fingerprint marker, hard-fail) is **#1706**'s `create` orchestration, not the module.

**Tech Stack:** OpenTofu (≥ pinned), `hashicorp/google` provider (pinned), cloud-init, Bash, shellcheck.

**Scope boundary (explicit):** This plan is **vergil-vm-only and offline**. The end-to-end loop — `vrg-vm create/session/destroy` dispatch, `tofu apply` orchestration, local state-path management, SSH `session`, GitHub App cred injection, and resolving the operator's origin addresses — lives in **vergil-tooling #1706** and is **out of scope**. So is the real-cloud `e2e-off-platform.sh` (costs money; gated, lands with #1706). Where this plan needs a value #1706 will supply at runtime (origin CIDRs, creds, the composed spec), the module exposes it as an **input variable** and the offline tests pass fakes.

## Global Constraints

- **Validation command (the only one):** `vrg-container-run -- vrg-validate`. (CLAUDE.md)
- **Git/GitHub wrappers + `vrg-commit`** as in Phase 1; project root read-only, edits via this worktree. (CLAUDE.md)
- **No silent failures / no `0.0.0.0/0`.** SSH ingress must be a non-empty explicit list and the module rejects `0.0.0.0/0`. A missing fingerprint marker is a hard failure. (spec security boundary; user global CLAUDE.md)
- **OpenTofu + provider versions are pinned** (`required_version`, `required_providers` `~>`, committed `.terraform.lock.hcl`); the off-platform path preflights `tofu` presence. (spec "Host dependency")
- **Volume is zonal and authoritative.** The vm follows the volume's `zone`; the ephemeral boot disk is a fixed module default; `disk` is not a cloud knob; only `volume` (size) is author-facing. (spec, pushback #3)
- **One provisioning truth.** cloud-init reuses `templates/provision/*.sh` unchanged; no second copy of provisioning logic. (spec, decision)
- **Prereq:** Phase 1 (`…-plan-1-provisioning-extraction.md`) is merged — `templates/provision/*.sh` exist with valid manifests, and `provision.env` is the input contract.

---

## File structure

**Created:**
- `opentofu/interface.json` — the canonical provider-agnostic contract: required variable + output names for the `volume` and `vm` modules. The interface-symmetry test reads this; Azure (Phase 3) must satisfy the same file.
- `opentofu/modules/gcp/volume/{main.tf,variables.tf,outputs.tf,versions.tf}` — the persistent disk module.
- `opentofu/modules/gcp/vm/{main.tf,variables.tf,outputs.tf,versions.tf,cloud-init.yaml.skel}` — the ephemeral instance + attach + cloud-init.
- `opentofu/modules/gcp/vm/cloud-init.yaml` — **generated** by `scripts/build-cloud-init.sh`; committed.
- `scripts/build-cloud-init.sh` — generator: cloud-init skeleton + `templates/provision/*.sh` → `cloud-init.yaml`.
- `tests/check-cloud-init-generation.sh` — host-side freshness check (regenerate, diff). Runs anywhere.
- `tests/check-opentofu-contract.sh` — host-side; asserts each gcp module's `variables.tf`/`outputs.tf` declares exactly the names in `opentofu/interface.json`.
- `tests/check-opentofu-validate.sh` — host-side; runs `tofu fmt -check`, `tofu init -backend=false`, `tofu validate` per module **if `tofu` is on PATH**, else prints a visible `SKIP (tofu not installed)` and exits 0 (visible skip, not a silent pass).

**Modified:**
- `.gitignore` — ignore `.terraform/` and `*.tfstate*` under `opentofu/` (but **not** `.terraform.lock.hcl`, which is committed).
- `CHANGELOG.md` — entry for the GCP modules.

---

## Interface contract (used by every module + the symmetry test)

`opentofu/interface.json` (authoritative; Azure must match in Phase 3):

```json
{
  "volume": {
    "variables": ["name", "region", "zone", "size_gib", "labels"],
    "outputs": ["volume_id", "zone"]
  },
  "vm": {
    "variables": ["name", "zone", "instance_type", "nested", "volume_id",
                  "boot_disk_gib", "ssh_user", "ssh_public_key",
                  "ssh_source_ranges", "provision_env", "labels"],
    "outputs": ["host", "ssh_user"]
  }
}
```

Notes: `zone` is a *variable* on `volume` (optional, defaults to `${region}-b` inside
the module) **and** an *output* (the zone actually used) — the vm consumes the output.
`provision_env` is the rendered `/etc/vergil/provision.env` body (#1706 composes it
from the spec); the module writes it to the guest and the shared scripts source it.

---

## Task 1: Pin versions, seed the interface contract, ignore tofu scratch

**Files:**
- Create: `opentofu/interface.json`
- Create: `opentofu/modules/gcp/volume/versions.tf`, `opentofu/modules/gcp/vm/versions.tf`
- Modify: `.gitignore`
- Create: `tests/check-opentofu-contract.sh`

**Interfaces:**
- Produces: `versions.tf` (shared content) pinning OpenTofu + the google provider;
  `interface.json` (above) consumed by `check-opentofu-contract.sh`.

- [ ] **Step 1: Write the failing contract test**

Create `tests/check-opentofu-contract.sh`:

```bash
#!/usr/bin/env bash
# tests/check-opentofu-contract.sh — Assert each provider's volume/vm modules declare
# exactly the variable/output names in opentofu/interface.json. This is the
# provider-agnostic guard: Azure (Phase 3) must satisfy the same contract. HOST-side,
# no tofu needed (text inspection of *.tf). Not named test_*.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
IFACE="${ROOT}/opentofu/interface.json"
fail() { echo "FAIL: $1" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

# Providers present under opentofu/modules/. Azure is added in Phase 3; the test
# covers whatever provider dirs exist.
for pdir in "${ROOT}"/opentofu/modules/*/; do
  provider="$(basename "$pdir")"
  for kind in volume vm; do
    mdir="${pdir}${kind}"
    [ -d "$mdir" ] || fail "${provider}/${kind}: module dir missing"
    # Declared names from the .tf (block label is the 2nd token: variable "x" {).
    declared_vars="$(grep -hoE '^variable[[:space:]]+"[^"]+"' "${mdir}"/*.tf | sed -E 's/.*"([^"]+)"/\1/' | sort -u)"
    declared_outs="$(grep -hoE '^output[[:space:]]+"[^"]+"'   "${mdir}"/*.tf | sed -E 's/.*"([^"]+)"/\1/' | sort -u)"
    want_vars="$(jq -r ".${kind}.variables[]" "$IFACE" | sort -u)"
    want_outs="$(jq -r ".${kind}.outputs[]"   "$IFACE" | sort -u)"
    [ "$declared_vars" = "$want_vars" ] || fail "${provider}/${kind}: variables mismatch
--- want ---
${want_vars}
--- got ---
${declared_vars}"
    [ "$declared_outs" = "$want_outs" ] || fail "${provider}/${kind}: outputs mismatch
--- want ---
${want_outs}
--- got ---
${declared_outs}"
  done
done
echo "PASS: all modules satisfy opentofu/interface.json"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd <worktree> && bash tests/check-opentofu-contract.sh`
Expected: FAIL — `opentofu/interface.json` missing (or no module dirs).

- [ ] **Step 3: Create the interface contract and versions files**

Create `opentofu/interface.json` with the JSON above. Create both `versions.tf` files
with identical content:

```hcl
terraform {
  required_version = ">= 1.8.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 4: Ignore tofu scratch (keep the lockfile)**

Append to `.gitignore`:

```gitignore
# OpenTofu local scratch (off-platform backend, #199). Keep .terraform.lock.hcl.
opentofu/**/.terraform/
opentofu/**/*.tfstate
opentofu/**/*.tfstate.*
```

- [ ] **Step 5: Contract test still fails (no modules yet) — that's expected**

Run: `cd <worktree> && bash tests/check-opentofu-contract.sh`
Expected: FAIL — `gcp/volume: module dir missing`. (The `.tf` arrive in Tasks 2–3.)

- [ ] **Step 6: Commit**

```bash
cd <worktree>
vrg-git add opentofu/interface.json opentofu/modules/gcp/volume/versions.tf \
  opentofu/modules/gcp/vm/versions.tf .gitignore tests/check-opentofu-contract.sh
vrg-commit --type build --scope opentofu \
  --message "pin OpenTofu/google versions and seed provider-agnostic interface contract (#199)" \
  --body "opentofu/interface.json is the canonical variable/output contract both providers must satisfy; check-opentofu-contract.sh enforces it. versions.tf pins OpenTofu >=1.8 and hashicorp/google ~>6.0."
```

## Task 2: The volume module (zonal, zone-owning)

**Files:**
- Create: `opentofu/modules/gcp/volume/{main.tf,variables.tf,outputs.tf}`

**Interfaces:**
- Produces: a `google_compute_disk` named `var.name`, in `coalesce(var.zone, "${var.region}-b")`,
  sized `var.size_gib`, labeled `var.labels`. Outputs `volume_id` (the disk
  `self_link`) and `zone` (the resolved zone the vm module pins to).

- [ ] **Step 1: variables.tf**

```hcl
variable "name" { type = string }
variable "region" { type = string }
variable "size_gib" { type = number }

variable "zone" {
  type    = string
  default = null # null -> ${region}-b
}

variable "labels" {
  type    = map(string)
  default = {}
}
```

- [ ] **Step 2: main.tf**

```hcl
locals {
  zone = coalesce(var.zone, "${var.region}-b")
}

# Persistent, long-lived data disk — the "laptop analog". Created once; the
# ephemeral VM module attaches it and is pinned to local.zone. prevent_destroy is a
# backstop: routine teardown runs `tofu destroy` on the VM state only, so this
# resource is never in a destroy plan; the guard catches an accidental blanket
# destroy of the volume state. Resize-down is impossible on GCP disks, so a
# shrink in size_gib must be a deliberate destroy-volume, not an in-place apply.
resource "google_compute_disk" "data" {
  name   = var.name
  type   = "pd-ssd"
  zone   = local.zone
  size   = var.size_gib
  labels = var.labels

  lifecycle {
    prevent_destroy = true
  }
}
```

- [ ] **Step 3: outputs.tf**

```hcl
output "volume_id" { value = google_compute_disk.data.self_link }
output "zone"      { value = google_compute_disk.data.zone }
```

- [ ] **Step 4: Offline validate the volume module**

Run (where `tofu` is installed):
`cd <worktree>/opentofu/modules/gcp/volume && tofu fmt -check && tofu init -backend=false && tofu validate`
Expected: `Success! The configuration is valid.`
(If `tofu` is not installed, run the Task-5 `check-opentofu-validate.sh`, which prints a
visible SKIP — but install tofu before merging so this is actually exercised.)

- [ ] **Step 5: Commit**

```bash
cd <worktree>
vrg-git add opentofu/modules/gcp/volume/main.tf opentofu/modules/gcp/volume/variables.tf opentofu/modules/gcp/volume/outputs.tf
vrg-commit --type feat --scope opentofu \
  --message "add gcp volume module (zonal persistent disk, zone-owning) (#199)" \
  --body "google_compute_disk in coalesce(zone, region-b); outputs volume_id + the resolved zone the vm module pins to. prevent_destroy backstops the destroy-VM-keep-volume contract."
```

## Task 3: The cloud-init generator (reuses provision/*.sh)

Build `scripts/build-cloud-init.sh` + the cloud-init skeleton, generating
`cloud-init.yaml` from the **same** `templates/provision/*.sh`, before the vm module
references it.

**Files:**
- Create: `opentofu/modules/gcp/vm/cloud-init.yaml.skel`
- Create: `scripts/build-cloud-init.sh`
- Create: `opentofu/modules/gcp/vm/cloud-init.yaml` (generated)
- Create: `tests/check-cloud-init-generation.sh`

**Interfaces:**
- Produces: `cloud-init.yaml` — a cloud-config that `write_files` the `provision.env`
  (from a `${provision_env}` template placeholder the vm module fills via
  `templatefile`), `write_files` every `templates/provision/*.sh` to
  `/opt/vergil/provision/`, and `runcmd`s them **in numeric order**, mapping manifest
  `context=root` → direct invocation and `context=user` → `sudo -iu "${ssh_user}"`. The
  skeleton also key-disables password SSH (`ssh_pwauth: false`) and mounts the
  persistent volume (format-on-first-use, abort on a foreign filesystem) before the
  provision scripts. **Readiness is not gated in the module** — the SSH poll of
  `cloud-init status` + the `/etc/vergil/vm-spec.fingerprint` check (the marker is
  written by `40-profile.sh`) is #1706's `create` orchestration.
- Marker syntax in the skel: `# @@PROVISION_FILES@@` (expands to the `write_files`
  entries for every script) and `# @@PROVISION_RUNCMD@@` (expands to the ordered
  `runcmd` lines with the context mapping). Note: **all** provision scripts are emitted
  to the cloud box, deliberately — including the Lima-shaped `00-logind-fix.sh` and
  `35-buildkit.sh`, which are benign/no-op on GCP (Issue 5, alignment review). If one
  ever proves harmful on cloud, add a `backends=` manifest filter to the generator.

- [ ] **Step 1: Write the failing generation test**

Create `tests/check-cloud-init-generation.sh`:

```bash
#!/usr/bin/env bash
# tests/check-cloud-init-generation.sh — Assert the committed gcp vm cloud-init.yaml is
# the current output of scripts/build-cloud-init.sh (skeleton + templates/provision/*.sh).
# HOST-side, no tofu. Not named test_*.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
if "${ROOT}/scripts/build-cloud-init.sh" --check; then
  echo "PASS: gcp vm cloud-init.yaml is up to date with provision scripts"
else
  echo "FAIL: cloud-init.yaml stale — run scripts/build-cloud-init.sh and commit" >&2
  exit 1
fi
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd <worktree> && bash tests/check-cloud-init-generation.sh`
Expected: FAIL — `build-cloud-init.sh: No such file or directory`.

- [ ] **Step 3: Write the cloud-init skeleton**

Create `opentofu/modules/gcp/vm/cloud-init.yaml.skel`:

```yaml
#cloud-config
# GENERATED by scripts/build-cloud-init.sh from this skeleton + templates/provision/*.sh.
# Edit the skeleton or the provision scripts, never this committed cloud-init.yaml.

# Key-only SSH (spec security boundary) — never rely on the image default.
ssh_pwauth: false

write_files:
  - path: /etc/vergil/provision.env
    permissions: '0644'
    content: |
      ${provision_env}
  # Persistent-volume mount (spec "Persistent volume → Mount"). Cloud-only: Lima uses
  # the /projects host mount instead. Format-on-first-use ONLY; abort loudly on a
  # foreign (unlabeled) filesystem rather than risk the laptop-analog data.
  - path: /opt/vergil/mount-volume.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -eux -o pipefail
      DEV=/dev/disk/by-id/google-vergil-data   # device_name set by the vm module
      MNT=/vergil
      LABEL=vergil-data
      mkdir -p "$MNT"
      fstype="$(blkid -o value -s TYPE "$DEV" 2>/dev/null || true)"
      label="$(blkid -o value -s LABEL "$DEV" 2>/dev/null || true)"
      if [ -z "$fstype" ]; then
        # Blank disk → first use → format with our label.
        mkfs.ext4 -L "$LABEL" "$DEV"
      elif [ "$label" != "$LABEL" ]; then
        echo "ERROR: $DEV has a foreign filesystem (type=$fstype label='$label'); refusing to mount/format (no-silent-failures)" >&2
        exit 1
      fi
      grep -q "[[:space:]]${MNT}[[:space:]]" /etc/fstab \
        || echo "LABEL=${LABEL} ${MNT} ext4 defaults,nofail 0 2" >> /etc/fstab
      mount "$MNT" || mount -a
# @@PROVISION_FILES@@
runcmd:
  - [ mkdir, -p, /etc/vergil ]
  # Mount the persistent volume BEFORE the provision scripts run (spec ordering).
  - [ bash, /opt/vergil/mount-volume.sh ]
# @@PROVISION_RUNCMD@@
  # Readiness is NOT gated here. The #1706 `create` orchestration polls
  # `cloud-init status --wait` over SSH and checks /etc/vergil/vm-spec.fingerprint
  # (written by 40-profile.sh), failing the create loudly if provisioning errored.
```

> `${provision_env}` is a `templatefile` variable the vm module supplies (the rendered
> env body). The `@@…@@` markers are expanded by the generator at build time, *before*
> tofu ever sees the file.

- [ ] **Step 4: Write the generator**

Create `scripts/build-cloud-init.sh`:

```bash
#!/bin/bash
# scripts/build-cloud-init.sh — Assemble opentofu/modules/gcp/vm/cloud-init.yaml from
# cloud-init.yaml.skel + templates/provision/*.sh. Expands:
#   @@PROVISION_FILES@@  -> a write_files entry per script (to /opt/vergil/provision/)
#   @@PROVISION_RUNCMD@@ -> an ordered runcmd line per script, context-mapped
#     (manifest context=root -> bash <script>; context=user -> sudo -iu <user> bash <script>)
# Usage: build-cloud-init.sh [--check]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKEL="${ROOT}/opentofu/modules/gcp/vm/cloud-init.yaml.skel"
OUT="${ROOT}/opentofu/modules/gcp/vm/cloud-init.yaml"
PROV="${ROOT}/templates/provision"

context_of() {  # context_of <script> -> root|user
  sed -n '2p' "$1" | grep -oE 'context=(root|user)' | cut -d= -f2
}

emit_files() {
  for s in "${PROV}"/*.sh; do
    local b; b="$(basename "$s")"
    printf '  - path: /opt/vergil/provision/%s\n    permissions: '\''0755'\''\n    content: |\n' "$b"
    sed 's/^/      /' "$s"
  done
}

emit_runcmd() {
  for s in "${PROV}"/*.sh; do
    local b ctx; b="$(basename "$s")"; ctx="$(context_of "$s")"
    if [ "$ctx" = "user" ]; then
      printf '  - [ bash, -c, "sudo -iu \\"$VERGIL_USER\\" bash /opt/vergil/provision/%s" ]\n' "$b"
    else
      printf '  - [ bash, /opt/vergil/provision/%s ]\n' "$b"
    fi
  done
}

render() {
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"@@PROVISION_FILES@@"*)  emit_files ;;
      *"@@PROVISION_RUNCMD@@"*) emit_runcmd ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$SKEL"
}

if [ "${1:-}" = "--check" ]; then
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  render > "$tmp"
  diff -u "$OUT" "$tmp" || { echo "build-cloud-init: cloud-init.yaml is stale" >&2; exit 1; }
else
  render > "$OUT"; echo "Wrote ${OUT}"
fi
```

> Note the `runcmd` for `user` context reads `$VERGIL_USER` from the sourced
> `provision.env` at runtime (cloud-init runs `runcmd` as root with `provision.env`
> already written). Phase 1's `30-toolchain.sh`/`35-buildkit.sh` are the `user`-context
> scripts; `sudo -iu` gives them the login-user environment Lima's `mode: user`
> provided.

- [ ] **Step 5: Generate and pass the freshness test**

Run: `cd <worktree> && chmod +x scripts/build-cloud-init.sh && scripts/build-cloud-init.sh && bash tests/check-cloud-init-generation.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd <worktree>
vrg-git add opentofu/modules/gcp/vm/cloud-init.yaml.skel scripts/build-cloud-init.sh \
  opentofu/modules/gcp/vm/cloud-init.yaml tests/check-cloud-init-generation.sh
vrg-commit --type feat --scope opentofu \
  --message "generate gcp vm cloud-init from shared provision scripts (#199)" \
  --body "scripts/build-cloud-init.sh assembles cloud-init.yaml from the skeleton + templates/provision/*.sh, mapping manifest context to runcmd (root) or sudo -iu (user). Same provisioning truth as Lima; freshness guarded by check-cloud-init-generation.sh."
```

## Task 4: The vm module (instance + attach + nested-virt + SSH ingress + cloud-init)

**Files:**
- Create: `opentofu/modules/gcp/vm/{variables.tf,main.tf,outputs.tf}`

**Interfaces:**
- Consumes: the volume module's `volume_id` + `zone`; `cloud-init.yaml` from Task 3;
  `versions.tf` from Task 1.
- Produces: a nested-virt instance pinned to `var.zone`, attaching `var.volume_id`,
  firewalled to `var.ssh_source_ranges`, booting the rendered cloud-init. Outputs
  `host` (public IP) and `ssh_user`.

- [ ] **Step 1: variables.tf (exactly the interface.json `vm.variables` set)**

```hcl
variable "name" { type = string }
variable "zone" { type = string }
variable "instance_type" { type = string }
variable "volume_id" { type = string } # the volume module's self_link
variable "ssh_user" { type = string }
variable "ssh_public_key" { type = string }

variable "nested" {
  type    = bool
  default = true
}

variable "boot_disk_gib" {
  type    = number
  default = 30
}

variable "ssh_source_ranges" {
  type = list(string)
  # #1706 resolves the create-initiator's origin address(es). Reject empties and the
  # any-IPv4 wildcard (no-silent-failures; never expose sshd to the internet).
  validation {
    condition     = length(var.ssh_source_ranges) > 0 && !contains(var.ssh_source_ranges, "0.0.0.0/0")
    error_message = "ssh_source_ranges must be a non-empty list and must not contain 0.0.0.0/0."
  }
}

variable "provision_env" { type = string } # rendered /etc/vergil/provision.env body

variable "labels" {
  type    = map(string)
  default = {}
}
```

- [ ] **Step 2: main.tf**

```hcl
locals {
  # Indent the multi-line provision.env body to sit under cloud-init's `content: |`.
  provision_env_block = replace(var.provision_env, "\n", "\n      ")

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    provision_env = local.provision_env_block
  })
}

# Ingress: SSH only, from the create-initiator's origin address(es). The variable
# validation already forbids an empty list and 0.0.0.0/0.
resource "google_compute_firewall" "ssh" {
  name    = "${var.name}-ssh"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = var.ssh_source_ranges
  target_tags   = [var.name]
}

resource "google_compute_instance" "vm" {
  name         = var.name
  machine_type = var.instance_type
  zone         = var.zone
  tags         = [var.name]
  labels       = var.labels

  # Ephemeral root/boot disk — dies with the instance. The persistent data disk is
  # attached separately below.
  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = var.boot_disk_gib
    }
  }

  # The persistent "laptop analog" volume, by self_link. Never auto-deleted.
  # device_name fixes the in-guest path (/dev/disk/by-id/google-vergil-data) the
  # cloud-init mount-volume.sh script formats-on-first-use and mounts at /vergil.
  attached_disk {
    source      = var.volume_id
    device_name = "vergil-data"
  }

  # Native-x86 nested KVM (the whole point — no TCG). The in-guest 70-nested-virt.sh
  # check fails the provision loudly if /dev/kvm never appears.
  advanced_machine_features {
    enable_nested_virtualization = var.nested
  }

  network_interface {
    network = "default"
    access_config {} # ephemeral public IP for SSH
  }

  metadata = {
    ssh-keys  = "${var.ssh_user}:${var.ssh_public_key}"
    user-data = local.user_data
  }
}
```

- [ ] **Step 3: outputs.tf**

```hcl
output "host"     { value = google_compute_instance.vm.network_interface[0].access_config[0].nat_ip }
output "ssh_user" { value = var.ssh_user }
```

- [ ] **Step 4: Offline validate the vm module**

Run (where `tofu` is installed):
`cd <worktree>/opentofu/modules/gcp/vm && tofu fmt -check && tofu init -backend=false && tofu validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Contract test now passes**

Run: `cd <worktree> && bash tests/check-opentofu-contract.sh`
Expected: PASS — both `gcp/volume` and `gcp/vm` declare exactly `interface.json`'s sets.
(If it fails, the message names the offending module + the variable/output delta — fix
the `.tf` to match the contract, not the contract.)

- [ ] **Step 6: Commit**

```bash
cd <worktree>
vrg-git add opentofu/modules/gcp/vm/variables.tf opentofu/modules/gcp/vm/main.tf opentofu/modules/gcp/vm/outputs.tf
vrg-commit --type feat --scope opentofu \
  --message "add gcp vm module: nested-virt instance, volume attach, SSH ingress, cloud-init (#199)" \
  --body "Instance pinned to the volume's zone, attaching the persistent disk, nested virtualization enabled, SSH firewalled to ssh_source_ranges (validated non-empty, never 0.0.0.0/0), booting the generated cloud-init. Outputs host + ssh_user. Satisfies opentofu/interface.json."
```

## Task 5: Offline validation harness + lockfile + version pinning gate

**Files:**
- Create: `tests/check-opentofu-validate.sh`
- Create: `opentofu/modules/gcp/volume/.terraform.lock.hcl`, `opentofu/modules/gcp/vm/.terraform.lock.hcl` (committed)

**Interfaces:**
- Produces: `check-opentofu-validate.sh` — runs `tofu fmt -check`, `tofu init -backend=false`,
  `tofu validate` for each `opentofu/modules/*/{volume,vm}`; if `tofu` is absent prints
  a single visible `SKIP (tofu not installed; install to exercise module validation)`
  and exits 0.

- [ ] **Step 1: Write the validate harness**

Create `tests/check-opentofu-validate.sh`:

```bash
#!/usr/bin/env bash
# tests/check-opentofu-validate.sh — fmt-check + init(-backend=false) + validate every
# OpenTofu module. Visible SKIP if tofu is not installed (no silent pass). HOST-side.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
if ! command -v tofu >/dev/null 2>&1; then
  echo "SKIP (tofu not installed; install OpenTofu >=1.8 to exercise module validation)"
  exit 0
fi
rc=0
for m in "${ROOT}"/opentofu/modules/*/volume "${ROOT}"/opentofu/modules/*/vm; do
  [ -d "$m" ] || continue
  echo "== ${m#${ROOT}/} =="
  ( cd "$m" && tofu fmt -check -diff && tofu init -backend=false -input=false >/dev/null && tofu validate ) || rc=1
done
[ "$rc" -eq 0 ] && echo "PASS: all modules fmt-clean and valid" || { echo "FAIL: see above" >&2; exit 1; }
exit "$rc"
```

- [ ] **Step 2: Generate and commit the lockfiles**

Run (where `tofu` is installed), per module dir:
`cd <worktree>/opentofu/modules/gcp/volume && tofu init -backend=false && tofu providers lock -platform=linux_amd64 -platform=darwin_arm64`
and the same for `…/vm`. This writes `.terraform.lock.hcl` pinning the resolved
`hashicorp/google` version for both the macOS (operator) and Linux (CI) platforms.

- [ ] **Step 3: Run the validate harness**

Run: `cd <worktree> && bash tests/check-opentofu-validate.sh`
Expected: `PASS: all modules fmt-clean and valid` (or a visible `SKIP` if tofu absent —
in which case run it on a machine with tofu before merging).

- [ ] **Step 4: Commit**

```bash
cd <worktree>
vrg-git add tests/check-opentofu-validate.sh \
  opentofu/modules/gcp/volume/.terraform.lock.hcl opentofu/modules/gcp/vm/.terraform.lock.hcl
vrg-commit --type test --scope opentofu \
  --message "add offline tofu validate harness and commit provider lockfiles (#199)" \
  --body "check-opentofu-validate.sh runs fmt-check/init(-backend=false)/validate per module (visible SKIP without tofu). Committed .terraform.lock.hcl pins hashicorp/google for darwin_arm64 + linux_amd64 (reproducible applies)."
```

## Task 6: Wire the offline checks into validation + docs + changelog

**Files:**
- Modify: the repo's test entrypoint so the new host-side tests run in the standard
  flow. `tests/run-tests.sh` runs **in-guest**, so it is the wrong host for these.
  Add them where the existing host-side e2e are invoked: `scripts/build.sh` (and note
  for #1706 that CI should call them). If a lighter host-only runner is preferred,
  create `tests/run-host-tests.sh` that runs `check-template-generation.sh`,
  `check-provision-manifest.sh`, `check-cloud-init-generation.sh`,
  `check-opentofu-contract.sh`, `check-opentofu-validate.sh`.
- Modify: `docs/site/docs/architecture/` — a short "off-platform GCP modules" page.
- Modify: `CHANGELOG.md`.

- [ ] **Step 1: Add a host-only test runner**

Create `tests/run-host-tests.sh`:

```bash
#!/usr/bin/env bash
# tests/run-host-tests.sh — Run the host-side (no-Lima, no-cloud) checks: template +
# cloud-init generation freshness, provision manifests, and the OpenTofu interface +
# validate. Safe in CI and on any dev box. (Lima integration stays in scripts/build.sh.)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
for t in check-template-generation check-provision-manifest check-cloud-init-generation \
         check-opentofu-contract check-opentofu-validate; do
  echo "== ${t} =="
  bash "${HERE}/${t}.sh"
done
echo "All host-side checks passed."
```

- [ ] **Step 2: Call it from build.sh**

In `scripts/build.sh`, replace the standalone `--check` line added in Phase 1 Task 1
with a call to the runner near the top (before the VM build):

```bash
echo "=== Host-side checks (generation, manifests, opentofu) ==="
bash "${REPO_ROOT}/tests/run-host-tests.sh"
echo ""
```

- [ ] **Step 3: Run the full host suite**

Run: `cd <worktree> && bash tests/run-host-tests.sh`
Expected: every section PASS (or `check-opentofu-validate` SKIP without tofu).
Run: `vrg-container-run -- vrg-validate` → passes (shellcheck on the new scripts).

- [ ] **Step 4: Docs + changelog**

Add a short architecture page: the GCP modules, the volume-owns-zone rule, the
SSH-ingress-from-origin + no-`0.0.0.0/0` rule, cloud-init reusing `provision/*.sh`, and
the explicit note that `apply`/`session`/cred injection live in vergil-tooling #1706.
Add a `CHANGELOG.md` entry: `- Add GCP OpenTofu modules (persistent volume + ephemeral nested-virt VM) for the off-platform backend, offline-validated; e2e/dispatch tracked in vergil-tooling #1706 (#199).`

- [ ] **Step 5: Commit**

```bash
cd <worktree>
vrg-git add tests/run-host-tests.sh scripts/build.sh docs/site/docs/architecture CHANGELOG.md
vrg-commit --type test --scope opentofu \
  --message "add host-side test runner and document gcp modules (#199)"
```

---

## Self-review notes (coverage against the spec)

- **Provider-agnostic interface** → `opentofu/interface.json` + `check-opentofu-contract.sh`
  (the symmetry guard Azure must satisfy in Phase 3).
- **Volume owns zone; vm follows** → volume `outputs.zone`; vm `var.zone`; `prevent_destroy`.
- **Boot disk fixed default; `disk` not a cloud knob; only `volume` author-facing** →
  vm `boot_disk_gib` default 30, no `disk` variable; volume `size_gib`.
- **SSH ingress from origin, never `0.0.0.0/0`** → `ssh_source_ranges` + validation.
- **One provisioning truth** → `build-cloud-init.sh` reuses `templates/provision/*.sh`;
  context-mapped runcmd; freshness test.
- **Pinned versions + lockfile + preflight** → `versions.tf` + committed
  `.terraform.lock.hcl`; the `tofu` preflight itself is #1706 (dispatcher).
- **Nested KVM** → `enable_nested_virtualization`; the in-guest assertion is the shared
  `70-nested-virt.sh`.
- **Persistent volume mount** → cloud-init `mount-volume.sh` (format-on-first-use,
  abort on foreign filesystem, mount `/vergil`); `attached_disk.device_name` fixes the
  guest path. (Checkout/`.claude` population is #1706.)
- **Key-only SSH** → `ssh_pwauth: false` in the cloud-init skeleton.

## Explicitly deferred to vergil-tooling #1706 (NOT in this plan)

- `vrg-vm` backend dispatch; `tofu apply/destroy` orchestration; two-state local paths.
- Composing `provision_env` and `ssh_source_ranges` (resolving the operator's origin
  addresses) from the spec; provider-credential selection.
- SSH `session` transport; GitHub App cred injection onto the ephemeral boot disk.
- The **repo checkout + `.claude` bootstrap** on the mounted `/vergil` volume
  (first-clone vs reattach-`git fetch`, seed empty `.claude`). This module mounts and
  formats the volume; populating it is the post-provision backend step in #1706.
  The readiness gate (poll `cloud-init status` + check `vm-spec.fingerprint`) is #1706.
- Real-cloud `tests/e2e-off-platform.sh` (gated, costs money) asserting `driver=kvm`,
  volume survival across `destroy`+`create`, and cred injection.
- `vrg-vm list` BACKEND column + `unknown (no creds)` degradation; `destroy-volume`;
  `update`→`rebuild`.

## Out of scope (this phase) — Azure

Azure modules (`opentofu/modules/azure/{volume,vm}`) are **Phase 3**. They must satisfy
the same `opentofu/interface.json` (the contract test already iterates every provider
dir, so it covers Azure automatically once the dirs exist).
