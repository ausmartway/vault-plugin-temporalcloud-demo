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

# The CLI's own tables rather than jq over `-o json`, and that is not laziness:
# `-o json` leaves every enum as an integer — an account role reads as 5, an
# owner type as 2 — while the text table renders them as ROLE_READ and
# SERVICE_ACCOUNT. For output a human is reading, the table is the accurate one.
#
# The trade is that the tables carry no role or expiry column. For either, ask
# about one account directly:
#   temporal cloud service-account get --service-account-id <id> --api-key ...
#
# --page-size guards against a status check silently omitting what you are
# looking for, which is worse than no status check at all.
hdr "Temporal Cloud service accounts"
temporal cloud service-account list --api-key "$TEMPORAL_CLOUD_API_KEY" --page-size 100

hdr "Temporal Cloud API keys"
temporal cloud apikey list --api-key "$TEMPORAL_CLOUD_API_KEY"
