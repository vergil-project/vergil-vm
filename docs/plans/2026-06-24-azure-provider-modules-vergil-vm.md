# Azure Off-Platform Provider — vergil-vm Modules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `opentofu/modules/azure/{vm,volume}` (and the cloud-init + tests + one interface addition) so the off-platform backend can provision a native-x86 nested-virt VM on Azure, satisfying the same `interface.json` contract as GCP.

**Architecture:** Two OpenTofu root-modules per provider — a long-lived `volume` (resource group + VNet/subnet/NSG + managed disk) and an ephemeral `vm` (public IP + NIC + Linux VM) that parses the resource group out of the `volume_id` (an Azure managed-disk resource ID) and `data`-sources the conventionally-named networking. The shared `templates/provision/*.sh` scripts are reused unchanged; only a per-provider cloud-init skeleton (the data-disk device path) differs.

**Tech Stack:** OpenTofu ≥ 1.8, `hashicorp/azurerm` ~> 4.0, cloud-init, bash host-side check scripts (the repo's established infra-test pattern — no pytest for HCL), `jq`.

## Global Constraints

- **Validation entrypoint:** `vrg-container-run -- vrg-validate` is the ONLY validation command. Do not run linters/formatters outside it. (CLAUDE.md)
- **Git:** use `vrg-git` (not `git`) and `vrg-commit` (not `git commit`). `vrg-commit --type <t> --scope <s> --message <m> [--body <b>]`. End commit bodies with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Worktree:** all edits flow through this worktree (`.worktrees/issue-250-azure-provider`, branch `feature/250-azure-provider`); the main worktree is read-only.
- **Interface contract:** `tests/check-opentofu-contract.sh` enforces that each provider's `volume`/`vm` module declares *exactly* the variable/output names in `opentofu/interface.json` — no extras, no omissions, across all providers. Every module task must keep this green.
- **Validation environment (IMPORTANT — corrected mid-execution):** `tofu` is a macOS-**host** tool and is **NOT present in the sandbox dev container**, so `tofu fmt`/`tofu validate` cannot run in-sandbox today. Adding tofu to the base image is tracked by **vergil-docker#352**; until the rebuilt image lands, in-sandbox verification is the grep-based `check-*.sh` + `vrg-container-run -- vrg-validate` (lint). The plan's per-module `tofu validate` steps run via the new `scripts/bin/validate-custom` (Task 6) **once tofu is in the image** — re-run before finishing. Never `tofu apply`/`plan` in CI/sandbox (those need cloud credentials and run only in the first-milestone manual stand-up). Do NOT self-install tofu in a subagent — it produces unverifiable results; defer to #352.
- **Name rule (reused from GCP):** the `name` variable is RFC1035 (`^[a-z]([-a-z0-9]*[a-z0-9])?$`) and `length(var.name) <= 58`. This is a safe subset of Azure's allowed charset/length for every derived resource name (`<name>-rg`, `-vnet`, `-subnet`, `-nsg`, `-data`, `-pip`, `-nic`).
- **Security type:** the Azure VM MUST NOT be Trusted Launch (incompatible with nested virtualization). Leave `secure_boot_enabled`/`vtpm_enabled` unset/false so the VM is Standard security type.
- **`var.name` is the #242 per-instance handle.** Resource sets are one-per-named-instance.

---

### Task 1: Add `ssh_public_key` to the interface and the GCP vm shim

The strict contract test loops all providers against one `interface.json`. Adding the new key requires updating GCP's vm module in the same task, or the test breaks for GCP. No Azure dir exists yet, so the contract test still only sees GCP here.

**Files:**
- Modify: `opentofu/interface.json` (add `ssh_public_key` to `vm.variables`)
- Modify: `opentofu/modules/gcp/vm/variables.tf` (declare the ignored variable)
- Test: `tests/check-opentofu-contract.sh` (existing — run it, no edit)

**Interfaces:**
- Produces: `ssh_public_key` (string) as a vm-module input every provider must declare. GCP ignores it; Azure (Task 3) consumes it.

- [ ] **Step 1: Run the contract test to confirm the current green baseline**

Run: `vrg-container-run -- bash tests/check-opentofu-contract.sh`
Expected: `PASS: all modules satisfy opentofu/interface.json`

- [ ] **Step 2: Add the variable to the interface contract**

Edit `opentofu/interface.json` so the `vm.variables` array gains `"ssh_public_key"` as its last entry:

```json
{
  "volume": {
    "variables": ["name", "region", "zone", "size_gib", "labels"],
    "outputs": ["volume_id", "zone"]
  },
  "vm": {
    "variables": ["name", "zone", "instance_type", "nested", "volume_id",
                  "boot_disk_gib", "ssh_user", "provision_env", "labels",
                  "ssh_public_key"],
    "outputs": ["host", "ssh_user"]
  }
}
```

- [ ] **Step 3: Run the contract test to verify it now FAILS for GCP**

Run: `vrg-container-run -- bash tests/check-opentofu-contract.sh`
Expected: FAIL — `gcp/vm: variables mismatch` (interface wants `ssh_public_key`, the GCP module does not declare it yet).

- [ ] **Step 4: Declare the ignored variable in the GCP vm module**

Append to `opentofu/modules/gcp/vm/variables.tf`:

```hcl
# Declared only to satisfy the provider-agnostic interface contract (#250). GCP
# reaches the box over IAP, which injects ephemeral SSH keys at connect time, so
# the GCP module manages no keypair and ignores this value. Azure consumes it.
variable "ssh_public_key" {
  type    = string
  default = ""
}
```

- [ ] **Step 5: Run the contract test to verify GCP is green again**

Run: `vrg-container-run -- bash tests/check-opentofu-contract.sh`
Expected: `PASS: all modules satisfy opentofu/interface.json`

- [ ] **Step 6: Commit**

```bash
vrg-commit --type feat --scope off-platform \
  --message "add ssh_public_key to the opentofu vm interface (#250)" \
  --body "Azure VMs require an SSH public key at create; the strict contract test forbids extra module vars, so add one honest interface variable. GCP declares it with default empty and ignores it (IAP injects ephemeral keys).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `azure/volume` module (long-lived resource group + networking + disk)

**Files:**
- Create: `opentofu/modules/azure/volume/versions.tf`
- Create: `opentofu/modules/azure/volume/variables.tf`
- Create: `opentofu/modules/azure/volume/main.tf`
- Create: `opentofu/modules/azure/volume/outputs.tf`

**Interfaces:**
- Consumes: `name, region, zone (default null), size_gib, labels` (the interface `volume.variables`).
- Produces: `volume_id` = the managed disk's Azure resource ID (`/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/disks/<name>-data`); `zone` = the AZ string or `""`. Task 3 parses the RG out of `volume_id`.

> The contract test checks *both* `volume` and `vm` for a provider dir, so it will not pass for `azure/` until Task 3 also exists. This task verifies with `tofu fmt`/`validate` only; Task 3 runs the contract test.

- [ ] **Step 1: Write `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.8.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}
```

- [ ] **Step 2: Write `variables.tf` (exact interface var set for `volume`)**

```hcl
variable "name" {
  type = string

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.name))
    error_message = "name must be RFC1035: a lowercase letter first, then lowercase alphanumerics or hyphens, no trailing hyphen."
  }

  validation {
    condition     = length(var.name) <= 58
    error_message = "name must be <= 58 chars so every derived Azure resource name stays within limits."
  }
}
variable "region" { type = string }
variable "size_gib" { type = number }

variable "zone" {
  type    = string
  default = null # null -> regional (zoneless) disk
}

variable "labels" {
  type    = map(string)
  default = {}
}
```

- [ ] **Step 3: Write `main.tf`**

```hcl
# azurerm is a root-module provider here (the tooling runs `tofu` in this dir), so the
# required features{} block lives in the module. Subscription comes from ARM_SUBSCRIPTION_ID
# in the tofu environment (the tooling sets it); no credentials are committed.
provider "azurerm" {
  features {}
}

# Per-instance resource group (#242): every named instance owns its own RG holding all
# long-lived scaffolding. The gated destroy-volume verb deletes this RG and everything in it.
resource "azurerm_resource_group" "rg" {
  name     = "${var.name}-rg"
  location = var.region
  tags     = var.labels
}

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.name}-vnet"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  address_space       = ["10.42.0.0/16"]
  tags                = var.labels
}

resource "azurerm_subnet" "subnet" {
  name                 = "${var.name}-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.42.0.0/24"]
}

# Subnet-attached NSG. The inbound-22 rule is long-lived (survives VM churn); its source
# is a non-routable placeholder that matches nothing until the SshTransport rewrites
# source_address_prefix to the operator's current /32 at session start (vergil-tooling).
resource "azurerm_network_security_group" "nsg" {
  name                = "${var.name}-nsg"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  tags                = var.labels

  security_rule {
    name                       = "ssh-operator"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "255.255.255.255/32" # placeholder: matches no real source
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "assoc" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# The persistent "laptop analog" data disk. create_option = Empty; never auto-deleted.
# Azure disks cannot shrink in place, so a size_gib decrease must be a deliberate
# destroy-volume, not an in-place apply. zone = null => regional.
resource "azurerm_managed_disk" "data" {
  name                 = "${var.name}-data"
  resource_group_name  = azurerm_resource_group.rg.name
  location             = azurerm_resource_group.rg.location
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.size_gib
  zone                 = var.zone
  tags                 = var.labels
}
```

- [ ] **Step 4: Write `outputs.tf` (exact interface output set for `volume`)**

```hcl
output "volume_id" { value = azurerm_managed_disk.data.id }
output "zone"      { value = var.zone == null ? "" : var.zone }
```

- [ ] **Step 5: Format-check and validate the module (offline, no credentials)**

Run:
```bash
vrg-container-run -- bash -c 'cd opentofu/modules/azure/volume && tofu fmt -check && tofu init -backend=false -input=false && tofu validate'
```
Expected: `tofu fmt -check` prints nothing (formatted); `tofu validate` → `Success! The configuration is valid.`

- [ ] **Step 6: Commit**

```bash
vrg-commit --type feat --scope off-platform \
  --message "add azure/volume opentofu module (#250)" \
  --body "Per-instance resource group + VNet/subnet/NSG + persistent managed disk. volume_id is the disk resource ID, which carries the resource group for the vm module to parse.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `azure/vm` module (public IP + NIC + Linux VM, RG parsed from `volume_id`)

**Files:**
- Create: `opentofu/modules/azure/vm/versions.tf`
- Create: `opentofu/modules/azure/vm/variables.tf`
- Create: `opentofu/modules/azure/vm/main.tf`
- Create: `opentofu/modules/azure/vm/outputs.tf`
- Test: `tests/check-opentofu-contract.sh` (existing — run it)

**Interfaces:**
- Consumes: the full vm var set `name, zone, instance_type, nested, volume_id, boot_disk_gib, ssh_user, provision_env, labels, ssh_public_key`; plus `volume_id` from Task 2.
- Produces: `host` = the public IP address; `ssh_user`.
- Depends on: `opentofu/modules/azure/vm/cloud-init.yaml` existing for `file()` to read. Task 4 generates it; until then `tofu validate` errors on the missing file. **Order Task 4 immediately after this task, OR create an empty placeholder `cloud-init.yaml` here** (Step 5 note).

- [ ] **Step 1: Write `versions.tf`** (identical provider pin to the volume module)

```hcl
terraform {
  required_version = ">= 1.8.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}
```

- [ ] **Step 2: Write `variables.tf` (exact vm interface set incl. `ssh_public_key`)**

```hcl
variable "name" {
  type = string

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.name))
    error_message = "name must be RFC1035: a lowercase letter first, then lowercase alphanumerics or hyphens, no trailing hyphen."
  }

  validation {
    condition     = length(var.name) <= 58
    error_message = "name must be <= 58 chars so every derived Azure resource name stays within limits."
  }
}

variable "zone" { type = string }
variable "instance_type" { type = string }

# The volume module's managed-disk resource ID. Validated so a malformed value fails
# fast at plan rather than producing an empty resource group via a bad split.
variable "volume_id" {
  type = string

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Compute/disks/[^/]+$", var.volume_id))
    error_message = "volume_id must be an Azure managed-disk resource ID (/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/disks/<name>)."
  }
}

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

variable "provision_env" { type = string } # rendered /etc/vergil/provision.env body

variable "labels" {
  type    = map(string)
  default = {}
}
```

- [ ] **Step 3: Write `main.tf`**

```hcl
provider "azurerm" {
  features {}
}

locals {
  # Parse subscription + resource group out of volume_id. split("/", id) yields
  # ["", "subscriptions", <sub>, "resourceGroups", <rg>, "providers", ...]; the
  # subscription is index 2 and the resource group index 4. This is the Azure analog of
  # GCP passing the disk self_link — the resource-group dimension needs no interface key.
  id_parts       = split("/", var.volume_id)
  resource_group = local.id_parts[4]

  # Coarse nested-virt-capable family guard. The Dv3+/Ev3+/Fsv2 families all start with
  # one of these prefixes; the in-guest 70-nested-virt.sh /dev/kvm check is the precise
  # backstop. (Cross-variable checks aren't allowed in variable{} validation on OpenTofu
  # 1.8, so this is enforced as a resource precondition below.)
  nested_capable_prefixes = ["Standard_D", "Standard_E", "Standard_F"]

  # Splice the provision.env body into the generated cloud-init, then base64 it for
  # custom_data. replace() (not templatefile) because the inlined provision scripts
  # contain shell ${...} that templatefile would try to interpret as Terraform.
  provision_env_block = replace(var.provision_env, "\n", "\n      ")
  user_data           = replace(file("${path.module}/cloud-init.yaml"), "@@PROVISION_ENV@@", local.provision_env_block)
}

# Long-lived networking + disk created by the volume module, looked up by convention
# within the parsed resource group. The disk's location pins every resource's region,
# so the vm module needs no region variable.
data "azurerm_managed_disk" "data" {
  name                = "${var.name}-data"
  resource_group_name = local.resource_group
}

data "azurerm_subnet" "subnet" {
  name                 = "${var.name}-subnet"
  virtual_network_name = "${var.name}-vnet"
  resource_group_name  = local.resource_group
}

resource "azurerm_public_ip" "pip" {
  name                = "${var.name}-pip"
  resource_group_name = local.resource_group
  location            = data.azurerm_managed_disk.data.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.labels
}

resource "azurerm_network_interface" "nic" {
  name                = "${var.name}-nic"
  resource_group_name = local.resource_group
  location            = data.azurerm_managed_disk.data.location
  tags                = var.labels

  ip_configuration {
    name                          = "primary"
    subnet_id                     = data.azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip.id
  }
}

resource "azurerm_linux_virtual_machine" "vm" {
  name                  = var.name
  resource_group_name   = local.resource_group
  location              = data.azurerm_managed_disk.data.location
  size                  = var.instance_type
  admin_username        = var.ssh_user
  network_interface_ids = [azurerm_network_interface.nic.id]
  zone                  = var.zone == "" ? null : var.zone
  tags                  = var.labels

  # NESTED VIRT IS LOAD-BEARING: do NOT set secure_boot_enabled / vtpm_enabled. Leaving
  # them unset keeps the VM at the Standard security type. Trusted Launch (the portal
  # default for many sizes) is INCOMPATIBLE with nested virtualization — the in-guest
  # /dev/kvm would never appear and 70-nested-virt.sh would fail the provision.

  admin_ssh_key {
    username   = var.ssh_user
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.boot_disk_gib
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # cloud-init user-data; Azure consumes it base64-encoded via custom_data.
  custom_data = base64encode(local.user_data)

  disable_password_authentication = true

  lifecycle {
    precondition {
      condition     = !var.nested || anytrue([for p in local.nested_capable_prefixes : startswith(var.instance_type, p)])
      error_message = "nested=true but instance_type ${var.instance_type} is not a nested-virt-capable family (expected Dv3+/Ev3+/Fsv2, e.g. Standard_D16s_v5)."
    }
  }
}

# Attach the persistent data disk at LUN 0 -> in-guest /dev/disk/azure/scsi1/lun0
# (the path mount-volume.sh formats-on-first-use and mounts at /vergil).
resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  managed_disk_id    = data.azurerm_managed_disk.data.id
  virtual_machine_id = azurerm_linux_virtual_machine.vm.id
  lun                = 0
  caching            = "ReadWrite"
}
```

- [ ] **Step 4: Write `outputs.tf` (exact vm interface output set)**

```hcl
# The routable public IP (NSG-locked to the operator's current /32 by the tooling).
output "host"     { value = azurerm_public_ip.pip.ip_address }
output "ssh_user" { value = var.ssh_user }
```

- [ ] **Step 5: Create a placeholder `cloud-init.yaml` so `file()`/`validate` resolve**

`local.user_data` calls `file("${path.module}/cloud-init.yaml")`, which must exist for `tofu validate`. Task 4 generates the real one; create a minimal placeholder now so this task validates:

```bash
printf '#cloud-config\n@@PROVISION_ENV@@\n' > opentofu/modules/azure/vm/cloud-init.yaml
```

- [ ] **Step 6: Run the contract test — now azure/{volume,vm} both exist, so it must PASS**

Run: `vrg-container-run -- bash tests/check-opentofu-contract.sh`
Expected: `PASS: all modules satisfy opentofu/interface.json`

- [ ] **Step 7: Format-check and validate the vm module**

Run:
```bash
vrg-container-run -- bash -c 'cd opentofu/modules/azure/vm && tofu fmt -check && tofu init -backend=false -input=false && tofu validate'
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 8: Commit**

```bash
vrg-commit --type feat --scope off-platform \
  --message "add azure/vm opentofu module (#250)" \
  --body "Public IP + NIC + Linux VM. Parses the resource group out of volume_id and data-sources the volume module's networking. Standard security type (Trusted Launch breaks nested virt); nested-family precondition guard; data disk at LUN 0.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Provider-aware cloud-init build + the Azure skeleton (data-disk path delta)

The build script is hardcoded to GCP paths and the disk device path lives in the skeleton. Generalize the builder to assemble every provider's cloud-init from its own skeleton + the shared provision scripts, and add the Azure skeleton whose only delta is the LUN device path.

**Files:**
- Modify: `scripts/build-cloud-init.sh` (auto-discover provider skeletons; build each)
- Create: `opentofu/modules/azure/vm/cloud-init.yaml.skel` (clone of GCP skel; Azure `DEV` path)
- Create (generated): `opentofu/modules/azure/vm/cloud-init.yaml` (overwrites the Task 3 placeholder)
- Test: `tests/check-cloud-init-generation.sh` (existing — covers both once the builder loops)

**Interfaces:**
- Consumes: `templates/provision/*.sh` (shared), each provider's `cloud-init.yaml.skel`.
- Produces: `opentofu/modules/<provider>/vm/cloud-init.yaml` for every provider with a skeleton.

- [ ] **Step 1: Create the Azure skeleton from the GCP one with the LUN device path**

```bash
cp opentofu/modules/gcp/vm/cloud-init.yaml.skel opentofu/modules/azure/vm/cloud-init.yaml.skel
```

Then in `opentofu/modules/azure/vm/cloud-init.yaml.skel`, change the one device-path line inside `mount-volume.sh` from:

```bash
      DEV=/dev/disk/by-id/google-vergil-data   # device_name set by the vm module
```

to:

```bash
      DEV=/dev/disk/azure/scsi1/lun0   # data disk attached at LUN 0 by the vm module
```

(Leave everything else in the skeleton identical — the provision scripts and runcmd are provider-neutral.)

- [ ] **Step 2: Generalize `scripts/build-cloud-init.sh` to loop providers**

Replace the hardcoded `SKEL`/`OUT` assignment and the single `render`/`--check` body. Change the top of the file from:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKEL="${ROOT}/opentofu/modules/gcp/vm/cloud-init.yaml.skel"
OUT="${ROOT}/opentofu/modules/gcp/vm/cloud-init.yaml"
PROV="${ROOT}/templates/provision"
```

to:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROV="${ROOT}/templates/provision"
# Build every provider that ships a vm cloud-init skeleton. Adding a provider dir with a
# skeleton is automatically picked up — no per-provider list to maintain.
SKELS=("${ROOT}"/opentofu/modules/*/vm/cloud-init.yaml.skel)
```

`emit_files`, `emit_runcmd`, and `context_of` are unchanged (they read `$PROV`). Change `render` to take a skeleton argument:

```bash
render() {
  local skel="$1"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"@@PROVISION_FILES@@"*) emit_files ;;
      *"@@PROVISION_RUNCMD@@"*) emit_runcmd ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$skel"
}
```

And replace the final `if [ "${1:-}" = "--check" ]; then … else … fi` block with a per-skeleton loop:

```bash
if [ "${1:-}" = "--check" ]; then
  stale=0
  for skel in "${SKELS[@]}"; do
    out="${skel%.skel}"
    tmp="$(mktemp)"
    render "$skel" > "$tmp"
    if ! diff -u "$out" "$tmp"; then
      echo "build-cloud-init: ${out#"${ROOT}"/} is stale (run scripts/build-cloud-init.sh and commit)" >&2
      stale=1
    fi
    rm -f "$tmp"
  done
  exit "$stale"
else
  for skel in "${SKELS[@]}"; do
    out="${skel%.skel}"
    render "$skel" > "$out"
    echo "Wrote ${out}"
  done
fi
```

- [ ] **Step 3: Run the generator to (re)build both providers' cloud-init.yaml**

Run: `vrg-container-run -- bash scripts/build-cloud-init.sh`
Expected: `Wrote .../gcp/vm/cloud-init.yaml` and `Wrote .../azure/vm/cloud-init.yaml`. The Azure file now contains the full provision payload with the LUN device path, overwriting the Task 3 placeholder. (GCP output must be byte-identical to what is already committed.)

- [ ] **Step 4: Verify the freshness check passes for BOTH providers**

Run: `vrg-container-run -- bash tests/check-cloud-init-generation.sh`
Expected: `PASS: gcp vm cloud-init.yaml is up to date with provision scripts` — and no stale diff for azure. (If the test message only names GCP, update its echo text to be provider-agnostic in this step.)

- [ ] **Step 5: Confirm the GCP cloud-init did not change**

Run: `vrg-git status --short opentofu/modules/gcp/vm/cloud-init.yaml`
Expected: no output (GCP cloud-init unchanged — the generalization is behavior-preserving for GCP).

- [ ] **Step 6: Confirm the azure/vm `@@PROVISION_ENV@@` anchor is at 6-space indent**

The vm module splices `provision_env` with a 6-space indent (`replace(..., "\n", "\n      ")`), so the generated `azure/vm/cloud-init.yaml` must carry `@@PROVISION_ENV@@` under `content: |` at the matching 6-space indent (the GCP skeleton clone already does — verify the clone preserved it).

Run: `grep -n "@@PROVISION_ENV@@" opentofu/modules/azure/vm/cloud-init.yaml`
Expected: the line is indented 6 spaces (`      @@PROVISION_ENV@@`), matching `opentofu/modules/gcp/vm/cloud-init.yaml`.

(`tofu validate` of the module against the real cloud-init is **deferred** to `scripts/bin/validate-custom` once tofu is in the sandbox image — vergil-docker#352. Do NOT run bare `tofu` here.)

- [ ] **Step 7: Commit**

```bash
vrg-commit --type feat --scope off-platform \
  --message "generate azure cloud-init from a provider-aware builder (#250)" \
  --body "Generalize build-cloud-init.sh to assemble every provider's cloud-init from its own skeleton + the shared provision scripts. Add the azure skeleton whose only delta is the LUN data-disk path (/dev/disk/azure/scsi1/lun0). GCP output is byte-identical.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Generalize the name-validation and volume_id-parse checks to Azure

**Files:**
- Modify: `tests/check-opentofu-name-validation.sh` (loop providers, not just GCP)
- Create: `tests/check-azure-volume-id-parse.sh` (assert the vm module's RG-parse + volume_id validation)

**Interfaces:**
- Consumes: the `azure/{volume,vm}/variables.tf` and `azure/vm/main.tf` from Tasks 2–3.

- [ ] **Step 1: Generalize the name-validation check to all provider dirs**

Replace the hardcoded GCP loop in `tests/check-opentofu-name-validation.sh`. Change:

```bash
for kind in volume vm; do
  f="${ROOT}/opentofu/modules/gcp/${kind}/variables.tf"
  [ -f "$f" ] || fail "${kind}: ${f#"${ROOT}"/} missing"
  grep -qF 'length(var.name) <= 58' "$f" \
    || fail "${kind}: name variable missing length validation 'length(var.name) <= 58'"
  grep -qF 'can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.name))' "$f" \
    || fail "${kind}: name variable missing RFC1035 charset validation"
done
echo "PASS: GCP volume/vm name validation present"
```

to:

```bash
shopt -s nullglob
for pdir in "${ROOT}"/opentofu/modules/*/; do
  provider="$(basename "$pdir")"
  for kind in volume vm; do
    f="${pdir}${kind}/variables.tf"
    [ -f "$f" ] || fail "${provider}/${kind}: ${f#"${ROOT}"/} missing"
    grep -qF 'length(var.name) <= 58' "$f" \
      || fail "${provider}/${kind}: name variable missing length validation 'length(var.name) <= 58'"
    grep -qF 'can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.name))' "$f" \
      || fail "${provider}/${kind}: name variable missing RFC1035 charset validation"
  done
done
echo "PASS: all providers' volume/vm name validation present"
```

- [ ] **Step 2: Run it — passes for gcp and azure**

Run: `vrg-container-run -- bash tests/check-opentofu-name-validation.sh`
Expected: `PASS: all providers' volume/vm name validation present`

- [ ] **Step 3: Write the volume_id-parse check (host-side text inspection)**

Create `tests/check-azure-volume-id-parse.sh`:

```bash
#!/usr/bin/env bash
# tests/check-azure-volume-id-parse.sh — Assert the azure/vm module both VALIDATES the
# volume_id as an Azure managed-disk resource ID and PARSES the resource group from index
# 4 of split("/", var.volume_id). Host-side text inspection — no tofu. The check-* prefix
# keeps it out of the run-tests.sh in-guest test_*.sh glob.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

vars="${ROOT}/opentofu/modules/azure/vm/variables.tf"
main="${ROOT}/opentofu/modules/azure/vm/main.tf"

grep -qF 'Microsoft.Compute/disks/' "$vars" \
  || fail "volume_id variable missing the Azure disk resource-ID validation regex"
grep -qE 'resource_group[[:space:]]*=[[:space:]]*local\.id_parts\[4\]' "$main" \
  || fail "main.tf must parse the resource group from local.id_parts[4]"
grep -qF 'split("/", var.volume_id)' "$main" \
  || fail "main.tf must derive id_parts via split(\"/\", var.volume_id)"
echo "PASS: azure/vm parses + validates the volume_id resource ID"
```

- [ ] **Step 4: Make it executable and run it**

Run: `chmod +x tests/check-azure-volume-id-parse.sh && vrg-container-run -- bash tests/check-azure-volume-id-parse.sh`
Expected: `PASS: azure/vm parses + validates the volume_id resource ID`

- [ ] **Step 5: Commit**

```bash
vrg-commit --type test --scope off-platform \
  --message "extend opentofu name + volume_id parse checks to azure (#250)" \
  --body "Generalize the name-validation check to every provider dir; add a host-side check asserting the azure/vm module validates the volume_id resource ID and parses the resource group from split index 4.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Add `scripts/bin/validate-custom` (wire opentofu checks + tofu into vrg-validate) and confirm packaging

**Discovered during execution:** `vrg-validate` does NOT currently run the opentofu `check-*.sh` at all. Its custom-validator hook (`vergil_tooling.bin.vrg_validate._find_custom_validator`) looks for `scripts/bin/validate-custom`, and **vergil-vm has no such file** — so the contract test, name check, cloud-init freshness, and the new parse check are not part of the sanctioned gate. This task creates that custom validator so all of them run under `vrg-validate`, and adds `tofu fmt`/`validate` per module guarded on tofu's presence (active automatically once **vergil-docker#352** lands tofu in the sandbox image).

**Files:**
- Create: `scripts/bin/validate-custom` (executable; auto-discovered by `vrg-validate`).

**Interfaces:**
- Consumes: every `tests/check-*.sh` from earlier tasks; `opentofu/modules/*/{volume,vm}`.

- [ ] **Step 1: Write `scripts/bin/validate-custom`**

```bash
#!/usr/bin/env bash
# scripts/bin/validate-custom — repo-specific validation, auto-discovered by vrg-validate
# (vergil_tooling.bin.vrg_validate._find_custom_validator looks for exactly this path).
# Runs the host-side OpenTofu check-*.sh assertions, and — when tofu is available
# (vergil-docker#352) — `tofu fmt`/`validate` for every provider module. fail-defer:
# run everything, report all failures, exit nonzero if any failed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
fail=0

run() { echo "→ $*"; "$@" || fail=1; }

# 1) Grep-based opentofu checks — no tofu needed, always run.
for chk in check-opentofu-contract check-opentofu-name-validation \
           check-cloud-init-generation check-azure-volume-id-parse; do
  s="${ROOT}/tests/${chk}.sh"
  [ -f "$s" ] && run bash "$s"
done

# 2) tofu fmt + validate per module — only when tofu is installed. A missing tofu is
# NOT a silent pass: it is an explicit, loud SKIP so the gap (vergil-docker#352) stays
# visible until the rebuilt image lands, at which point this activates automatically.
if command -v tofu >/dev/null 2>&1; then
  for mdir in "${ROOT}"/opentofu/modules/*/volume "${ROOT}"/opentofu/modules/*/vm; do
    [ -d "$mdir" ] || continue
    echo "→ tofu fmt/validate ${mdir#"${ROOT}"/}"
    ( cd "$mdir" \
      && tofu fmt -check \
      && tofu init -backend=false -input=false >/dev/null \
      && tofu validate ) || fail=1
  done
else
  echo "SKIP: tofu not installed (vergil-docker#352) — HCL fmt/validate not run in-sandbox" >&2
fi

exit "$fail"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/bin/validate-custom`

- [ ] **Step 3: Run the full sanctioned validation — the custom validator is now discovered**

Run: `vrg-container-run -- vrg-validate`
Expected: the lint stages pass AND a `custom` stage runs `scripts/bin/validate-custom`, which runs the four opentofu `check-*.sh` (all PASS) and prints the `SKIP: tofu not installed` line (until #352 lands). `vrg-validate` exits 0.

- [ ] **Step 4: Confirm the module release archive includes `azure/`**

The off-platform consumer fetches the **v-tag source archive** (the whole repo at the tag — #212 published modules as an asset, #216 switched to the tag archive, #0c3c1e9 dropped the bespoke publish job). Confirm no per-provider allowlist filters the modules:

Run: `grep -rn "modules" .github/workflows/ scripts/ 2>/dev/null | grep -iE "gcp|provider|exclude|allowlist|tar|archive"`
Expected: no GCP-only filter — any committed `opentofu/modules/azure/` is in the tag archive automatically. If a filter *is* found, change it to glob `opentofu/modules/**`. Record the finding in the commit message.

- [ ] **Step 5: Commit**

```bash
vrg-commit --type feat --scope off-platform \
  --message "run opentofu checks (+ tofu when present) under vrg-validate via validate-custom (#250)" \
  --body "vrg-validate had no scripts/bin/validate-custom, so the opentofu check-*.sh were not part of the sanctioned gate. Add it: runs the contract/name/cloud-init/parse checks always, and tofu fmt/validate per module when tofu is installed (vergil-docker#352) — a loud SKIP until then. Confirmed azure/ ships in the v-tag source archive (no provider filter).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

> **Post-#352 re-validation (do once tofu is in the image):** re-run `vrg-container-run -- vrg-validate`; the tofu branch activates and validates all GCP + Azure modules. Three follow-ups to apply and commit then: (1) a likely `tofu fmt` normalization pass on the hand-authored HCL; (2) **generate the missing `opentofu/modules/azure/vm/.terraform.lock.hcl`** (azurerm 4.78.0, matching `azure/volume`) — it could not be created in-sandbox without tofu, leaving azure/vm the only module without a pinned lock; (3) confirm `tofu validate` passes for both azure modules against the real cloud-init.

---

### Task 7: First-milestone acceptance (MANUAL — credentialed, NOT CI)

Every prior task stops at offline validation. This task is the only one that proves the
modules actually work, against a real Azure subscription. It is **manual and
out-of-CI** (it creates billed resources and needs `az login`); run it once the
vergil-tooling consumer plan has also landed and a real off-platform Azure profile
exists for the MQ-cluster repo. It owns the spec's "First milestone" acceptance.

**Files:** none (operational verification).

**Interfaces:**
- Consumes: the released Azure modules + the vergil-tooling Azure backend (companion plan).

- [ ] **Step 1: Preconditions**

Confirm: `az login` done; an Azure subscription with quota for `Standard_D16s_v5` (16
vCPU nested-virt-capable) in the target region; the MQ-cluster repo's off-platform
profile set to `provider = "azure"`, `instance = "Standard_D16s_v5"`, `region = <region>`.

- [ ] **Step 2: Stand up a real instance**

Run the off-platform create for the repo (`vrg-vm create` with the Azure profile).
Expected: volume state applies (RG + VNet/subnet/NSG + disk), then VM state applies
(public IP + NIC + VM), and `cloud-init status --wait` over the `SshTransport` returns
`status: done` (not `error`).

- [ ] **Step 3: Prove nested KVM (no TCG tax)**

Over the session, run: `ls -l /dev/kvm && systemd-detect-virt`
Expected: `/dev/kvm` exists (the `70-nested-virt.sh` check passed → Standard security
type, not Trusted Launch), confirming nested KVM rather than TCG software emulation.

- [ ] **Step 4: Prove the persistent volume + provisioning**

Expected: `/vergil` is mounted from `/dev/disk/azure/scsi1/lun0` (the LUN device path);
`/etc/vergil/vm-spec.fingerprint` exists (40-profile.sh ran); a session launches.

- [ ] **Step 5: Exercise the capacity/zone fallback (companion-plan behavior)**

Force a zone stockout (request the SKU in a zone known to be constrained, or temporarily
restrict zones) and confirm the tooling walks to another availability zone and lands,
rather than failing — the capacity-resilience story that motivated Azure.

- [ ] **Step 6: Tear down and record**

Run `vrg-vm destroy` (VM state only; volume survives), confirm no orphan public IP / NIC
/ NSG rule remains, then `destroy-volume` to remove the RG. Capture the working
region + SKU + zone combination into the #204 setup guide.

> No commit — this task is operational acceptance, not a code change.

---

## Self-Review (vergil-vm plan)

**Spec coverage:**
- `azure/{vm,volume}` satisfying interface — Tasks 2, 3. ✓
- Carrier trick (RG from `volume_id`) — Task 3 (`local.id_parts[4]`) + Task 5 check. ✓
- `ssh_public_key` interface addition + GCP shim — Task 1. ✓
- Trusted-Launch/nested guard — Task 3 (no secure_boot/vtpm + family precondition). ✓
- Provisioning delta: data-disk LUN path — Task 4 (azure skeleton). ✓
- Provisioning delta: SSH key — `admin_ssh_key = var.ssh_public_key`, Task 3 (private key is tooling-side, out of scope here). ✓
- Release packaging — Task 6 Step 3. ✓
- Tests under `vrg-validate` — Tasks 1–6 use it as the only entrypoint. ✓
- `interface.json` strict contract stays green — Tasks 1, 3. ✓

**Placeholder scan:** No TBD/TODO. Task 6 Steps 1–3 are investigate-then-act with exact commands (the only legitimate discovery in the plan — the check-runner/packaging mechanism is in a file the plan locates precisely). ✓

**Type consistency:** `local.id_parts`/`local.resource_group` defined in Task 3 and asserted by the Task 5 check using the same names. `ssh_public_key` spelled identically in interface.json, both modules, and the spec. Azure `DEV=/dev/disk/azure/scsi1/lun0` matches `lun = 0` on the data-disk attachment. ✓

**Out of scope (this plan):** all vergil-tooling work — `SshTransport`, NSG refresh, provider parameterization, capacity/zone Azure paths, read & enumerate surface, lifecycle parity, keypair generation/persistence. See the companion vergil-tooling plan.
