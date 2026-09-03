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

# Defined in common.sh so these are always the names demo.sh just created.
SA_NAMES=("$SA_BROAD" "$SA_SCOPED" "$SA_METRICS")

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
# Do not swallow this. Discarding the output and `|| true`-ing the failure meant
# a teardown could fail and the script would still print "Clean." at the end —
# leaving a container holding port 8200 that the operator was told was gone.
if ! down_output="$(docker compose -f "$REPO_ROOT/docker-compose.yml" down -v 2>&1)"; then
    echo "    could not stop Vault:"
    echo "$down_output" | sed 's/^/      /'
    echo "    run 'docker compose down -v' by hand before the next demo"
fi

echo "==> Removing the downloaded plugin binary"
rm -rf "$PLUGIN_DIR"

# A crash between minting and revoking can leave a service account behind in
# Temporal Cloud that Vault no longer knows about. Check for those by name so
# the next demo starts from a genuinely clean account.
#
# Both demo families are swept. This Vault runs in dev mode, so stopping its
# container — a laptop reboot, a Docker Desktop restart — discards every role
# while the accounts they created live on. The plugin then refuses to mint
# against an account it did not create, and `up` fails on a name this repo
# created itself, so a sweep that covered only demo-app-* left the Kubernetes
# demo permanently wedged after something as ordinary as a reboot.
if command -v tcld >/dev/null 2>&1; then
    echo "==> Checking Temporal Cloud for orphaned demo service accounts"
    # Report a failed lookup instead of swallowing it. Under `set -euo pipefail`
    # a failing tcld here used to abort the whole reset with stderr discarded —
    # so the operator saw neither "Clean." nor any reason why. A sweep that
    # cannot run is exactly when you need to be told.
    # --page-size: tcld pages at 10 by default, which would hide orphans on an
    # account that has more than ten service accounts.
    if ! sa_list="$(tcld --api-key "$TEMPORAL_CLOUD_API_KEY" service-account list --page-size 100 2>&1)"; then
        echo "    could not reach Temporal Cloud — check for leftover demo-app-* and demo-k8s-worker* accounts by hand"
        sa_list='{}'
    fi
    orphans="$(jq -r '.serviceAccount[]?
        | select(.spec.name | startswith("demo-app-") or startswith("demo-k8s-worker"))
        | "\(.id)\t\(.spec.name)"' <<<"$sa_list")"
    if [[ -n "$orphans" ]]; then
        echo "$orphans" | while IFS=$'\t' read -r id name; do
            echo "    deleting orphan: $name ($id)"
            tcld --api-key "$TEMPORAL_CLOUD_API_KEY" service-account delete --service-account-id "$id" >/dev/null 2>&1 ||
                echo "    could not delete $name — remove it in the Temporal Cloud UI"
        done
    else
        echo "    none found"
    fi
fi

echo
echo "Clean. 'make demo' will start from scratch."
