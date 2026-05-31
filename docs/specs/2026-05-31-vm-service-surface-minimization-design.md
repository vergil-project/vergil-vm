# VM Service-Surface Minimization Design

**Issues:**
- [vergil-vm #78 — Audit and minimize VM service surface: strip the agent image to smallest viable footprint](https://github.com/vergil-project/vergil-vm/issues/78)

**Date:** 2026-05-31

**Status:** Implemented (issue #78).

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
- **Implementing egress filtering.** That is vergil-tooling #901. This pass only
  stays *compatible* with it by reserving the in-VM netfilter/networking path — see
  Forward-compatibility.

## Approach overview

Four artifacts, all in `vergil-vm`:

1. **`templates/agent.yaml`** — a new, dedicated `mode: system` provision block whose
   sole job is surface minimization. Its comment header *is* the in-repo
   keep/mask/purge table, so the rationale lives next to the code that enacts it. It
   runs after the existing tool-install block. cloud-init and the existing `mode: boot`
   logind fix are untouched.
2. **`tests/test_services.sh`** — intent assertions; auto-discovered by the
   `tests/run-tests.sh` `test_*.sh` glob (runs in-guest).
3. **`scripts/audit-services.sh`** — a dumb, one-shot inventory dump (host-side
   wrapper over the shared in-guest snippet); output is paste-ready for the issue.
4. **`scripts/vm-metrics.sh`** — a deliberately simple, labeled footprint snapshot
   (process count, idle memory, root-fs usage, unit counts) run **before** and
   **after** stripping to quantify the win (host-side wrapper over the shared
   in-guest snippet).

### Execution model — host-side wrappers over a shared in-guest snippet

The test harness already runs each `tests/test_*.sh` **inside the guest** by piping
it over `limactl shell "$INSTANCE" -- bash -s`, while the existing `scripts/` are
**host-side**. To make the "never drift" guarantee real across that boundary, the
actual inventory commands (`systemctl list-*`, `/proc/meminfo`, `df`,
`systemd-analyze`) live in **one shared in-guest snippet** (e.g.
`tests/lib/inventory.sh`). `audit-services.sh` and `vm-metrics.sh` are thin
host-side wrappers that run that snippet via `limactl shell <instance> -- bash -s`.
`test_services.sh` asserts unit *states* (masked / active) rather than counts, so it
stands alone — but the two scripts that *do* count the surface share one definition,
so they cannot disagree.

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
clearly-dead *package*. **Namespace rules:** (1) any unit in the `lima-*` namespace
is KEEP unless positively proven idle — these are Lima's own coordination units and
masking one can silently break `limactl` access; (2) any `netfilter*` / `iptables*` /
`nftables*` unit is KEEP — **reserved for future egress filtering** (see
Forward-compatibility below), even though it looks idle in a fresh image. The
candidate table below is grounded in known Ubuntu 24.04
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
| `lima-guestagent` (and any `lima-*` units) | Lima-injected; coordinates port-forwarding and `limactl shell` access. Non-obvious and easy to mistake for cruft — masking it breaks the only access path *and* the test/metrics tooling that rides it. Exact unit name and scope (system vs. user) confirmed by the real-build audit. |
| `containerd` (user) + user-lingering | Rootless containerd is the entire purpose of the VM. |
| `cloud-init*` (`cloud-init`, `cloud-config`, `cloud-final`, `cloud-init-local`) | **Per-boot** load-bearing: the existing `mode: boot` logind fix runs through cloud-init on *every* boot, not just first boot. |
| `dbus` | systemd / cloud-init / polkit interactions. |
| `systemd-journald` | Logging; diagnostics. |
| `systemd-resolved` | DNS resolution for agent network access. **Egress-critical:** under egress filtering Layer 3 drops port 53 to arbitrary hosts, so the VM's DNS must route through the local stub resolver — doubly load-bearing then. |
| `systemd-timesyncd` | Correct clock — TLS to GitHub/Anthropic depends on it. |
| `systemd-networkd` + `netplan` | The network itself. **Egress-relevant:** the iptables DNAT target is derived from the default route (`ip route show default`), so routing must be intact. |
| `netfilter*` / `iptables*` / `nftables*` units *(reserved)* | KEEP even if idle now — reserved for egress filtering Layer 1 (in-VM iptables DNAT + `netfilter-persistent` reload at boot). See Forward-compatibility. |
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
| `unattended-upgrades` | We do not want surprise upgrades mutating a pinned image mid-life. **Security note below.** |
| `modemmanager` *(if pulled as a package)* | No modems. |

#### Security note — removing the auto-patch path is deliberate

`unattended-upgrades` is also the channel that applies **security** patches, so
purging it means a running VM does not self-patch CVEs. This is an accepted,
deliberate tradeoff, **not** an oversight, and it is sound only because of how these
VMs are operated: they are treated as **ephemeral, stateless resources refreshed by
frequent rebuilds**, which is where security updates come from (a rebuild pulls the
updated base image). This is the same philosophy as the
[stale-session lifecycle](./2026-05-30-stale-session-lifecycle-design.md) — which
actively nudges away from long-lived sessions — and the broader practice of
aggressively rebuilding agents rather than letting bespoke state accumulate over
time. **If VMs ever become long-lived, this decision must be revisited and an update
mechanism added; until then, the strategy is rebuild, not patch-in-place.**

## Forward-compatibility: egress filtering (vergil-tooling #901)

Egress filtering — a three-layer system (in-VM iptables DNAT → host HAProxy SNI
allowlist → host pf perimeter) that confines the agent's network reach to an
explicit host allowlist — is a **planned, pre-release-critical** feature
([vergil-tooling #901](https://github.com/vergil-project/vergil-tooling/issues/901),
adopted from corral). It is **not implemented here**, but this minimization pass must
not strip the in-VM machinery it will need, or we trade a quick win now for rework
(and a confusing breakage) later.

The two efforts are complementary, not in tension: **minimization shrinks what the
agent could talk to; egress filtering controls where it is allowed to.** Keeping the
network path intact while stripping unrelated daemons serves both.

**Only Layer 1 lives inside the VM.** Layers 2–3 (HAProxy, pf) run on the host and
need nothing from the guest. Layer 1 (#901 Plan 4, Task 4) detects the host gateway,
adds a `nat`/`OUTPUT` DNAT rule redirecting `:443` to the host proxy, and persists it
to `/etc/iptables/rules.v4`. What that requires us to **proactively KEEP**:

| Reserved for egress | Why it must not be masked/purged |
|---|---|
| `netfilter*` / `iptables*` / `nftables*` units | Carry the `nat` table + DNAT and the boot-time `rules.v4` reload (`netfilter-persistent`). Idle in a fresh image — precisely the trap. The namespace rule above reserves them. |
| `systemd-resolved` | Egress Layer 3 drops port 53 to arbitrary hosts; the VM resolves only via the local stub resolver. Masking it breaks DNS *under filtering*. |
| `systemd-networkd` + `netplan` | The DNAT target is the default route; routing must stay intact. |
| `iptables` package (not purged) | Present in the base image; the DNAT rule needs it. Not on any purge list — recorded here so it stays that way. |

**Observation (for #901, not this issue):** as written, Task 4 persists the rule to
`/etc/iptables/rules.v4` but does not install/enable `netfilter-persistent`, so the
rule would not survive a reboot. That gap belongs to #901; we note it only to explain
why `netfilter-persistent` is on our reserved-KEEP list — egress will need it enabled.

This section is documentation only; it adds **no** template change now. Its job is to
ensure the audit's keep/mask/purge decisions are made with egress filtering in view.

## Guardrails

### `tests/test_services.sh` — assert intent, not inventory

Auto-discovered by the `run-tests.sh` `test_*.sh` glob — the file just needs the
right name; no harness edit. Runs in-guest. Three assertion sets, against the built VM:

- **Denylist:** each unit in the mask/purge table is `masked` (for masks) or absent
  (for purges). Catches a typo'd mask that no-ops and a base-image bump that revives
  a unit.
- **Allowlist:** the load-bearing set still works — `containerd` reachable, `sshd`
  active, and `gh` / `uv` / `claude` resolve and run.
- **Reserved:** the Lima guest-agent unit is **not** masked — a narrow positive guard
  on the highest-impact reserved unit, so a future edit that masks Lima's own
  coordination unit is caught here, not in a mysterious `limactl` failure. (The
  `netfilter*` units are absent until egress lands, so they are guarded by the comment
  reservation and the decision table rather than a vacuous "not masked" assertion.)

This deliberately does **not** assert the complete running-unit set; a golden
snapshot would break on every legitimate upstream point-release shift and train a
"just re-bless it" reflex that defeats the guard.

### `scripts/audit-services.sh` — dumb dump, shared core

A host-side wrapper that runs the shared in-guest inventory snippet (see Execution
model) via `limactl shell` and prints its output — the six inventory commands above.
Because the snippet is the same one the test counts against, the two never drift.
Two lives: one-time baseline capture for the issue, and the first diagnostic when
something later breaks ("run it, diff against the table"). It contains no
parsing/formatting/diff logic — that would be gold-plating.

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

**Resource-config parity (so the comparison is honest):** `before` and `after` must
be built with the **identical** `cpus` / `memory` / `disk` config — idle-memory and
disk-available numbers move with VM size, and the template documents per-identity
overrides (e.g. `memory = "32GiB"`), so a size mismatch would make the "win" pure
noise. Use the template defaults for both runs, and have `vm-metrics.sh` record the
active `cpus`/`memory`/`disk` in its output header so any mismatch is self-evident on
the face of the snapshot.

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
quantitative *sizes* (the before/after story). Both draw their unit counts from the
same shared in-guest snippet (see Execution model), so they cannot disagree.

## Implementation touchpoints

| File | Change |
|---|---|
| `templates/agent.yaml` | New `mode: system` minimization block (mask list + curated purge), comment header carrying the keep/mask/purge table. |
| `tests/lib/inventory.sh` | New — the shared in-guest inventory snippet (single definition of how the surface is counted). |
| `tests/test_services.sh` | New — denylist + allowlist + reserved (Lima agent unmasked) assertions. Auto-discovered by the `test_*.sh` glob; **no `run-tests.sh` edit needed.** |
| `scripts/audit-services.sh` | New — host-side wrapper; one-shot inventory dump via the shared snippet. |
| `scripts/vm-metrics.sh` | New — host-side wrapper; labeled before/after footprint snapshot, records resource config in its header. |

## Acceptance

- Documented keep/mask/purge decision for every enabled/running unit, delivered as a
  **per-unit decision table** (one row per unit, `keep｜mask｜purge` + a one-line
  reason) reconciled against the real build and attached to the issue. KEEPs may be
  justified by category; the table covers the audit's running-services and
  enabled-unit-files sets, not just the changed units.
- Measured reduction in running services / timers / sockets (before/after).
- A **before/after footprint snapshot** from `vm-metrics.sh` (process count, idle
  memory, root-fs usage, unit counts) attached as the win story — baseline captured
  on the unmodified image first.
- `tests/test_services.sh` green in `run-tests.sh`.
- **Two-tier "still works" check:**
  - *Smoke (automated, in `build.sh`):* rebuild passes the readiness probe, tools
    (`gh`, `uv`, `claude`) resolve, containerd runs, and the `claude` CLI launches.
    The `build.sh` instance is uncredentialed, so this is all it can prove.
  - *End-to-end (manual gate, credentialed VM):* one real non-interactive Claude turn
    completes on the stripped image. This is the criterion's "a real Claude Code
    session works end to end"; it requires credentials so it runs as a deliberate
    manual gate, recorded on the issue (or explicitly marked deferred to a credentialed
    host — never silently skipped).
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
