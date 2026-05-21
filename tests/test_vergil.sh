#!/bin/bash
# tests/test_vergil.sh — Verify vergil-tooling can be installed
# dynamically via uv and that vrg-* commands are available.
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

# uv tool install works (install from the configured version)
uv tool install 'vergil-tooling @ git+https://github.com/vergil-project/vergil-tooling@v2.0'

# Core vrg-* commands are available after install
command -v vrg-commit
command -v vrg-git
command -v vrg-gh
command -v vrg-validate
command -v vrg-docker-run

# Clean up (don't leave tooling installed in the test VM)
uv tool uninstall vergil-tooling

echo "test_vergil: all checks passed"
