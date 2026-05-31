# VM Service-Surface Minimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Strip the agent VM's systemd service surface to the smallest viable footprint by masking unneeded units and purging dead-weight packages in `templates/agent.yaml`, with a regression test that locks the result and a before/after metrics snapshot that quantifies the win.

**Architecture:** Mask-by-default (reversible, resists dependency pull-in) plus a curated `apt-get purge` of unambiguous dead weight, added as one dedicated `mode: system` provision block. A shared in-guest inventory snippet feeds two host-side wrapper scripts (`audit-services.sh` for the qualitative lists, `vm-metrics.sh` for the quantitative footprint). An auto-discovered `tests/test_services.sh` asserts intent — specific units masked/absent, load-bearing units up. The exact mask/purge lists are reconciled against a real build before the template changes land. The in-VM netfilter/networking path is preserved for future egress filtering (vergil-tooling #901).

**Tech Stack:** Lima YAML, Bash, systemd (`systemctl`, `systemd-analyze`), `limactl`, `apt-get`.

**Spec:** `docs/specs/2026-05-31-vm-service-surface-minimization-design.md`

**Worktree:** All work happens in `.worktrees/issue-78-minimize-vm-surface/` on branch `feature/78-minimize-vm-surface`. `scripts/build.sh` derives its repo root from its own location, so building from inside the worktree builds the worktree's template. Use `vrg-git` / `vrg-commit` for all git operations.

**Build/test reality:** `./scripts/build.sh --keep` creates the Lima instance `vergil-agent-test` from `templates/agent.yaml` (defaults: `cpus: 4`, `memory: 4GiB`, `disk: 50GiB` — only the mount is overridden, so before/after **resource-config parity is automatic**), then runs `tests/run-tests.sh vergil-agent-test`. `run-tests.sh` auto-discovers every `tests/test_*.sh` and pipes it into the guest via `limactl shell ... -- bash -s`. Building a VM takes minutes (provisioning timeout is 30m); the long steps are flagged.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `tests/lib/inventory.sh` | Create | Shared in-guest inventory/counting functions (single source of "how we count the surface"). Functions only, no top-level execution. |
| `scripts/audit-services.sh` | Create | Host-side wrapper: pipe the shared snippet into the VM and dump the qualitative unit lists. |
| `scripts/vm-metrics.sh` | Create | Host-side wrapper: labeled before/after footprint snapshot; records VM resource config in the header. |
| `tests/test_services.sh` | Create | Intent assertions (denylist masked/absent, allowlist up). Auto-discovered by the `test_*.sh` glob. |
| `templates/agent.yaml` | Modify | New `mode: system` minimization block (mask list + curated purge), comment header carrying the keep/mask/purge table. |
| `docs/specs/2026-05-31-vm-service-surface-minimization-design.md` | Modify | One-line Execution-model accuracy fix (Task 1). |
| `CHANGELOG.md` | Modify | Record the change (Task 8). |

---

## Task 0: Reconciliation gate — baseline build + confirm the real inventory

The spec's keep/mask/purge table is a *candidate* grounded in known Ubuntu 24.04
defaults. Before writing any masks, confirm against a real build which candidate
units actually exist and are unused. This task produces the **confirmed lists** that
Tasks 5 and 6 consume. It needs the tooling from Tasks 1–3, so **do Tasks 1–3 first,
then return here.** (It is Task 0 because its *output* gates 5 and 6.)

- [ ] **Step 1: Build the current, unmodified VM and keep it running**

This is the **before** image — the template has no minimization block yet.

Run (long, up to 30m):

```bash
./scripts/build.sh --keep
```

Expected: `=== Build complete ===` and the existing test suite passes. The instance
`vergil-agent-test` stays running.

- [ ] **Step 2: Capture the baseline footprint (before)**

```bash
./scripts/vm-metrics.sh before vergil-agent-test | tee /tmp/vm-metrics-before.txt
```

Expected: a `=== vm-metrics [before] ===` block listing the config and the metric
key=values. Keep this file — it is half the win story.

- [ ] **Step 3: Capture the qualitative inventory**

```bash
./scripts/audit-services.sh vergil-agent-test | tee /tmp/vm-audit-before.txt
```

Expected: `### running services`, `### enabled unit files`, `### timers`,
`### sockets`, `### systemd-analyze blame`, `### critical-chain` sections.

- [ ] **Step 4: Reconcile the candidate list against reality**

Open `/tmp/vm-audit-before.txt`. For each MASK/PURGE candidate in the spec table,
confirm it is present and genuinely unused. Apply the classification rule (keep only
if required for SSH-in, rootless containerd, cloud-init per-boot, DNS/time, or the
gh/uv/claude toolchain). Honor the namespace rules: **never** mark `lima-*` or
`netfilter*`/`iptables*`/`nftables*` units for masking.

Write the **confirmed lists** into the issue and carry them to Tasks 5 and 6:

- `CONFIRMED_MASK` — units present and unused (start from: `multipathd.service`,
  `ModemManager.service`, `getty@tty1.service`, `systemd-networkd-wait-online.service`,
  `apt-daily.timer`, `apt-daily-upgrade.timer`, `motd-news.timer`, `motd-news.service`;
  plus any of `avahi-daemon`, `cups`, `bluetooth`, `packagekit`,
  `power-profiles-daemon`, `thermald`, `switcheroo-control`, `accounts-daemon` found
  present). Drop any not present; add any newly-found unused defaults.
- `CONFIRMED_PURGE` — packages present and dead weight (start from: `snapd`,
  `unattended-upgrades`; add `modemmanager` only if installed as a package).

- [ ] **Step 5: Post the baseline to the issue**

```bash
vrg-gh issue comment 78 --body-file /tmp/vm-metrics-before.txt
```

Expected: comment URL printed. (Attach the audit too if useful.)

---

## Task 1: Shared in-guest inventory snippet

**Files:**
- Create: `tests/lib/inventory.sh`
- Modify: `docs/specs/2026-05-31-vm-service-surface-minimization-design.md`

- [ ] **Step 1: Write the inventory library**

Create `tests/lib/inventory.sh`:

```bash
#!/bin/bash
# tests/lib/inventory.sh — Shared in-guest inventory/counting core.
#
# Functions only, NO top-level execution. The host-side wrappers
# (scripts/audit-services.sh, scripts/vm-metrics.sh) concatenate this file
# with a single trailing function call and pipe it into the guest via
# `limactl shell <instance> -- bash -s`. One definition of "how we count the
# surface" so the two wrappers cannot disagree.
#
# grep -c exits 1 on zero matches; `|| true` keeps the captured "0" and
# prevents `set -o pipefail` in the caller from aborting.

inv_services_running() { systemctl list-units --type=service --state=running --no-legend --no-pager | grep -c '\.service' || true; }
inv_units_enabled()    { systemctl list-unit-files --state=enabled --no-legend --no-pager | grep -c . || true; }
inv_timers()           { systemctl list-timers --all --no-legend --no-pager | grep -c '\.timer' || true; }
inv_sockets()          { systemctl list-sockets --no-legend --no-pager | grep -c '\.socket' || true; }
inv_proc_count()       { ps -e --no-headers | wc -l; }
inv_mem_used_kb()      { awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t-a}' /proc/meminfo; }
inv_rootfs()           { df -P / | awk 'NR==2{print "used_kb="$3" avail_kb="$4}'; }
inv_boot_time()        { systemd-analyze time 2>/dev/null | head -n1; }

# Compact quantitative snapshot (consumed by vm-metrics.sh).
inv_metrics_block() {
    echo "services_running=$(inv_services_running)"
    echo "units_enabled=$(inv_units_enabled)"
    echo "timers=$(inv_timers)"
    echo "sockets=$(inv_sockets)"
    echo "processes=$(inv_proc_count)"
    echo "mem_used_kb=$(inv_mem_used_kb)"
    echo "rootfs: $(inv_rootfs)"
    echo "boot: $(inv_boot_time)"
}

# Full qualitative dump (consumed by audit-services.sh).
inv_dump_lists() {
    echo "### running services";      systemctl list-units --type=service --state=running --no-pager
    echo "### enabled unit files";    systemctl list-unit-files --state=enabled --no-pager
    echo "### timers";                systemctl list-timers --all --no-pager
    echo "### sockets";               systemctl list-sockets --no-pager
    echo "### systemd-analyze blame"; systemd-analyze blame --no-pager 2>/dev/null || true
    echo "### critical-chain";        systemd-analyze critical-chain --no-pager 2>/dev/null || true
}
```

- [ ] **Step 2: Verify the library sources cleanly and defines its functions**

Run (on the host — this only checks shape, not VM values):

```bash
bash -c 'source tests/lib/inventory.sh && type inv_metrics_block inv_dump_lists >/dev/null && echo OK'
```

Expected: `OK`.

- [ ] **Step 3: Correct the spec's Execution-model wording to match reality**

The shared snippet is used by the two host-side wrappers; `test_services.sh` asserts
unit *states* (a different operation) and does not need the counting core. In
`docs/specs/2026-05-31-vm-service-surface-minimization-design.md`, find:

```
host-side wrappers that run that snippet via `limactl shell <instance> -- bash -s`;
`test_services.sh` sources/embeds the same snippet for its counts. One definition of
"how we count the surface," three consumers — so they cannot disagree.
```

Replace with:

```
host-side wrappers that run that snippet via `limactl shell <instance> -- bash -s`.
`test_services.sh` asserts unit *states* (masked / active) rather than counts, so it
stands alone — but the two scripts that *do* count the surface share one definition,
so they cannot disagree.
```

- [ ] **Step 4: Validate and commit**

```bash
vrg-container-run -- vrg-validate
vrg-git add tests/lib/inventory.sh docs/specs/2026-05-31-vm-service-surface-minimization-design.md
vrg-commit --type feat --scope audit \
  --message "add shared in-guest inventory snippet" \
  --body "Single source of truth for counting/dumping the systemd surface, consumed by the audit and metrics wrappers. Corrects the spec execution model: the test asserts unit states, not counts."
```

Expected: validation passes; commit created.

---

## Task 2: `audit-services.sh` host-side wrapper

**Files:**
- Create: `scripts/audit-services.sh`

- [ ] **Step 1: Write the wrapper**

Create `scripts/audit-services.sh`:

```bash
#!/bin/bash
# scripts/audit-services.sh — Dump the VM's systemd inventory (qualitative).
#
# Host-side wrapper: concatenates the shared in-guest snippet with a call to
# inv_dump_lists and pipes it into the VM. Output is paste-ready for issue #78
# and the first diagnostic when something later breaks.
#
# Usage: ./scripts/audit-services.sh [instance]   (default: vergil-agent-test)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="${SCRIPT_DIR}/../tests/lib/inventory.sh"
INSTANCE="${1:-vergil-agent-test}"

{ cat "$LIB"; echo 'inv_dump_lists'; } | limactl shell "$INSTANCE" -- bash -s
```

- [ ] **Step 2: Make it executable and verify it parses**

```bash
chmod +x scripts/audit-services.sh
bash -n scripts/audit-services.sh && echo OK
```

Expected: `OK`. (A live run happens in Task 0 Step 3, against the built VM.)

- [ ] **Step 3: Validate and commit**

```bash
vrg-container-run -- vrg-validate
vrg-git add scripts/audit-services.sh
vrg-commit --type feat --scope audit \
  --message "add audit-services.sh inventory dump" \
  --body "Host-side wrapper over the shared in-guest snippet; dumps running services, enabled units, timers, sockets, and boot analysis."
```

---

## Task 3: `vm-metrics.sh` host-side wrapper

**Files:**
- Create: `scripts/vm-metrics.sh`

- [ ] **Step 1: Write the wrapper**

Create `scripts/vm-metrics.sh`:

```bash
#!/bin/bash
# scripts/vm-metrics.sh — Labeled before/after footprint snapshot.
#
# Host-side wrapper. Records the VM's resource config in the header so
# before/after parity is self-evident on the face of the snapshot.
#
# Usage: ./scripts/vm-metrics.sh <before|after> [instance]
#   (default instance: vergil-agent-test)
set -euo pipefail

LABEL="${1:?Usage: vm-metrics.sh <before|after> [instance]}"
INSTANCE="${2:-vergil-agent-test}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="${SCRIPT_DIR}/../tests/lib/inventory.sh"

# Resource config (parity check) — Lima reports memory/disk in bytes.
cfg=$(limactl list --json "$INSTANCE" \
  | jq -r '"cpus=\(.cpus) memory_bytes=\(.memory) disk_bytes=\(.disk)"')

echo "=== vm-metrics [$LABEL] ==="
echo "instance=$INSTANCE"
echo "config: $cfg"
echo "---"
{ cat "$LIB"; echo 'inv_metrics_block'; } | limactl shell "$INSTANCE" -- bash -s
echo "=== end [$LABEL] ==="
```

- [ ] **Step 2: Make it executable and verify it parses**

```bash
chmod +x scripts/vm-metrics.sh
bash -n scripts/vm-metrics.sh && echo OK
```

Expected: `OK`. (A live run happens in Task 0 Step 2.)

- [ ] **Step 3: Validate and commit**

```bash
vrg-container-run -- vrg-validate
vrg-git add scripts/vm-metrics.sh
vrg-commit --type feat --scope metrics \
  --message "add vm-metrics.sh footprint snapshot" \
  --body "Host-side wrapper; labeled before/after footprint (proc count, idle memory, root-fs usage, unit counts) with resource config recorded in the header for parity."
```

> After Tasks 1–3 are committed, go do **Task 0** (baseline build + reconciliation),
> then return for Task 4.

---

## Task 4: Regression test — `tests/test_services.sh` (TDD red)

**Files:**
- Create: `tests/test_services.sh`

Use the `CONFIRMED_MASK` / `CONFIRMED_PURGE` lists from Task 0. The lists below are
the candidate starting point; **adjust the two `for` loops to match exactly what
Task 6 will mask/purge** — the test and the template share one list.

- [ ] **Step 1: Write the test**

Create `tests/test_services.sh`:

```bash
#!/bin/bash
# tests/test_services.sh — Assert the minimized service surface (intent, not snapshot).
#
# Auto-discovered by run-tests.sh; runs in-guest. Two assertion sets:
#   denylist  — each unit masked / each package purged
#   allowlist — load-bearing units up, toolchain resolves
# NOT `set -e`: run every assertion, then report. Exit 1 if any failed.
set -uo pipefail
fail=0

assert_masked() {
    local unit="$1" state
    state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    if [ "$state" = "masked" ]; then
        echo "  PASS: $unit masked"
    else
        echo "  FAIL: $unit expected masked, got '${state:-absent}'"
        fail=1
    fi
}

assert_purged() {
    local pkg="$1"
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
        echo "  FAIL: package $pkg expected purged, still installed"
        fail=1
    else
        echo "  PASS: package $pkg absent"
    fi
}

assert_active() {            # assert_active <unit> [user]
    local unit="$1" scope="${2:-system}"
    if [ "$scope" = "user" ]; then
        if systemctl --user is-active --quiet "$unit"; then
            echo "  PASS: (user) $unit active"
        else
            echo "  FAIL: (user) $unit not active"; fail=1
        fi
    else
        if systemctl is-active --quiet "$unit"; then
            echo "  PASS: $unit active"
        else
            echo "  FAIL: $unit not active"; fail=1
        fi
    fi
}

assert_command() {
    local c="$1"
    if command -v "$c" >/dev/null 2>&1; then
        echo "  PASS: $c resolves"
    else
        echo "  FAIL: $c missing"; fail=1
    fi
}

echo "== Denylist: must be masked =="
for u in \
    multipathd.service \
    ModemManager.service \
    getty@tty1.service \
    systemd-networkd-wait-online.service \
    apt-daily.timer \
    apt-daily-upgrade.timer \
    motd-news.timer \
    motd-news.service \
    ; do
    assert_masked "$u"
done

echo "== Denylist: must be purged =="
for p in snapd unattended-upgrades; do
    assert_purged "$p"
done

echo "== Allowlist: load-bearing must be up =="
assert_active ssh
assert_active systemd-resolved
assert_active systemd-networkd
assert_active containerd user
for c in gh uv claude; do
    assert_command "$c"
done

if [ "$fail" -ne 0 ]; then
    echo "test_services: FAIL"
    exit 1
fi
echo "test_services: all checks passed"
```

- [ ] **Step 2: Run the test against the current (unstripped) VM — expect RED**

The `vergil-agent-test` instance from Task 0 is still running and has **not** been
stripped, so the denylist must fail.

Run:

```bash
limactl shell vergil-agent-test -- bash -s < tests/test_services.sh; echo "exit=$?"
```

Expected: multiple `FAIL: ... expected masked` / `expected purged` lines, final
`test_services: FAIL`, `exit=1`. The allowlist lines should already PASS. This
confirms the test actually detects the unstripped state (a meaningful red).

- [ ] **Step 3: Validate and commit**

```bash
vrg-container-run -- vrg-validate
vrg-git add tests/test_services.sh
vrg-commit --type test --scope services \
  --message "add service-surface regression test" \
  --body "Asserts intent (denylist masked/purged, allowlist up) rather than a golden snapshot. Currently red against the unstripped image; goes green once the template strips the surface."
```

---

## Task 5: Minimization block in `templates/agent.yaml` (TDD green)

**Files:**
- Modify: `templates/agent.yaml`

Mask list and purge list **must match Task 4's denylist exactly** (the reconciled
`CONFIRMED_MASK` / `CONFIRMED_PURGE`).

- [ ] **Step 1: Append the minimization block**

Add this block to `templates/agent.yaml` in the `provision:` list, immediately
**after** the existing tool-install `mode: system` block and **before** the
`mode: user` block:

```yaml
  # --- Service-surface minimization (issue #78) -------------------------
  # Strip the general-purpose Ubuntu default service set down to what this
  # special-purpose agent VM needs. Mask-by-default (reversible, resists
  # dependency pull-in) + a curated purge of dead-weight packages.
  #
  # KEEP (load-bearing — never mask): ssh, lima-* (limactl access),
  #   containerd (user), cloud-init* (per-boot logind fix), dbus, journald,
  #   resolved, timesyncd, networkd/netplan, serial-getty, polkit, and ALL
  #   netfilter*/iptables*/nftables* units (reserved for egress filtering —
  #   vergil-tooling #901).
  # MASK: multipathd, ModemManager, getty@tty1, systemd-networkd-wait-online,
  #   apt-daily{,-upgrade}.timer, motd-news.{timer,service}.
  # PURGE: snapd, unattended-upgrades.
  # See docs/specs/2026-05-31-vm-service-surface-minimization-design.md.
  - mode: system
    script: |
      #!/bin/bash
      set -eux -o pipefail
      export DEBIAN_FRONTEND=noninteractive

      # MASK — unneeded units. mask is idempotent and safe even if a unit is
      # absent; `systemctl cat` gates so we don't create dead /dev/null links
      # for units this image doesn't ship.
      mask_if_present() {
        local u
        for u in "$@"; do
          if systemctl cat "$u" >/dev/null 2>&1; then
            systemctl mask "$u" || true
          fi
        done
      }

      mask_if_present \
        multipathd.service \
        ModemManager.service \
        getty@tty1.service \
        systemd-networkd-wait-online.service \
        apt-daily.timer apt-daily-upgrade.timer \
        motd-news.timer motd-news.service

      # PURGE — curated dead weight. Stop snapd first so purge is clean.
      systemctl stop snapd.socket snapd.service 2>/dev/null || true
      apt-get purge -y snapd unattended-upgrades 2>/dev/null || true
      apt-get autoremove -y --purge 2>/dev/null || true
```

- [ ] **Step 2: Validate the template syntax**

```bash
limactl validate templates/agent.yaml && echo "template valid"
```

Expected: `template valid`. (If `limactl` is unavailable on the host, run
`vrg-container-run -- vrg-validate`, which also lints the template.)

- [ ] **Step 3: Commit**

```bash
vrg-git add templates/agent.yaml
vrg-commit --type feat --scope template \
  --message "minimize systemd service surface" \
  --body "Dedicated mode:system block masks unneeded units (multipathd, ModemManager, getty@tty1, networkd-wait-online, apt-daily/motd-news timers) and purges snapd + unattended-upgrades. Comment header carries the keep/mask/purge table; reserves lima-* and netfilter* units. Closes the surface #74 warned about."
```

---

## Task 6: Rebuild, verify green, capture after

**Files:** none (build + verification)

- [ ] **Step 1: Tear down the before instance**

```bash
limactl stop vergil-agent-test 2>/dev/null || true
limactl delete --force vergil-agent-test 2>/dev/null || true
```

- [ ] **Step 2: Rebuild from the stripped template and run the full suite**

Run (long, up to 30m). `build.sh` runs `run-tests.sh`, which now includes
`test_services.sh`:

```bash
./scripts/build.sh --keep
```

Expected: `=== Build complete ===`. In the test output, `test_services.sh` is
**PASS**, and every pre-existing test (`test_base`, `test_containerd`, `test_ssh`,
`test_tools`, `test_vergil`, `test_credentials`) is still **PASS**. This is the TDD
green: the same test that was red in Task 4 Step 2 now passes.

- [ ] **Step 3: Confirm the readiness probe and a real Claude Code session**

```bash
limactl shell vergil-agent-test -- bash -lc 'command -v gh && command -v uv && command -v claude && systemctl --user is-active containerd'
limactl shell vergil-agent-test --workdir /projects -- claude --version
```

Expected: all four tools resolve, containerd `active`, and `claude --version` prints
a version — proving the stripped image still works end to end.

- [ ] **Step 4: Capture the after footprint**

```bash
./scripts/vm-metrics.sh after vergil-agent-test | tee /tmp/vm-metrics-after.txt
```

Expected: `=== vm-metrics [after] ===` with the **same config line** as the before
snapshot (parity) and lower `services_running` / `timers` / `processes` counts.

---

## Task 7: Evidence, changelog, finalize

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Post the before/after comparison to the issue**

```bash
{ echo '## Before/after footprint'; echo '```'; \
  cat /tmp/vm-metrics-before.txt; echo; cat /tmp/vm-metrics-after.txt; echo '```'; } \
  > /tmp/vm-metrics-compare.txt
vrg-gh issue comment 78 --body-file /tmp/vm-metrics-compare.txt
```

Expected: comment URL printed. The deterministic drop in `services_running` /
`timers` / `sockets` is the acceptance evidence; process/memory/disk deltas are the
win story.

- [ ] **Step 2: Add a CHANGELOG entry**

In `CHANGELOG.md`, under a new `## [Unreleased]` section (or the current unreleased
section if one exists), add:

```markdown
### Changed

- minimize the VM systemd service surface — mask unneeded units
  (multipathd, ModemManager, getty@tty1, networkd-wait-online,
  apt-daily/motd-news timers) and purge snapd + unattended-upgrades,
  with a regression test and before/after footprint metrics
```

- [ ] **Step 3: Mark the spec implemented**

In `docs/specs/2026-05-31-vm-service-surface-minimization-design.md`, change the
status line:

```
**Status:** Design approved; ready for implementation planning.
```

to:

```
**Status:** Implemented (issue #78).
```

- [ ] **Step 4: Commit**

```bash
vrg-git add CHANGELOG.md docs/specs/2026-05-31-vm-service-surface-minimization-design.md
vrg-commit --type docs --scope changelog \
  --message "record service-surface minimization" \
  --body "CHANGELOG entry and spec status update for issue #78."
```

- [ ] **Step 5: Tear down the test VM**

```bash
limactl stop vergil-agent-test 2>/dev/null || true
limactl delete --force vergil-agent-test 2>/dev/null || true
```

- [ ] **Step 6: Open the PR**

Use the `vergil:pr-workflow` skill (runs from inside this worktree) to push
`feature/78-minimize-vm-surface`, wait for CI, and hand off for review.

---

## Self-Review

- **Spec coverage:**
  - Audit methodology / inventory commands → Task 1 (`inventory.sh`), Task 0 Step 3.
  - Mask-default + curated purge → Task 5.
  - Candidate table reconciled against a real build → Task 0 Step 4.
  - `tests/test_services.sh` intent assertions, auto-discovered → Task 4, Task 6 Step 2.
  - `audit-services.sh` / `vm-metrics.sh` host wrappers over shared snippet → Tasks 2, 3.
  - Before/after metrics, resource-config parity, baseline-first sequencing → Task 0 Steps 1–2, Task 6 Step 4 (parity automatic via `build.sh` defaults).
  - Gate on service/timer/socket drop; boot time as evidence → Task 7 Step 1.
  - KEEP lima-* and netfilter*/iptables*/nftables* (egress reservation) → Task 0 Step 4 rule, Task 5 comment header + `mask_if_present` list omits them.
  - Readiness probe + real Claude session still work → Task 6 Step 3.
- **Placeholder scan:** No TBD/TODO. The "reconcile / adjust to match CONFIRMED list"
  instructions are concrete verification actions with explicit starting content, not
  deferred work.
- **Type consistency:** Function names (`inv_*`, `assert_masked`, `assert_purged`,
  `assert_active`, `mask_if_present`) are used identically across the lib, the test,
  and the template. The mask/purge lists in Task 4 (test) and Task 5 (template) are
  the same set, both derived from Task 0's `CONFIRMED_MASK`/`CONFIRMED_PURGE`.
