# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/)
and this project adheres to [Semantic Versioning](https://semver.org/).

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
