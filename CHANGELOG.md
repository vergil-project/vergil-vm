# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/)
and this project adheres to [Semantic Versioning](https://semver.org/).

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
