#!/usr/bin/env bash
# Shared setup sourced by every script in this repo. Not executable on its own.
#
# Loads .env, derives the values that must stay consistent with it (VAULT_ADDR
# follows VAULT_PORT, so changing the port in one place is enough), and fails
# loudly on anything missing rather than halfway through a live demo.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$REPO_ROOT/.env" ]]; then
    echo "ERROR: no .env found. Copy .env.example to .env and fill it in." >&2
    exit 1
fi

# `set -a` exports everything the file defines, so child processes (vault, tcld,
# docker compose) inherit it without us re-exporting each name by hand.
set -a
# shellcheck disable=SC1091
source "$REPO_ROOT/.env"
set +a

: "${TEMPORAL_API_KEY:?set TEMPORAL_API_KEY in .env}"
: "${TEMPORAL_ADMIN_SA_ID:?set TEMPORAL_ADMIN_SA_ID in .env}"
: "${TEMPORAL_NAMESPACE:?set TEMPORAL_NAMESPACE in .env}"

export VAULT_PORT="${VAULT_PORT:-8200}"
export VAULT_TOKEN="${VAULT_TOKEN:-root}"
export MOUNT="${MOUNT:-temporalcloud}"
export PLUGIN_VERSION="${PLUGIN_VERSION:-0.1.1}"
export PLUGIN_NAME="vault-plugin-secrets-temporalcloud"
export PLUGIN_DIR="$REPO_ROOT/plugins"

# Derived, never set in .env: one port, one address, no chance of drift.
export VAULT_ADDR="http://127.0.0.1:${VAULT_PORT}"

# The Vault role name is also the Temporal Cloud service account name, so the
# names live here rather than in demo.sh — reset.sh has to delete exactly what
# demo.sh created, and one definition is the only way that stays true.
# The scoped role's name follows TEMPORAL_NAMESPACE so it can never advertise a
# namespace .env no longer points at. Only the prefix is used: the account
# suffix in "vault-test.rgumq" is noise in a service account name.
export SA_BROAD="demo-app-account-level-read"
export SA_SCOPED="demo-app-${TEMPORAL_NAMESPACE%%.*}-namespace-write"
export SA_METRICS="demo-app-metrics-read"

# The demo drives Vault through the CLI inside the container, so the host does
# not need a `vault` binary installed. This wrapper is what every script calls.
vault() {
    docker compose -f "$REPO_ROOT/docker-compose.yml" exec -T \
        -e VAULT_ADDR=http://127.0.0.1:8200 \
        -e VAULT_TOKEN="$VAULT_TOKEN" \
        vault vault "$@"
}
export -f vault

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: '$1' is required but not installed." >&2
        exit 1
    }
}

# Fails if Vault is not up, which is the single most common reason a step dies
# mid-demo. Better to say so before the audience sees a connection refused.
require_vault_running() {
    if ! vault status >/dev/null 2>&1; then
        echo "ERROR: Vault is not reachable at $VAULT_ADDR. Run 'make up' first." >&2
        exit 1
    fi
}
