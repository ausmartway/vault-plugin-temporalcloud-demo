#!/usr/bin/env bash
#
# Back to a clean state, safe to run twice, safe to run after a failed demo.
#
# Order matters: revoke leases first, delete the service accounts second.
# Deleting a service account in Temporal Cloud invalidates every key it owns,
# so doing it the other way round leaves Vault holding leases for keys whose
# owner is already gone.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/common.sh"

SA_NAMES=(demo-app-readonly demo-app-namespace)

if vault status >/dev/null 2>&1 && vault secrets list -format=json 2>/dev/null | grep -q "\"$MOUNT/\""; then
    echo "==> Revoking outstanding leases"
    for sa in "${SA_NAMES[@]}"; do
        vault lease revoke -prefix "$MOUNT/creds/$sa" >/dev/null 2>&1 || true
    done

    echo "==> Deleting service accounts (this deletes them in Temporal Cloud too)"
    for sa in "${SA_NAMES[@]}"; do
        vault delete "$MOUNT/service-accounts/$sa" >/dev/null 2>&1 || true
    done

    echo "==> Disabling the $MOUNT mount"
    vault secrets disable "$MOUNT" >/dev/null 2>&1 || true
else
    echo "==> Vault not running or engine not mounted, skipping Vault cleanup"
fi

echo "==> Stopping Vault"
docker compose -f "$REPO_ROOT/docker-compose.yml" down -v >/dev/null 2>&1 || true

echo "==> Removing the downloaded plugin binary"
rm -rf "$PLUGIN_DIR"

# A crash between minting and revoking can leave a service account behind in
# Temporal Cloud that Vault no longer knows about. Check for those by name so
# the next demo starts from a genuinely clean account.
if command -v tcld >/dev/null 2>&1; then
    echo "==> Checking Temporal Cloud for orphaned demo service accounts"
    orphans="$(tcld --api-key "$TEMPORAL_API_KEY" service-account list 2>/dev/null |
        jq -r '.serviceAccount[]? | select(.spec.name | startswith("demo-app-")) | "\(.id)\t\(.spec.name)"')"
    if [[ -n "$orphans" ]]; then
        echo "$orphans" | while IFS=$'\t' read -r id name; do
            echo "    deleting orphan: $name ($id)"
            tcld --api-key "$TEMPORAL_API_KEY" service-account delete --service-account-id "$id" >/dev/null 2>&1 ||
                echo "    could not delete $name — remove it in the Temporal Cloud UI"
        done
    else
        echo "    none found"
    fi
fi

echo
echo "Clean. 'make demo' will start from scratch."
