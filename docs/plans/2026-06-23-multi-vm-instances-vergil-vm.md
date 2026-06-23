# Multiple VM Instances Per Repo — vergil-vm Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the GCP OpenTofu modules' defense-in-depth `var.name` validation that backs the hashed cloud-resource-naming contract for named instances (#242), with a host-side test, and record the naming decision in the architecture docs.

**Architecture:** The GCP modules are already instance-agnostic — `name` and `labels` are opaque pass-throughs, the disk is `${var.name}-data`, the firewall `${var.name}-ssh`. Named instances therefore need **no interface change**. The dispatcher (vergil-tooling, out of scope) derives a deterministic hashed `vrg-<12hex of sha256(slug)>` resource name to stay within GCP's 63-char (RFC1035) limit, and carries the human identity in `vergil-identity`/`vergil-repo`/`vergil-instance` labels. This repo's job is to make the modules **fail loudly** if a malformed or over-length `name` ever arrives, and to document the contract.

**Tech Stack:** OpenTofu (HCL, `hashicorp/google ~> 6.0`), bash test harness, Docusaurus markdown docs.

## Source spec

`docs/specs/2026-06-23-multiple-vm-instances-per-repo-design.md` — see "Cloud resource names are hashed (the 63-char limit)" and the vergil-vm implementation touch-points.

## Out of scope (vergil-tooling — separate repo, separate plan)

Do **not** attempt these here; they live in the `vergil-tooling` companion (issue to be filed, mirrors #1412/#1706):

- Parsing the `[vm.<identity>.instances.<name>]` namespace; tier 1–5 composition; per-identity scoping; `--name` across every verb.
- Four-part handle/slug naming, reversible `split('--')`, repo-name `--` rejection, instance-name validation.
- The `vrg-<hash>` derivation, label composition, recorded-state lifecycle dispatch (`destroy`/`stop`/`start` enumerating all recorded state), and the `vrg-vm list` INSTANCE/`no-vm`/per-provider rows.

A gated real two-instance cloud e2e is also deferred: `tests/e2e-off-platform.sh` does not exist (#199 left the paid cloud e2e unbuilt).

## Global Constraints

- **Worktree:** all work happens in `/.worktrees/issue-242-multi-vm-instances/` on branch `feature/242-multi-vm-instances`. Use absolute worktree paths for Read/Edit/Write; `cd` into the worktree for Bash. Never edit the project root (read-only main worktree).
- **Git wrappers:** use `vrg-git` (not `git`) and `vrg-gh` (not `gh`). Commits go through **`vrg-commit --type <t> --scope <s> --message <m> [--body <b>]`** (raw `git commit` is denied). Heredocs are blocked — pass `--body` as a normal quoted string.
- **Canonical validation:** `vrg-container-run -- vrg-validate` is the **only** full validation command. Do not run individual linters/formatters outside it. For the TDD inner loop, running a single `tests/check-*.sh` script directly is observing a test, which is fine.
- **GCP name rule (verbatim from spec):** cloud `name` must be RFC1035 (`^[a-z]([-a-z0-9]*[a-z0-9])?$`) and **≤ 58 chars** so the derived `<name>-data` disk stays within GCP's 63-char limit.
- **fmt-clean HCL:** `check-opentofu-validate.sh` runs `tofu fmt -check -diff`; committed HCL must already be `tofu fmt`-formatted (the code blocks below are). If fmt-check fails in validation, hand-correct the spacing to match the `-diff` output.

---

### Task 1: GCP module `var.name` validation guard + host test

**Files:**
- Modify: `opentofu/modules/gcp/volume/variables.tf:1` (the `variable "name"` block)
- Modify: `opentofu/modules/gcp/vm/variables.tf:1` (the `variable "name"` block)
- Create: `tests/check-opentofu-name-validation.sh`
- Modify: `tests/run-host-tests.sh:9-10` (add the new check to the run list)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: both GCP modules reject a `var.name` that is non-RFC1035 or > 58 chars at `tofu plan`; a host check `tests/check-opentofu-name-validation.sh` asserting the guard is present in both modules, wired into `tests/run-host-tests.sh`.

- [ ] **Step 1: Write the failing test**

Create `tests/check-opentofu-name-validation.sh`:

```bash
#!/usr/bin/env bash
# tests/check-opentofu-name-validation.sh — Assert each GCP module's `name` variable
# carries the defense-in-depth validation backing the hashed-naming contract (#242):
# RFC1035 charset and length <= 58 (so the derived <name>-data disk stays within GCP's
# 63-char limit). HOST-side text inspection — no tofu needed. The check-* prefix keeps
# it out of the run-tests.sh in-guest test_*.sh glob.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

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

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/pmoore/dev/projects/vergil-project/vergil-vm/.worktrees/issue-242-multi-vm-instances && bash tests/check-opentofu-name-validation.sh`
Expected: `FAIL: volume: name variable missing length validation 'length(var.name) <= 58'` (exit 1) — the validation does not exist yet.

- [ ] **Step 3: Add the validation to the volume module**

Replace the `variable "name" { type = string }` line at the top of `opentofu/modules/gcp/volume/variables.tf` with:

```hcl
variable "name" {
  type = string

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.name))
    error_message = "name must be RFC1035: a lowercase letter first, then lowercase alphanumerics or hyphens, no trailing hyphen."
  }

  validation {
    condition     = length(var.name) <= 58
    error_message = "name must be <= 58 chars so the derived <name>-data disk stays within GCP's 63-char limit."
  }
}
```

- [ ] **Step 4: Add the same validation to the vm module**

Replace the `variable "name" { type = string }` line at the top of `opentofu/modules/gcp/vm/variables.tf` with the identical block:

```hcl
variable "name" {
  type = string

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.name))
    error_message = "name must be RFC1035: a lowercase letter first, then lowercase alphanumerics or hyphens, no trailing hyphen."
  }

  validation {
    condition     = length(var.name) <= 58
    error_message = "name must be <= 58 chars so the derived <name>-data disk stays within GCP's 63-char limit."
  }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd /Users/pmoore/dev/projects/vergil-project/vergil-vm/.worktrees/issue-242-multi-vm-instances && bash tests/check-opentofu-name-validation.sh`
Expected: `PASS: GCP volume/vm name validation present` (exit 0).

- [ ] **Step 6: Wire the new check into the host harness**

In `tests/run-host-tests.sh`, extend the `for t in …` list (currently ending `check-opentofu-validate`) to include the new check:

```bash
for t in check-template-generation check-provision-manifest check-cloud-init-generation \
         check-opentofu-contract check-opentofu-validate check-opentofu-name-validation; do
```

- [ ] **Step 7: Run the full canonical validation**

Run: `cd /Users/pmoore/dev/projects/vergil-project/vergil-vm/.worktrees/issue-242-multi-vm-instances && vrg-container-run -- vrg-validate`
Expected: PASS. Specifically: `tofu fmt -check` clean on both modules (the blocks above are fmt-formatted), `tofu validate` green (validation syntax parses), `check-opentofu-contract.sh` still PASS (no interface drift — no new variables), and the new `check-opentofu-name-validation` step prints `PASS`.
If `tofu fmt -check` reports a diff, hand-correct the spacing in the two `variables.tf` files to match the `-diff` output, then re-run.

- [ ] **Step 8: Commit**

```bash
cd /Users/pmoore/dev/projects/vergil-project/vergil-vm/.worktrees/issue-242-multi-vm-instances
vrg-git add opentofu/modules/gcp/volume/variables.tf opentofu/modules/gcp/vm/variables.tf tests/check-opentofu-name-validation.sh tests/run-host-tests.sh
vrg-commit --type feat --scope off-platform --message "validate GCP module name (RFC1035, <=58) for hashed instance naming (#242)" --body "Named instances (#242) make the dispatcher derive a hashed vrg-<hash> cloud resource name to fit GCP's 63-char RFC1035 limit, since the four-segment slug overflows it. Add a defense-in-depth validation on var.name in both GCP modules (charset + length <= 58, so <name>-data stays <= 63), failing tofu plan loudly rather than erroring deep in apply. New host check check-opentofu-name-validation.sh asserts the guard; wired into run-host-tests.sh. No interface change (name/labels already opaque; vergil-instance is a label value)."
```

---

### Task 2: Document the named-instance naming contract

**Files:**
- Modify: `docs/site/docs/architecture/decisions/off-platform-gcp-modules.md` (insert a section after "## Provider-agnostic interface", which ends at the `enable_nested_virtualization` line)

**Interfaces:**
- Consumes: the `var.name` validation from Task 1 (referenced in the doc).
- Produces: a documented record of the readable-slug-vs-hashed-name split, the label-carried identity, and the module guard.

- [ ] **Step 1: Insert the documentation section**

In `docs/site/docs/architecture/decisions/off-platform-gcp-modules.md`, immediately after the "## Provider-agnostic interface" section (after the line ending `…stay inside the module.`) and before "## One provisioning truth", insert:

```markdown
## Named instances and resource naming (#242)

One `(identity, org/repo)` can own several named instances (vergil-vm #242), each its
own VM + volume. The instance handle is the four-segment slug
`<identity>--<org>--<repo>--<name>`, used for the tofu **state path**, the **Lima**
instance name, and as the **source of the identity labels**.

GCP resource names cannot be the slug: instance/disk/firewall names are capped at **63
chars** (RFC1035), the derived `<name>-data` / `<name>-ssh` add 5 / 4, and a realistic
four-segment slug already overflows. So the dispatcher (#1706) passes the modules a
**deterministic hashed name** — `vrg-<first 12 hex of sha256(slug)>` (≤ 16 chars,
RFC1035-valid) — and carries the human identity in the `vergil-identity` /
`vergil-repo` / `vergil-instance` **labels**. `vrg-vm list` and `tofu import` read the
labels; the cloud-console name is an opaque hash by design. `vergil-instance` is a
label *value* in the existing `labels` map — `interface.json` is unchanged.

The modules **fail loudly on a bad name**: `var.name` in both `volume` and `vm`
carries a `validation` enforcing the RFC1035 charset and length ≤ 58 (so `<name>-data`
stays ≤ 63), so a malformed or over-length name is rejected at `tofu plan`, not deep
in apply. `tests/check-opentofu-name-validation.sh` guards the validation's presence.
```

- [ ] **Step 2: Run the full canonical validation**

Run: `cd /Users/pmoore/dev/projects/vergil-project/vergil-vm/.worktrees/issue-242-multi-vm-instances && vrg-container-run -- vrg-validate`
Expected: PASS (docs generation/freshness checks green; no broken links introduced — the section references only existing anchors and the new test file).

- [ ] **Step 3: Commit**

```bash
cd /Users/pmoore/dev/projects/vergil-project/vergil-vm/.worktrees/issue-242-multi-vm-instances
vrg-git add docs/site/docs/architecture/decisions/off-platform-gcp-modules.md
vrg-commit --type docs --scope off-platform --message "document named-instance hashed resource naming (#242)" --body "Record the #242 contract in the GCP-modules decision page: the four-segment slug keys the state path / Lima instance / labels, while GCP resources take a deterministic vrg-<hash> name (63-char RFC1035 limit), with identity in the vergil-identity/vergil-repo/vergil-instance labels that list and import read. Note the var.name validation guard and that interface.json is unchanged."
```

---

## Self-Review

**Spec coverage (vergil-vm slice only):**
- "Cloud resource names are hashed (the 63-char limit)" → Task 1 (the `var.name` validation that enforces the budget) + Task 2 (documents the hash + label contract). ✓
- vergil-vm touch-point "defense-in-depth `validation` on `var.name` … RFC1035 … ≤ 58" → Task 1. ✓
- "`interface.json` unchanged; `vergil-instance` is a label value" → no module variable added; `check-opentofu-contract.sh` stays green (Task 1 Step 7). ✓
- "host-side check asserting both GCP modules carry the `var.name` … validation" → `tests/check-opentofu-name-validation.sh` (Task 1). ✓
- "decisions-doc update recording the split … + label-identity contract" → Task 2. ✓
- Acceptance criterion 8 (hashed names, labels carry identity, validation rejects bad name at plan) → Task 1 + Task 2. ✓
- Acceptance criterion 9 (existing `tests/` green, Lima default path unchanged) → Task 1 Step 7 runs the full suite; no Lima-path file is touched. ✓
- Spec items NOT covered here are the explicit "Out of scope (vergil-tooling)" list above — by design.

**Placeholder scan:** No TBD/TODO; every code/test/doc step contains the literal content. ✓

**Type/name consistency:** The grep targets in `check-opentofu-name-validation.sh` (`length(var.name) <= 58` and `can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.name))`) match the exact strings written into both `variables.tf` files in Steps 3–4. The new check name `check-opentofu-name-validation` matches between the created file and the `run-host-tests.sh` list entry. ✓
