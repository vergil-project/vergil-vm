# VM Service-Surface Minimization Design

**Issues:**
- [vergil-vm #78 — Audit and minimize VM service surface: strip the agent image to smallest viable footprint](https://github.com/vergil-project/vergil-vm/issues/78)

**Date:** 2026-05-31

**Status:** Design approved; ready for implementation planning.

**Builds on:** [#74 logind/VT busy-loop fix](https://github.com/vergil-project/vergil-vm/pull/75)
(merged). That fix disabled `systemd-logind` VT management after a default
console service busy-looped at 100% CPU and wedged the build. This design is the
broader, systematic pass: #74 removed one bad default; #78 strips the whole class.

## Problem

`templates/agent.yaml` builds on a general-purpose Ubuntu 24.04 cloud image, which
ships a broad default service set — network discovery, automatic package upgrades,
modem/printer/bluetooth daemons, console login surface, and more. This VM is
**special-purpose**: it exists only to host Vergil agent (Claude Code) sessions
over SSH, with rootless containerd and a fixed dev toolchain. It needs almost none
of those defaults.

Cruft we don't run isn't free. #74 is the cautionary example: a default service we
never use busy-looped at 100% CPU and hung the entire VM build. Every enabled unit
is a potential failure mode, a boot-time cost, a wakeup source, and attack surface.
The objective is the **smallest viable runtime surface**: if a service, timer, or
socket isn't required for our use case, mask it (or don't install it).

## Goals

- A documented **keep / mask / purge** decision for every enabled/running unit, each
  with a one-line justification.
- Template changes that **measurably reduce** the running-service / timer / socket
  count.
- A **before/after footprint snapshot** — process count, idle memory, root-filesystem
  usage, and the unit counts — so the win is *quantified*, not just asserted.
- A durable **regression guardrail** so the minimized surface stays minimized — a
  wrong mask or a base-image bump that revives a unit is caught, not discovered in a
  broken rebuild months later.
- The rebuild still passes the readiness probe (`gh`, `uv`, `claude`, containerd)
  and a real Claude Code session works end to end.

## Non-goals

- **The #74 logind/VT fix itself** — already merged; this design leaves it untouched.
- **cloud-init internals.** cloud-init is *kept* and not stripped — see below; it is
  per-boot load-bearing here.
- **Boot-time as an acceptance gate.** Boot time is recorded as corroborating
  evidence, not gated on (it is too noisy in a VM — see Measurement & footprint
  metrics).
- **A golden full-inventory snapshot test.** The guardrail asserts *intent*, not the
  complete unit set, to avoid brittleness against upstream base-image churn.

## Approach overview

Four artifacts, all in `vergil-vm`:

1. **`templates/agent.yaml`** — a new, dedicated `mode: system` provision block whose
   sole job is surface minimization. Its comment header *is* the in-repo
   keep/mask/purge table, so the rationale lives next to the code that enacts it. It
   runs after the existing tool-install block. cloud-init and the existing `mode: boot`
   logind fix are untouched.
2. **`tests/test_services.sh`** — intent assertions, wired into `tests/run-tests.sh`.
3. **`scripts/audit-services.sh`** — a dumb, one-shot inventory dump that shares its
   command core with the test; output is paste-ready for the issue.
4. **`scripts/vm-metrics.sh`** — a deliberately simple, labeled footprint snapshot
   (process count, idle memory, root-fs usage, unit counts) run **before** and
   **after** stripping to quantify the win.

### Why a dedicated block (not inline, not an external script)

Inlining the masks into the existing tool-install block would tangle minimization
with installation and leave the "why is this masked" rationale homeless.
Externalizing the logic into a guest-side script the template fetches and runs adds
indirection and a sync risk between script and template, against Lima's inline-
provisioning convention. A dedicated, self-documenting block keeps the audit
**legible and lockable**, which is the spirit of the issue.

## Strip mechanism: mask-default + curated purge

- **Mask by default.** `systemctl mask` is reversible (one `unmask` away) and, unlike
  `disable`, prevents a unit from being pulled back in as a dependency. A wrong call
  has minimal blast radius.
- **Curated purge for unambiguous dead weight.** A short, explicit allowlist of
  packages with no conceivable role here (e.g. `snapd`, `unattended-upgrades`) is
  `apt-get purge`d for a real file-count / image win.
- **No aggressive purge-first.** We do not purge anything that could be a transitive
  dependency of containerd, SSH, or cloud-init. The cost of a wrong purge (a broken
  rebuild) outweighs the marginal image saving.

> **Note on masking that no-ops.** `systemctl mask` of a misspelled or absent unit
> does **not** fail loudly — it silently does nothing. This is why the regression
> test asserts the *resulting state* (unit is `masked`/inactive), not merely that the
> mask command ran. See Guardrails.

## Audit methodology (the repeatable process)

`scripts/audit-services.sh` captures, in one run:

- `systemctl list-units --type=service --state=running`
- `systemctl list-unit-files --state=enabled`
- `systemctl list-timers`
- `systemctl list-sockets`
- `systemd-analyze blame`
- `systemd-analyze critical-chain`

Every unit is classified against a single test: **is it required for SSH-in,
rootless containerd, cloud-init per-boot provisioning, DNS/time, or the
gh/uv/claude toolchain?** If yes → keep. If no → mask, or purge when it is a
clearly-dead *package*. The candidate table below is grounded in known Ubuntu 24.04
cloud-image defaults and this VM's known needs; it is **confirmed against a freshly
built VM during implementation** (the planning step runs `audit-services.sh` on a
real build and reconciles any deltas before finalizing the masks).

## Candidate keep / mask / purge table

> Candidate, pending real-build confirmation. Units marked *if present* may not exist
> on the cloud image at all; the audit run confirms presence.

### KEEP — load-bearing; masking these breaks us

| Unit | Why |
|---|---|
| `ssh` / `sshd` | `limactl shell` rides SSH; the only access path. |
| `containerd` (user) + user-lingering | Rootless containerd is the entire purpose of the VM. |
| `cloud-init*` (`cloud-init`, `cloud-config`, `cloud-final`, `cloud-init-local`) | **Per-boot** load-bearing: the existing `mode: boot` logind fix runs through cloud-init on *every* boot, not just first boot. |
| `dbus` | systemd / cloud-init / polkit interactions. |
| `systemd-journald` | Logging; diagnostics. |
| `systemd-resolved` | DNS resolution for agent network access. |
| `systemd-timesyncd` | Correct clock — TLS to GitHub/Anthropic depends on it. |
| `systemd-networkd` + `netplan` | The network itself. |
| `serial-getty` | **Judgment call — keep.** Feeds Lima's serial console log, the diagnostic that matters exactly when a boot wedges (cf. #74). Cheap to keep; masking it blinds us during the next bad boot. |
| `polkit` | Kept-cautious — cloud-init/systemd may rely on it. Revisit only if the audit shows it truly idle. |

### MASK — unit off; package stays; reversible

| Unit | Why |
|---|---|
| `multipathd` | No multipath storage. |
| `ModemManager` | No modems. |
| `getty@tty1` | No interactive console; access is via SSH. (Distinct from `serial-getty`, kept above.) |
| `systemd-networkd-wait-online` (and any `*-wait-online`) | **Judgment call — mask.** Removes the boot-blocking wait for "network online"; networking itself stays up. Biggest boot-time win; the unit to watch hardest in the rebuild probe. |
| `apt-daily.timer`, `apt-daily-upgrade.timer` | Background apt refresh/upgrade — surprise CPU/IO and dpkg-lock contention in a build-once VM. Manual `apt` still works. |
| `motd-news.timer` / `motd-news.service`, `update-notifier*` | Dynamic MOTD news fetch — pointless network calls. |
| `avahi-daemon`, `cups`, `bluetooth`, `packagekit`, `power-profiles-daemon`, `thermald`, `switcheroo-control`, `accounts-daemon` *(if present)* | Desktop/discovery/print/power daemons with no role here. |

### PURGE — curated, unambiguously dead weight

| Package | Why |
|---|---|
| `snapd` (+ `snapd.socket`, `snapd.seeded`) | We never use snaps. Removes a whole subsystem of mounts/timers. |
| `unattended-upgrades` | We do not want surprise upgrades mutating a pinned image mid-life. |
| `modemmanager` *(if pulled as a package)* | No modems. |

## Guardrails

### `tests/test_services.sh` — assert intent, not inventory

Wired into `tests/run-tests.sh`. Two assertion sets, run against the built VM:

- **Denylist:** each unit in the mask/purge table is `masked` (for masks) or absent
  (for purges). Catches a typo'd mask that no-ops and a base-image bump that revives
  a unit.
- **Allowlist:** the load-bearing set still works — `containerd` reachable, `sshd`
  active, and `gh` / `uv` / `claude` resolve and run.

This deliberately does **not** assert the complete running-unit set; a golden
snapshot would break on every legitimate upstream point-release shift and train a
"just re-bless it" reflex that defeats the guard.

### `scripts/audit-services.sh` — dumb dump, shared core

Runs the six inventory commands above and prints their output. Shares its command
core with the test so the two never drift. Two lives: one-time baseline capture for
the issue, and the first diagnostic when something later breaks ("run it, diff
against the table"). It contains no parsing/formatting/diff logic — that would be
gold-plating.

### Measurement & footprint metrics — `scripts/vm-metrics.sh`

We capture the VM's "size" before and after so the win is quantified, not asserted.
`scripts/vm-metrics.sh` takes a label (`before` / `after`) and prints a compact,
paste-ready snapshot of first/second-order footprint metrics:

| Metric | Source | What it shows |
|---|---|---|
| Running services / enabled units / timers / sockets | `systemctl list-* \| count` | The directly-controlled surface (the **gate**). |
| Process count | total live PIDs | How many things are actually running. |
| Idle memory in use | `/proc/meminfo` (`MemTotal` − `MemAvailable`) | Steady-state RAM footprint. |
| Root-fs used / available | `df` on `/` | Installed disk footprint (the purge win lands here). |
| Boot time | `systemd-analyze` | Corroborating evidence only (see below). |

**Sampling discipline (so before/after are comparable):** sample at a defined point —
after the readiness probe passes, a short settle, with **no Claude session attached**.
Idle memory and process counts are far more deterministic than boot wall-clock, but
still depend on *when* you look; a fixed sampling point keeps the two runs
apples-to-apples.

**Sequencing requirement:** the `before` snapshot must be captured on the **current,
unmodified** image *before* any template change lands. The implementation plan
captures baseline first, then strips, then re-measures.

**Gate vs. evidence.** Acceptance gates on the **deterministic reduction in running
services / timers / sockets** — the thing we actually control. Process count, idle
memory, and disk usage are reported as the win story. Boot-time wall-clock is
corroborating only: in a VM it is dominated by cloud-init network waits and one-shot
provisioning and swings several seconds run-to-run from host load, so it is not a
numeric gate.

`vm-metrics.sh` is distinct from `audit-services.sh`: the audit script dumps the
qualitative *lists* (input to classification); the metrics script captures the
quantitative *sizes* (the before/after story). They share the unit-counting
commands so the two never disagree on counts.

## Implementation touchpoints

| File | Change |
|---|---|
| `templates/agent.yaml` | New `mode: system` minimization block (mask list + curated purge), comment header carrying the keep/mask/purge table. |
| `tests/test_services.sh` | New — denylist + allowlist assertions. |
| `tests/run-tests.sh` | Register `test_services.sh`. |
| `scripts/audit-services.sh` | New — one-shot inventory dump. |
| `scripts/vm-metrics.sh` | New — labeled before/after footprint snapshot. |

## Acceptance

- Documented keep/mask/purge decision for every enabled/running unit (the table,
  reconciled against the real build).
- Measured reduction in running services / timers / sockets (before/after).
- A **before/after footprint snapshot** from `vm-metrics.sh` (process count, idle
  memory, root-fs usage, unit counts) attached as the win story — baseline captured
  on the unmodified image first.
- `tests/test_services.sh` green in `run-tests.sh`.
- Rebuild passes the readiness probe (`gh`, `uv`, `claude`, containerd) and a real
  Claude Code session works end to end.
- `systemd-analyze` before/after recorded as evidence.

## Risks & mitigations

- **Masking a transitive dependency of containerd / SSH / cloud-init.** → Mask-default
  (reversible), curated-not-aggressive purge, and the readiness probe + allowlist test
  catch it in the rebuild, not in production.
- **`*-wait-online` change destabilizing early-boot networking.** → Masking removes
  only the blocking wait, not networking; flagged as the unit to watch in the probe.
- **Base-image point release reviving a unit.** → Denylist test fails on the next run.
- **Candidate table drifting from reality.** → Implementation reconciles it against a
  live `audit-services.sh` run before finalizing.
