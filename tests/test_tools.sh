#!/bin/bash
# tests/test_tools.sh — Verify development tools are installed.
set -euo pipefail

check_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        echo "MISSING: $1"
        return 1
    fi
}

check_command git
check_command gh
check_command uv
check_command jq
check_command yq
check_command rg
check_command fzf
check_command curl
check_command zsh
check_command vim
check_command tmux
check_command nano

echo "test_tools: all checks passed"
