# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [2.1.20] - 2026-06-11

### Bug fixes

- keep two-line prompt on one YAML line; use $ prompt char (#163) (#164)

## [2.1.19] - 2026-06-10

### Bug fixes

- bump ci-docs reusable workflow from v2.0 to v2.1 (#159)

## [2.1.18] - 2026-06-09

### Features

- identity-aware two-line interactive prompt (#154)

## [2.1.17] - 2026-06-08

### Bug fixes

- export VRG_IDENTITY_MODE from ~/.zshenv, not ~/.bashrc (#149)

## [2.1.16] - 2026-06-06

### Bug fixes

- grant actions: read to the security job (#144)

## [2.1.15] - 2026-06-06

### Bug fixes

- add Lima user to libvirt/kvm groups for libvirt-stack profiles (#138)

## [2.1.14] - 2026-06-05

### Bug fixes

- loud extra-package failures and template-owned vagrant (#130) (#133)

### Features

- per-profile nested-virtualization knob (#131) (#132)

## [2.1.13] - 2026-06-05

### Chores

- replace raw limactl references with vrg-vm commands

## [2.1.12] - 2026-06-05

### CI

- add build-only docs verification job

## [2.1.11] - 2026-06-05

### Documentation

- design for guaranteeing buildkitd in the VM (#97)
- tighten buildkit build test after pushback (#97)

### Features

- provision and start rootless buildkit for nerdctl build (#97)

### Testing

- assert buildkit unit and end-to-end nerdctl build (#97)

## [2.1.10] - 2026-06-05

### Bug fixes

- disable Claude Code autoupdater via managed settings (#110)

### Chores

- migrate vergil dependency pins from v2.0 to v2.1

### Documentation

- amend VM profiles spec: list enumerates instances only (#111)

## [2.1.9] - 2026-06-04

### Features

- declarative apt_repos + vagrant_plugins provisioning; .vergil/ is scratch (#105)

## [2.1.8] - 2026-06-04

### Documentation

- add per-repo VM profiles design spec (#99)
- fold pushback resolutions into VM profiles spec (#99)
- add Plan 1 (spec foundation) for per-repo VM profiles (#99)
- add Plans 2 (lifecycle) and 3 (observability) for VM profiles (#99)
- apply alignment fixes to VM profile plans (#99)
- use vrg-validate as the per-task verification gate in plans (#99)

### Features

- layer profile packages, hook, and fingerprint at provision time (#99)

### Testing

- end-to-end profile build: package + hook + fingerprint (#99)

## [2.1.7] - 2026-06-01

### Bug fixes

- disable Claude Code background autoupdater (#85)

## [2.1.6] - 2026-05-31

### Bug fixes

- drop redundant template pre-validation
- make runner robust for user-service tests
- unbreak vergil and credentials tests on clean build
- resolve ~/.local/bin in non-login shells
- count only live timers in metrics
- parse identities.toml with tomllib, not host yq
- fail loud on mask/purge errors instead of swallowing them

### Documentation

- add stale-session lifecycle design
- refine stale-lifecycle design after pushback review
- deterministic session naming design (#73)
- finalize session-naming detection design after live re-inspection
- add comprehensive vrg-vm session user guide
- add VM service-surface minimization design
- add before/after footprint metrics to minimization design
- incorporate pushback review into minimization design
- reserve in-VM egress-filtering path in minimization design
- add VM service-surface minimization implementation plan
- align plan and spec after alignment review
- mark service-surface minimization implemented

### Features

- add shared in-guest inventory snippet
- add audit-services.sh inventory dump
- add vm-metrics.sh footprint snapshot
- minimize systemd service surface

### Testing

- add service-surface regression test

## [2.1.5] - 2026-05-29

### Bug fixes

- add language specifier to fenced code block in credential injection ADR
- disable logind VT management to stop 100% CPU busy-loop

### Documentation

- add design spec and implementation plan for site documentation
- add site infrastructure, nav structure, and release boilerplate
- write home page with ecosystem context and component overview
- write getting started guide with VM creation and credential setup
- write architecture overview with provisioning pipeline and credential model
- write VM isolation model design decision
- write credential injection design decision
- write build and test operations guide
- write resource tuning operations guide
- write troubleshooting guide
- fill in README overview section
- rewrite home page with sandbox framing, protection pillars, and corral credit
- rewrite getting started with vrg-vm commands, correct identity naming, and proper step order
- update overview with sandbox framing
- third iteration of site documentation refinements
- clarify why uv is in Stage 2 (per-user install path)
- fourth iteration — table formatting, version cleanup, vrg-vm commands

## [2.1.2] - 2026-05-28

### Bug fixes

- restructure readiness probe with 30-minute combined timeout
- replace language: base with container-suffix: base

### Chores

- bump version to 2.1.1
- add hook guard shim, update CLAUDE.md template, fix settings.json
- remove legacy .githooks/pre-commit
- remove primary-language from vergil.toml

### Documentation

- add VM resource sizing design spec and implementation plan
- add environment indicator design spec
- add environment indicator implementation plan
- add design spec and implementation plan for terminal env forwarding

### Features

- update resource defaults and document override mechanism
- accept terminal env vars for keyboard protocol detection

### Testing

- add acceptance test for terminal env AcceptEnv config

## [2.1.0] - 2026-05-22

### Bug fixes

- add run-codeql false, container-suffix/tag for audit and test jobs, and Table of Contents to README
- remove container-tag from audit and test jobs (not an accepted input)
- add missing release job to cd.yml
- remove audit and test jobs not required for shell repos
- add PATH to readiness probe for user-installed tools
- remove Go template syntax, make projects mount required
- move Claude Code install to system provisioning block

### Chores

- step 3 - vergil.toml
- step 4 - config files
- step 5 - CI/CD workflows
- step 6 - docs site
- add VERSION file (2.1.0) to bootstrap version tracking
- directory structure and Lima-specific gitignore

### Features

- Lima VM template for vergil-agent
- build script for VM creation and testing
- parameterized /projects mount point
- install Node.js and Claude Code in VM template
- credential provisioning via vrg-vm-init

### Testing

- VM acceptance test suite
