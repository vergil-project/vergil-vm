# Provisioning Extraction Implementation Plan (Off-platform Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the inline provisioning in `templates/agent.yaml` into backend-neutral `templates/provision/*.sh` scripts that both the Lima template (via a build-time generator) and the future cloud-init (Phase 2) can invoke, with zero change to the Lima box's behavior.

**Architecture:** `templates/provision/*.sh` becomes the single source of provisioning truth. `templates/agent.yaml` becomes a **generated artifact**, assembled by `scripts/build-template.sh` from a hand-authored skeleton (`templates/agent.yaml.skel`, which owns the Lima-specific structure — mounts, params, `nestedVirtualization`, `containerd`, the `mode: boot` `provision.env` writer, and the readiness probe) plus the provision scripts inlined at `@@INCLUDE@@` markers. Phase 1 lands in two parts: **Part A** is a text-faithful mechanical split (the generator reproduces today's `agent.yaml` byte-for-byte — provable in CI); **Part B** swaps Lima's `{{.User}}`/`{{.Param.*}}` templating inside the scripts for shell variables sourced from `/etc/vergil/provision.env`, making the scripts backend-neutral (proven behavior-identical by the Mac integration build).

**Tech Stack:** Bash, Lima (vz, macOS), shellcheck, the existing `tests/` Lima integration harness.

## Global Constraints

- **Validation command (the only one):** `vrg-container-run -- vrg-validate`. Do not run individual linters outside it. (CLAUDE.md)
- **Git/GitHub wrappers:** use `vrg-git` / `vrg-gh`, never raw `git`/`gh`. Commit with `vrg-commit --type <t> --scope <s> --message <m> [--body <b>]` (raw `git commit` is denied). (CLAUDE.md)
- **Worktree:** all edits flow through this feature-branch worktree; the project root is read-only. Use absolute worktree paths or `cd` into the worktree for Bash. (CLAUDE.md)
- **No silent failures.** No swallowed exceptions, no fallback that hides an error. A failed provision must fail the build loudly. (user global CLAUDE.md; existing template policy)
- **First-boot-only markers stamped LAST.** A guard marker (`provisioned.base`, `provisioned.uv`, `provisioned.profile`) is written only after its block fully succeeds, so a partial run re-runs next boot. (#177)
- **Heredoc indentation:** Lima `provision` script bodies are YAML block scalars; heredoc bodies/terminators that must land at column 0 in the executed script sit at the block's base indent in the YAML. Preserve this exactly when moving blocks. (existing template comments, #170/#187)
- **CI does not build a VM.** GitHub CI runs shell quality + security + docs only. The Lima build/test (`scripts/build.sh`) is a **manual macOS step**. Therefore: text-level checks (generation freshness, manifest, shellcheck) are the automated gate; "Lima behavior unchanged" is proven by a manual `scripts/build.sh` run on a Mac with Lima.

### Verbatim-move convention (read before Part A)

Several tasks **move an existing `agent.yaml` provision block verbatim** into a new
script file. For these, the "code" is the block content that already exists in
`templates/agent.yaml` — re-pasting hundreds of unchanged lines here would add no
information and risk transcription drift. Each move task therefore identifies the
source block **unambiguously by its leading comment and `mode:`**, names the exact
destination file, the manifest header to prepend, and (in Part B) the exact
substitutions to apply. The generation-freshness test (Task 2) is what mechanically
proves the move was faithful: if a single byte changed, regeneration no longer equals
the committed `agent.yaml` and the test fails. Treat that test as the acceptance gate
for every Part A move.

---

## File structure

**Created:**
- `templates/agent.yaml.skel` — hand-authored Lima skeleton with `@@INCLUDE@@` markers; owns all non-script structure + the Lima `provision.env` writer + the readiness probe.
- `templates/provision/00-logind-fix.sh` … `80-port-forwards.sh` — the extracted, backend-neutral provision scripts (inventory in Task 3).
- `scripts/build-template.sh` — the generator: `skel + provision/*.sh → templates/agent.yaml`.
- `tests/test_template_generation.sh` — host-side; regenerates into a temp file and diffs against the committed `agent.yaml`. Runs anywhere (no Lima).
- `tests/test_provision_manifest.sh` — host-side; validates every script's `# vergil-provision:` manifest and that the skel's `mode:` for each include matches the script's declared `context`.

**Modified:**
- `templates/agent.yaml` — becomes generated output of `build-template.sh` (still committed, so Lima consumers and tests that read it directly keep working).
- `scripts/build.sh` — add a generation-freshness assertion before it builds the VM (regenerate, fail if `agent.yaml` is stale).
- `docs/site/docs/architecture/` (one short page) — note that `agent.yaml` is generated; edit `provision/*.sh` + `*.skel`, never `agent.yaml` directly.

**Unchanged (regression guardrails):** every `tests/test_*.sh`, the `tests/e2e-*.sh` suite, `tests/run-tests.sh`.

---

## Part A — Text-faithful mechanical split (CI-verifiable)

Goal of Part A: introduce the generator and move every provision block into a script
**without changing a single byte of the effective `agent.yaml`**. Scripts in Part A
still contain Lima `{{.User}}`/`{{.Param.*}}` templating — they are exact slices of
today's file. Success criterion throughout: `tests/test_template_generation.sh`
passes (generated == committed `agent.yaml`).

### Task 1: The generator and its skeleton (identity transform)

Stand up `build-template.sh` + `agent.yaml.skel` where the skel initially **contains
the entire current `agent.yaml` verbatim and zero `@@INCLUDE@@` markers**, so
generation is the identity transform. This proves the harness before any block moves.

**Files:**
- Create: `scripts/build-template.sh`
- Create: `templates/agent.yaml.skel` (initial copy of `templates/agent.yaml`)
- Create: `tests/test_template_generation.sh`
- Modify: `scripts/build.sh` (add freshness assertion)

**Interfaces:**
- Produces: `scripts/build-template.sh` — usage `build-template.sh [--check]`. With no
  args, writes `templates/agent.yaml` from `templates/agent.yaml.skel` (expanding
  `@@INCLUDE <repo-relative-path>@@` markers). With `--check`, writes to a temp file
  and exits non-zero (printing a diff) if it differs from the committed
  `templates/agent.yaml`. Marker syntax: a line whose only non-whitespace content is
  `# @@INCLUDE <path>@@`; the marker's leading indentation is prepended to every line
  of the included file.

- [ ] **Step 1: Write the failing generation test**

Create `tests/test_template_generation.sh`:

```bash
#!/usr/bin/env bash
# tests/test_template_generation.sh — Assert templates/agent.yaml is the
# current output of scripts/build-template.sh (skel + provision/*.sh).
# HOST-side (no Lima): deliberately NOT named test_*.sh so run-tests.sh does
# not pipe it into a guest. Runs in CI and locally.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
if "${REPO_ROOT}/scripts/build-template.sh" --check; then
  echo "PASS: templates/agent.yaml is up to date with the skeleton and provision scripts"
else
  echo "FAIL: templates/agent.yaml is stale — run scripts/build-template.sh and commit the result" >&2
  exit 1
fi
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd <worktree> && bash tests/test_template_generation.sh`
Expected: FAIL — `scripts/build-template.sh: No such file or directory`.

- [ ] **Step 3: Write the generator**

Create `scripts/build-template.sh`:

```bash
#!/bin/bash
# scripts/build-template.sh — Assemble templates/agent.yaml from the
# hand-authored skeleton templates/agent.yaml.skel by expanding
# `# @@INCLUDE <repo-relative-path>@@` markers with the named file's content,
# preserving the marker line's indentation. agent.yaml is a GENERATED artifact:
# edit templates/provision/*.sh and templates/agent.yaml.skel, never agent.yaml.
#
# Usage:
#   build-template.sh           # regenerate templates/agent.yaml in place
#   build-template.sh --check    # exit non-zero (with a diff) if agent.yaml is stale
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKEL="${REPO_ROOT}/templates/agent.yaml.skel"
OUT="${REPO_ROOT}/templates/agent.yaml"

render() {  # render <skel> -> stdout
  local skel="$1" line indent path
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^([[:space:]]*)#[[:space:]]@@INCLUDE[[:space:]]+([^[:space:]]+)@@[[:space:]]*$ ]]; then
      indent="${BASH_REMATCH[1]}"
      path="${REPO_ROOT}/${BASH_REMATCH[2]}"
      if [ ! -f "$path" ]; then
        echo "build-template: included file not found: ${BASH_REMATCH[2]}" >&2
        exit 1
      fi
      # Prepend the marker's indentation to every included line. Blank lines
      # stay blank (no trailing whitespace).
      while IFS= read -r inc || [ -n "$inc" ]; do
        if [ -z "$inc" ]; then printf '\n'; else printf '%s%s\n' "$indent" "$inc"; fi
      done < "$path"
    else
      printf '%s\n' "$line"
    fi
  done < "$skel"
}

if [ "${1:-}" = "--check" ]; then
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  render "$SKEL" > "$tmp"
  if ! diff -u "$OUT" "$tmp"; then
    echo "build-template: templates/agent.yaml is stale (see diff above)" >&2
    exit 1
  fi
else
  render "$SKEL" > "$OUT"
  echo "Wrote ${OUT}"
fi
```

- [ ] **Step 4: Seed the skeleton as an identity copy**

Run: `cd <worktree> && cp templates/agent.yaml templates/agent.yaml.skel`
(The skel is, for now, a byte-for-byte copy with no markers, so `render` is the
identity transform.)

- [ ] **Step 5: Run the generation test to verify it passes**

Run: `cd <worktree> && chmod +x scripts/build-template.sh && bash tests/test_template_generation.sh`
Expected: PASS — `templates/agent.yaml is up to date …`.

- [ ] **Step 6: Wire the freshness assertion into build.sh**

In `scripts/build.sh`, immediately after the `KEEP`/arg-parse block and before
`echo "=== Building vergil-agent VM ==="`, insert:

```bash
# agent.yaml is generated from the skeleton + provision scripts. Fail early if
# the committed copy is stale, so we never build/test an out-of-date template.
echo "=== Checking templates/agent.yaml is up to date ==="
"${REPO_ROOT}/scripts/build-template.sh" --check
echo ""
```

- [ ] **Step 7: Commit**

```bash
cd <worktree>
vrg-git add scripts/build-template.sh templates/agent.yaml.skel tests/test_template_generation.sh scripts/build.sh
vrg-commit --type build --scope provision \
  --message "add agent.yaml generator with identity-transform skeleton (#199)" \
  --body "templates/agent.yaml becomes a generated artifact assembled by scripts/build-template.sh from templates/agent.yaml.skel. The skeleton is seeded as a byte-for-byte copy (no markers yet), so generation is the identity transform and tests/test_template_generation.sh passes. build.sh now fails early on a stale agent.yaml. Blocks are extracted in subsequent tasks."
```

### Task 2: Extract the readiness probe boundary and prove a single include round-trips

Before moving the real blocks, prove the `@@INCLUDE@@` mechanism on the **simplest,
lowest-risk block** — the `mode: boot` logind fix — so any indentation bug surfaces on
two lines, not two hundred.

**Files:**
- Create: `templates/provision/00-logind-fix.sh`
- Modify: `templates/agent.yaml.skel` (replace the logind block body with a marker)

**Interfaces:**
- Consumes: the generator + freshness test from Task 1.
- Produces: `templates/provision/00-logind-fix.sh` (the first extracted script; **no
  manifest header yet** — headers are added in Part B). Establishes the move pattern.

- [ ] **Step 1: Create the script from the existing block (verbatim)**

Create `templates/provision/00-logind-fix.sh` containing **exactly** the body of the
`mode: boot` block whose leading comment begins
`# systemd-logind busy-loops at 100% CPU polling VT fds`, i.e. the lines from
`set -eu` through the closing `fi` of that block, verbatim and unindented (column 0):

```bash
set -eu
mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nNAutoVTs=0\nReserveVT=0\n' \
  > /etc/systemd/logind.conf.d/10-vergil-novt.conf
if systemctl is-active --quiet systemd-logind 2>/dev/null; then
  systemctl try-restart systemd-logind || true
fi
```

- [ ] **Step 2: Replace the block body in the skel with an include marker**

In `templates/agent.yaml.skel`, find the `- mode: boot` entry with that logind comment.
Keep the `- mode: boot`, the comment lines, and the `script: |` line. Replace the
indented script body (the `set -eu …` through `fi` lines, which are indented 4 spaces
under `script: |`) with a single marker at that same 4-space indent:

```yaml
- mode: boot
  # (keep the existing explanatory comment lines here)
  script: |
    # @@INCLUDE templates/provision/00-logind-fix.sh@@
```

- [ ] **Step 3: Run the freshness test — expect FAIL (proves the marker changed output)**

Run: `cd <worktree> && bash tests/test_template_generation.sh`
Expected: PASS if the include reproduces the body byte-for-byte. If it FAILs, the diff
shows an indentation mismatch — fix the marker indent (must equal the original body
indent) until the diff is empty.

> Note: this is the one task where you iterate on the diff. Once green, the include
> mechanism is proven and every later move is mechanical.

- [ ] **Step 4: Regenerate and confirm green**

Run: `cd <worktree> && scripts/build-template.sh && bash tests/test_template_generation.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd <worktree>
vrg-git add templates/provision/00-logind-fix.sh templates/agent.yaml.skel templates/agent.yaml
vrg-commit --type refactor --scope provision \
  --message "extract logind-fix boot block into provision/00-logind-fix.sh (#199)" \
  --body "First @@INCLUDE@@ round-trip: the mode:boot logind fix moves verbatim into a provision script; generated agent.yaml is byte-identical (test_template_generation green). Proves the include/indentation mechanism."
```

### Task 3: Extract the remaining provision blocks (verbatim, one commit each)

Move every remaining provision block into its script, in this exact inventory. Each is
a **verbatim move** per the convention above: cut the block's `script:` body into the
new file at column 0, replace it with a `# @@INCLUDE@@` marker at the body's original
indent, regenerate, and confirm `test_template_generation.sh` stays green. Do them in
this order, one commit per row.

**Inventory** (source block identified by leading comment + `mode:`; all are
`mode: system` unless noted):

| # | Source block (leading comment) | Mode | Dest file | First-boot guard |
|---|---|---|---|---|
| 1 | `apt-get update … curl wget unzip …` base tools (guard `provisioned.base`) | system | `templates/provision/10-base.sh` | `provisioned.base` |
| 2 | `# PATH for non-login, non-interactive shells.` | system | `templates/provision/15-environment.sh` | none |
| 3 | `# --- Service-surface minimization (issue #78)` | system | `templates/provision/20-minimize.sh` | none |
| 4 | uv + zsh config (guard `provisioned.uv`) | **user** | `templates/provision/30-toolchain.sh` | `provisioned.uv` |
| 5 | `# --- Rootless buildkit for ` + "`nerdctl build`" + ` (issue #97)` | **user** | `templates/provision/35-buildkit.sh` | none |
| 6 | `# --- Per-repo VM profile layering (issue #99, #105)` (guard `provisioned.profile`) | system | `templates/provision/40-profile.sh` | `provisioned.profile` |
| 7 | `# --- Libvirt/KVM group membership (issue #137)` | system | `templates/provision/50-libvirt-groups.sh` | none |
| 8 | `# --- Time: chrony with makestep … (issue #187)` | system | `templates/provision/60-time.sh` | none |
| 9 | `# --- Nested-virtualization verification (issue #131)` | system | `templates/provision/70-nested-virt.sh` | none |
| 10 | `# --- Port-forward relays (issue #170)` | system | `templates/provision/80-port-forwards.sh` | none |

The `probes: - mode: readiness` block stays in the skel (Lima-specific, not extracted).

- [ ] **Step 1: Move block #1 (base tools) → `10-base.sh`**

Cut the body of the `mode: system` base-tools block (from its `#!/bin/bash` through the
final `touch /etc/vergil/provisioned.base`) into `templates/provision/10-base.sh` at
column 0, verbatim. Replace the body in the skel with `# @@INCLUDE templates/provision/10-base.sh@@`
at the original 4-space body indent.

- [ ] **Step 2: Regenerate + freshness test**

Run: `cd <worktree> && scripts/build-template.sh && bash tests/test_template_generation.sh`
Expected: PASS (byte-identical). If FAIL, the diff localizes the discrepancy — fix
indent/whitespace until empty.

- [ ] **Step 3: Commit block #1**

```bash
cd <worktree>
vrg-git add templates/provision/10-base.sh templates/agent.yaml.skel templates/agent.yaml
vrg-commit --type refactor --scope provision --message "extract base-tools block into provision/10-base.sh (#199)"
```

- [ ] **Step 4: Repeat Steps 1–3 for inventory rows #2 → #10, in order**

For each remaining row: cut the block body verbatim into the named file at column 0;
replace with the `@@INCLUDE@@` marker at the original body indent; preserve `- mode:`
(note rows #4 and #5 are `mode: user`); regenerate; confirm `test_template_generation.sh`
is green; commit with message `extract <block> into provision/<file> (#199)`. The
freshness test passing on every row is the proof the split changed nothing.

- [ ] **Step 5: Final Part-A verification — full generation is faithful**

Run: `cd <worktree> && scripts/build-template.sh && bash tests/test_template_generation.sh && vrg-git status`
Expected: PASS, and `git status` shows a clean tree (regenerated `agent.yaml` matches
the committed one). At this point `agent.yaml` is fully generated from the skel + all
provision scripts, and is byte-identical to the original pre-refactor file.

- [ ] **Step 6: Manual macOS gate — Lima box unchanged (Part A)**

On a Mac with Lima, from the worktree:

Run: `./scripts/build.sh`
Expected: the generation freshness check passes, the VM builds, `run-tests.sh` reports
`<N> tests, 0 failures`, and the `e2e-vm-profile`, `e2e-port-forwards`,
`e2e-nested-virt`, and `e2e-provision-failure` scripts all print `PASS`. (Part A is a
text-only split, so this must pass with no behavioral change.)

> If you are not on a Mac, mark this step blocked and hand off — Part B's correctness
> depends on this baseline being green first.

---

## Part B — Env-neutralization (Mac-verified)

Goal of Part B: make the scripts backend-neutral by replacing Lima templating
(`{{.User}}`, `{{.Param.*}}`) with shell variables sourced from
`/etc/vergil/provision.env`, and add manifest headers. After Part B the scripts are
ready for Phase 2 cloud-init reuse. Each Part-B task changes `agent.yaml` text (so the
freshness test still passes — it compares against the regenerated file, not the
original), and is proven behavior-identical by a Mac `build.sh` run.

### Task 4: Add the `provision.env` contract and the Lima env-writer

**Files:**
- Modify: `templates/agent.yaml.skel` (add a `mode: boot` env-writer block)
- Create: `docs/site/docs/architecture/decisions/provision-env-contract.md` (short)

**Interfaces:**
- Produces: `/etc/vergil/provision.env` on the guest — a root-owned, world-readable
  (`0644`) file of `export KEY="value"` lines, written before any `mode: system`/`user`
  script runs. Contract (exact keys): `VERGIL_USER`, `EXTRA_PACKAGES`, `APT_REPOS`,
  `VAGRANT_PLUGINS`, `NESTED_VIRT`, `PORT_FORWARDS`, `SPEC_FINGERPRINT`. Every
  param-consuming script begins with `. /etc/vergil/provision.env`. On Lima the values
  come from `{{.User}}`/`{{.Param.*}}`; on cloud (Phase 2) from tofu-templated
  cloud-init.

- [ ] **Step 1: Add the env-writer to the skel**

In `templates/agent.yaml.skel`, add as the **first** `provision:` entry (before the
logind `mode: boot` block) a new `mode: boot` block. This block keeps Lima templating
(it is the one Lima-specific shim; it is **not** an `@@INCLUDE@@`):

```yaml
- mode: boot
  # Backend-neutral provisioning contract (#199). Write /etc/vergil/provision.env
  # from Lima's template params so the extracted provision/*.sh scripts read shell
  # variables, not Lima {{...}} templating — the same scripts cloud-init drives on
  # the off-platform backend. mode:boot so it exists before any system/user script.
  script: |
    set -eu
    mkdir -p /etc/vergil
    cat > /etc/vergil/provision.env <<ENV
    export VERGIL_USER="{{.User}}"
    export EXTRA_PACKAGES="{{.Param.EXTRA_PACKAGES}}"
    export APT_REPOS="{{.Param.APT_REPOS}}"
    export VAGRANT_PLUGINS="{{.Param.VAGRANT_PLUGINS}}"
    export NESTED_VIRT="{{.Param.NESTED_VIRT}}"
    export PORT_FORWARDS="{{.Param.PORT_FORWARDS}}"
    export SPEC_FINGERPRINT="{{.Param.SPEC_FINGERPRINT}}"
    ENV
    chmod 0644 /etc/vergil/provision.env
```

- [ ] **Step 2: Regenerate and confirm the env-writer appears**

Run: `cd <worktree> && scripts/build-template.sh && bash tests/test_template_generation.sh`
Expected: FAIL (the generated `agent.yaml` now contains the new block, differing from
the committed one). This is expected for a structural addition.

- [ ] **Step 3: Accept the regenerated agent.yaml and write the decision note**

Run: `cd <worktree> && scripts/build-template.sh`
Create `docs/site/docs/architecture/decisions/provision-env-contract.md` (≤1 screen)
documenting: agent.yaml is generated; the provision.env key list above; that scripts
source it and use `$VAR`; that Lima and cloud-init each write provision.env their own
way. Re-run `bash tests/test_template_generation.sh` → PASS.

- [ ] **Step 4: Manual macOS gate — env-writer is inert so far**

On a Mac: `./scripts/build.sh`. Expected: still `0 failures` and all e2e `PASS`
(no script reads provision.env yet, so behavior is unchanged; this proves the
env-writer itself is harmless).

- [ ] **Step 5: Commit**

```bash
cd <worktree>
vrg-git add templates/agent.yaml.skel templates/agent.yaml docs/site/docs/architecture/decisions/provision-env-contract.md
vrg-commit --type feat --scope provision \
  --message "add provision.env contract and Lima env-writer (#199)" \
  --body "A mode:boot shim writes /etc/vergil/provision.env from Lima template params. Scripts are converted to read it in the next tasks. Inert until then; build.sh stays green."
```

### Task 5: Neutralize templating in the param-consuming scripts

Convert each script that still contains `{{.User}}`/`{{.Param.*}}` to source
`provision.env` and use shell variables. Apply the **exact substitutions** below.
Scripts not listed (`00-logind-fix.sh`, `20-minimize.sh`, `30-toolchain.sh`,
`35-buildkit.sh`) contain no Lima templating and are unchanged in this task.

**Substitution table** (replace every occurrence):

| Script | Replace | With |
|---|---|---|
| `10-base.sh` | `"{{.User}}"` | `"$VERGIL_USER"` |
| `15-environment.sh` | `"{{.User}}"` | `"$VERGIL_USER"` |
| `40-profile.sh` | `{{.Param.SPEC_FINGERPRINT}}`, `{{.Param.APT_REPOS}}`, `{{.Param.EXTRA_PACKAGES}}`, `{{.Param.VAGRANT_PLUGINS}}`, `"{{.User}}"` | `$SPEC_FINGERPRINT`, `$APT_REPOS`, `$EXTRA_PACKAGES`, `$VAGRANT_PLUGINS`, `"$VERGIL_USER"` |
| `50-libvirt-groups.sh` | `{{.Param.EXTRA_PACKAGES}}`, `{{.Param.VAGRANT_PLUGINS}}`, `{{.Param.NESTED_VIRT}}`, `"{{.User}}"` | `$EXTRA_PACKAGES`, `$VAGRANT_PLUGINS`, `$NESTED_VIRT`, `"$VERGIL_USER"` |
| `60-time.sh` | `{{.Param.EXTRA_PACKAGES}}`, `{{.Param.VAGRANT_PLUGINS}}`, `{{.Param.NESTED_VIRT}}` | `$EXTRA_PACKAGES`, `$VAGRANT_PLUGINS`, `$NESTED_VIRT` |
| `70-nested-virt.sh` | `{{.Param.NESTED_VIRT}}` | `$NESTED_VIRT` |
| `80-port-forwards.sh` | `{{.Param.PORT_FORWARDS}}` | `$PORT_FORWARDS` |

In every script in the table, insert **as the first executable line after the
`#!/bin/bash` + `set -…` lines**:

```bash
# Backend-neutral inputs (#199): Lima/cloud each write this file their own way.
. /etc/vergil/provision.env
```

> The existing scripts already assign each param to a local (e.g.
> `PKGS="{{.Param.EXTRA_PACKAGES}}"` → after substitution `PKGS="$EXTRA_PACKAGES"`),
> so downstream uses (`$PKGS`, including the intentional unquoted word-split in
> `apt-get install $PKGS`) are unchanged.

- [ ] **Step 1: Convert `10-base.sh` and `15-environment.sh`**

Apply the table rows + the `. /etc/vergil/provision.env` source line to both files.

- [ ] **Step 2: Regenerate + freshness + shellcheck**

Run: `cd <worktree> && scripts/build-template.sh && bash tests/test_template_generation.sh`
Expected: PASS (committed agent.yaml matches regeneration).
Run validation (shellcheck of the scripts is part of it):
Run: `vrg-container-run -- vrg-validate`
Expected: passes (no shellcheck regressions; `$VERGIL_USER` is a normal var ref).

- [ ] **Step 3: Convert the remaining table scripts**

Apply the table rows + source line to `40-profile.sh`, `50-libvirt-groups.sh`,
`60-time.sh`, `70-nested-virt.sh`, `80-port-forwards.sh`. Regenerate after each and
keep `test_template_generation.sh` green.

- [ ] **Step 4: Manual macOS gate — behavior identical via provision.env**

On a Mac: `./scripts/build.sh`.
Expected: `run-tests.sh` → `0 failures`; `e2e-vm-profile` PASS (proves
`SPEC_FINGERPRINT`/`APT_REPOS`/`EXTRA_PACKAGES` still flow — it sets those params and
asserts the keyring, the `cowsay` package, the fingerprint marker `testfp123`, and
libvirt/kvm groups); `e2e-nested-virt` PASS (proves `NESTED_VIRT`); `e2e-port-forwards`
PASS (proves `PORT_FORWARDS`); `e2e-provision-failure` PASS (proves the loud-failure
path through the profile block). This is the core proof that env-sourcing reproduces
Lima templating exactly.

- [ ] **Step 5: Commit**

```bash
cd <worktree>
vrg-git add templates/provision/10-base.sh templates/provision/15-environment.sh \
  templates/provision/40-profile.sh templates/provision/50-libvirt-groups.sh \
  templates/provision/60-time.sh templates/provision/70-nested-virt.sh \
  templates/provision/80-port-forwards.sh templates/agent.yaml
vrg-commit --type refactor --scope provision \
  --message "source provision.env instead of Lima templating in provision scripts (#199)" \
  --body "Replace {{.User}}/{{.Param.*}} with shell vars sourced from /etc/vergil/provision.env across the param-consuming scripts. Scripts are now backend-neutral and ready for cloud-init reuse (Phase 2). Verified behavior-identical on Lima via scripts/build.sh (run-tests + full e2e suite green)."
```

### Task 6: Add manifest headers and the manifest-validation test

Give every script a machine-readable `# vergil-provision:` manifest declaring its
`context` and `cadence`, and add a host-side test that validates the manifests and
their consistency with the skel's Lima `mode:`.

**Files:**
- Modify: every `templates/provision/*.sh` (prepend manifest line)
- Create: `tests/test_provision_manifest.sh`

**Interfaces:**
- Produces: a manifest line as the **second line** of each script (after `#!/bin/bash`):
  `# vergil-provision: context=<root|user> cadence=<once|boot>[ guard=<marker>]`. Used
  by Phase 2 cloud-init generation to pick `runcmd` vs `sudo -iu` and document cadence.

Manifest values per script (matches the Task 3 inventory):

| Script | context | cadence | guard |
|---|---|---|---|
| `00-logind-fix.sh` | root | boot | — |
| `10-base.sh` | root | once | provisioned.base |
| `15-environment.sh` | root | boot | — |
| `20-minimize.sh` | root | boot | — |
| `30-toolchain.sh` | user | once | provisioned.uv |
| `35-buildkit.sh` | user | boot | — |
| `40-profile.sh` | root | once | provisioned.profile |
| `50-libvirt-groups.sh` | root | boot | — |
| `60-time.sh` | root | boot | — |
| `70-nested-virt.sh` | root | boot | — |
| `80-port-forwards.sh` | root | boot | — |

- [ ] **Step 1: Write the failing manifest test**

Create `tests/test_provision_manifest.sh`:

```bash
#!/usr/bin/env bash
# tests/test_provision_manifest.sh — Validate every templates/provision/*.sh has a
# well-formed `# vergil-provision:` manifest, and that the skeleton's Lima mode for
# each include is consistent with the script's declared context (root->system/boot,
# user->user). HOST-side; runs in CI. Not named test_*.sh (no guest pipe).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

for s in "${ROOT}"/templates/provision/*.sh; do
  base="$(basename "$s")"
  m="$(sed -n '2p' "$s")"
  case "$m" in
    "# vergil-provision: "*) : ;;
    *) fail "${base}: missing or misplaced manifest on line 2 (got: ${m})" ;;
  esac
  echo "$m" | grep -Eq 'context=(root|user)' || fail "${base}: bad/absent context"
  echo "$m" | grep -Eq 'cadence=(once|boot)'  || fail "${base}: bad/absent cadence"
  # A 'once' script must name a guard; a 'boot' script must not.
  if echo "$m" | grep -q 'cadence=once'; then
    echo "$m" | grep -q 'guard=' || fail "${base}: cadence=once requires a guard="
  fi
done

# Consistency: a user-context script must be included under a `- mode: user` entry in
# the skel; a root-context script under `- mode: system` or `- mode: boot`.
skel="${ROOT}/templates/agent.yaml.skel"
while IFS= read -r incpath; do
  base="$(basename "$incpath")"
  ctx="$(sed -n '2p' "${ROOT}/${incpath}" | grep -oE 'context=(root|user)' | cut -d= -f2)"
  # The nearest preceding `- mode:` line before this include marker.
  mode="$(awk -v marker="@@INCLUDE ${incpath}@@" '
    /- mode:/ { m=$0 }
    index($0, marker) { print m; exit }' "$skel" | grep -oE 'mode: (system|user|boot)' | awk '{print $2}')"
  case "$ctx:$mode" in
    root:system|root:boot|user:user) : ;;
    *) fail "${base}: context=${ctx} but skel mode=${mode} (inconsistent)" ;;
  esac
done < <(grep -oE 'templates/provision/[^@ ]+\.sh' "$skel")

echo "PASS: all provision manifests valid and consistent with skeleton modes"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd <worktree> && bash tests/test_provision_manifest.sh`
Expected: FAIL — `… missing or misplaced manifest on line 2` (no headers yet).

- [ ] **Step 3: Add the manifest line to every script**

For each script, insert the manifest as line 2 (immediately after `#!/bin/bash`), per
the table. Example for `10-base.sh`:

```bash
#!/bin/bash
# vergil-provision: context=root cadence=once guard=provisioned.base
```

For `00-logind-fix.sh`, which currently starts with `set -eu` and no shebang, add both
the shebang and the manifest as the first two lines:

```bash
#!/bin/bash
# vergil-provision: context=root cadence=boot
set -eu
```

> Adding the shebang to `00-logind-fix.sh` changes the generated agent.yaml body for
> that block (an extra `#!/bin/bash` line). That is a benign, intentional change — the
> body is executed by `bash` either way. Regeneration + the Mac gate below confirm it.

- [ ] **Step 4: Regenerate, freshness, manifest test, validate**

Run: `cd <worktree> && scripts/build-template.sh && bash tests/test_template_generation.sh && bash tests/test_provision_manifest.sh`
Expected: both PASS.
Run: `vrg-container-run -- vrg-validate` → passes.

- [ ] **Step 5: Manual macOS gate — final Part-B proof**

On a Mac: `./scripts/build.sh`. Expected: `0 failures` and every e2e `PASS`.

- [ ] **Step 6: Commit**

```bash
cd <worktree>
vrg-git add templates/provision/*.sh templates/agent.yaml tests/test_provision_manifest.sh
vrg-commit --type feat --scope provision \
  --message "add provision script manifests and validation test (#199)" \
  --body "Each provision/*.sh declares context+cadence(+guard) in a # vergil-provision: header; test_provision_manifest.sh validates them and their consistency with the skeleton's Lima modes. These manifests drive Phase 2 cloud-init generation (runcmd vs sudo -iu)."
```

### Task 7: Documentation + final sweep

**Files:**
- Modify: `docs/site/docs/architecture/index.md` (or the most relevant page) — a short
  "Provisioning is generated" note and the edit-the-scripts-not-agent.yaml rule.
- Modify: `CHANGELOG.md` — add the entry under the current unreleased section following
  the existing format.

- [ ] **Step 1: Add the docs note**

Add a short subsection: `templates/agent.yaml` is generated by
`scripts/build-template.sh` from `templates/agent.yaml.skel` + `templates/provision/*.sh`;
edit the scripts/skeleton and regenerate; CI fails on a stale `agent.yaml`; the scripts
are backend-neutral (read `/etc/vergil/provision.env`) so the off-platform backend
(#199 Phase 2) reuses them.

- [ ] **Step 2: Add the changelog entry**

Match the existing `CHANGELOG.md` style; one line, e.g.:
`- Extract VM provisioning into backend-neutral templates/provision/*.sh, with templates/agent.yaml now generated by scripts/build-template.sh (#199).`

- [ ] **Step 3: Validate + freshness + manifest, all green**

Run: `cd <worktree> && bash tests/test_template_generation.sh && bash tests/test_provision_manifest.sh && vrg-container-run -- vrg-validate`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
cd <worktree>
vrg-git add docs/site/docs/architecture/index.md CHANGELOG.md
vrg-commit --type docs --scope provision --message "document generated agent.yaml and provision scripts (#199)"
```

---

## Self-review notes (coverage against the spec's "Provisioning extraction" section)

- **Context + cadence + readiness contract** → manifests (Task 6) + the readiness probe
  retained in the skel; the cloud readiness *synthesis* is Phase 2 (cloud-init), not
  this plan.
- **Real block inventory incl. the `mode: user` uv/vergil-tooling install** → Task 3
  row #4 (`30-toolchain.sh`). (Note: the in-VM `vergil-tooling` install proper is done
  at credential-injection time by `vrg-vm-init.sh`, not here; `30-toolchain.sh`
  installs `uv` and the shell/identity config, matching today's block.)
- **Three first-boot guards** → preserved verbatim in `10-base.sh` / `30-toolchain.sh`
  / `40-profile.sh`; asserted by the manifest test's `cadence=once ⇒ guard=` rule.
- **Single source of truth, both backends** → `provision/*.sh` is canonical; Lima via
  the generator, cloud-init via Phase 2; the freshness test guards drift.
- **Lima behavior unchanged** → Part A byte-identity (CI) + Part B Mac `build.sh`
  (run-tests + full e2e) at Tasks 3/5/6.

## Out of scope (this plan)

- Cloud-init, OpenTofu, any `gcp`/`azure` module — Phase 2 (`…-plan-2-gcp-module.md`).
- `vrg-vm` backend dispatch, SSH session, cred injection on a remote peer —
  vergil-tooling #1706.
