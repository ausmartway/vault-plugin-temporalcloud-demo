#!/usr/bin/env bash
#
# What exists right now, on both sides. Useful before a demo to confirm a clean
# start, and after a failed step to see what actually happened.

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

hdr() { printf '\n\033[1;34m== %s\033[0m\n' "$1"; }

hdr "Vault"
if vault status >/dev/null 2>&1; then
    echo "reachable at $VAULT_ADDR"
    vault secrets list 2>/dev/null | grep -E "^Path|^$MOUNT/" || echo "$MOUNT/ not mounted"
    echo
    echo "roles:"
    vault list "$MOUNT/service-accounts" 2>/dev/null || echo "  (none)"
else
    echo "not running — 'make up' to start it"
fi

hdr "Temporal Cloud service accounts"
tcld --api-key "$TEMPORAL_API_KEY" service-account list |
    jq -r '.serviceAccount[] | "\(.spec.name)\t\(.spec.access.accountAccess.role)\t\(.id)"'

hdr "Temporal Cloud API keys"
tcld --api-key "$TEMPORAL_API_KEY" apikey list |
    jq -r '.apiKeys[] | "\(.spec.displayName)\towner=\(.owner.ownerType)\texpires=\(.spec.expiryTime)"'
