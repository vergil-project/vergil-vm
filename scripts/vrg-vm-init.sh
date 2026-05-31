#!/bin/bash
# scripts/vrg-vm-init.sh — Initialize an identity VM with agent credentials.
#
# Injects GitHub App credentials into the VM so the agent can
# authenticate via installation tokens. All token acquisition
# happens dynamically at runtime through vrg-git / vrg-gh —
# this script only provisions the raw credentials and configures
# git for HTTPS access.
#
# Usage:
#   ./scripts/vrg-vm-init.sh <identity-name> <vm-instance>
#
# Reads credentials from ~/.config/vergil/identities.toml, or
# from environment variable overrides:
#   VRG_APP_ID            — GitHub App ID
#   VRG_PRIVATE_KEY_PATH  — Path to App private key (.pem)
#
# Example:
#   ./scripts/vrg-vm-init.sh vergil vergil-agent
set -euo pipefail

IDENTITY="${1:?Usage: vrg-vm-init <identity-name> <vm-instance>}"
INSTANCE="${2:?Usage: vrg-vm-init <identity-name> <vm-instance>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Initializing identity VM: $INSTANCE (identity: $IDENTITY) ==="
echo ""

# --- Read credentials ---

APP_ID="${VRG_APP_ID:-}"
PRIVATE_KEY_PATH="${VRG_PRIVATE_KEY_PATH:-}"

if [ -z "$APP_ID" ] || [ -z "$PRIVATE_KEY_PATH" ]; then
    IDENTITIES_FILE="$HOME/.config/vergil/identities.toml"
    if [ ! -f "$IDENTITIES_FILE" ]; then
        echo "ERROR: $IDENTITIES_FILE not found and VRG_APP_ID / VRG_PRIVATE_KEY_PATH not set" >&2
        exit 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: python3 is required to read $IDENTITIES_FILE (TOML). Install python3, or set VRG_APP_ID and VRG_PRIVATE_KEY_PATH to bypass config parsing." >&2
        exit 1
    fi

    # Read one identity field from the TOML config. tomllib (stdlib, Python
    # 3.11+) is the correct parser — the file is TOML, not YAML, so the old
    # `yq` call was wrong even when yq was installed, and `yq` is not a host
    # dependency. Exits non-zero with a clear message on a parse error or a
    # missing field rather than swallowing it into an empty value.
    read_identity_field() {  # read_identity_field <field>
        python3 - "$IDENTITIES_FILE" "$IDENTITY" "$1" <<'PY'
import sys, tomllib
path, identity, field = sys.argv[1:4]
try:
    with open(path, "rb") as fh:
        data = tomllib.load(fh)
except (OSError, tomllib.TOMLDecodeError) as exc:
    sys.exit(f"ERROR: failed to read {path}: {exc}")
value = data.get("identities", {}).get(identity, {}).get(field)
if value is None:
    sys.exit(f"ERROR: identities.{identity}.{field} not found in {path}")
print(value)
PY
    }

    if [ -z "$APP_ID" ]; then
        APP_ID=$(read_identity_field app_id)
    fi
    if [ -z "$PRIVATE_KEY_PATH" ]; then
        RAW_PATH=$(read_identity_field private_key_path)
        PRIVATE_KEY_PATH="${RAW_PATH/#\~/$HOME}"
    fi
fi

if [ ! -f "$PRIVATE_KEY_PATH" ]; then
    echo "ERROR: Private key not found: $PRIVATE_KEY_PATH" >&2
    exit 1
fi

echo "App ID: $APP_ID"
echo "Key: $PRIVATE_KEY_PATH"
echo ""

# --- Inject App credentials ---

echo "Injecting App private key..."
# shellcheck disable=SC2016
limactl shell "$INSTANCE" -- bash -c \
    'mkdir -p ~/.config/vergil && cat > ~/.config/vergil/app.pem && chmod 600 ~/.config/vergil/app.pem' \
    < "$PRIVATE_KEY_PATH"

echo "Injecting App configuration..."
printf 'APP_ID=%s\n' "$APP_ID" | \
    limactl shell "$INSTANCE" -- bash -c \
        'cat > ~/.config/vergil/app.env && chmod 600 ~/.config/vergil/app.env'

# --- Configure git for HTTPS ---

echo "Configuring git for HTTPS GitHub access..."
limactl shell "$INSTANCE" -- \
    git config --global url."https://github.com/".insteadOf "git@github.com:"

# --- Install vergil-tooling ---

echo "Installing vergil-tooling in VM..."
# shellcheck disable=SC2016
limactl shell "$INSTANCE" -- bash -c \
    'export PATH="$HOME/.local/bin:$PATH" && uv tool install "vergil-tooling @ git+https://github.com/vergil-project/vergil-tooling@v2.0"' \
    2>&1 | tail -3
echo ""

# --- Verify ---

echo "=== Running credential verification ==="
limactl shell "$INSTANCE" -- bash -s < "${SCRIPT_DIR}/vm-verify-credentials.sh"

echo ""
echo "=== VM initialization complete ==="
