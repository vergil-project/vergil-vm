# vergil-vm

Lima VM image definitions for Vergil identity VMs

## Table of Contents

- [Status](#status)
- [Overview](#overview)
- [Getting Started](#getting-started)
- [License](#license)

## Status

Early development

## Overview

Vergil VM implements a sandbox environment for running Claude Code within
the Vergil ecosystem. It protects the host OS by limiting filesystem
access to a single designated project directory, and protects GitHub
resources by authenticating through a dedicated GitHub App with scoped
permissions.

See the [documentation site](https://vergil-project.github.io/vergil-vm/)
for the full guide.

Pinned versions that no lockfile covers (OpenTofu providers, nerdctl, Lima,
Node.js) are kept current by the dependency-update hook,
`scripts/dev/update-deps.sh`; see
[Dependency Updates](docs/site/docs/operations/dependency-updates.md).

## Getting Started

See the [documentation](https://vergil-project.github.io/vergil-vm/).

## License

MIT — see [LICENSE](LICENSE).
