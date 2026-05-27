# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [2.1.1] - 2026-05-27

### Bug fixes

- restructure readiness probe with 30-minute combined timeout

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
