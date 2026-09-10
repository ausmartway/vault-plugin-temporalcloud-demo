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

cleanup_failed=false

print_indented() {
    while IFS= read -r line; do
        printf '      %s\n' "$line"
    done <<<"$1"
}

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
    print_indented "$down_output"
    echo "    run 'docker compose down -v' by hand before the next demo"
    cleanup_failed=true
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
if command -v temporal >/dev/null 2>&1; then
    echo "==> Checking Temporal Cloud for orphaned temporary bootstrap keys"
    if bootstrap_list="$(temporal cloud apikey list \
        --api-key "$TEMPORAL_CLOUD_API_KEY" --page-size 100 -o json 2>&1)"; then
        bootstrap_keys="$(jq -r '.ApiKeys[]?
            | select(.spec.display_name | startswith("vault-demo-bootstrap-"))
            | "\(.id)\t\(.spec.display_name)"' <<<"$bootstrap_list")"
        if [[ -n "$bootstrap_keys" ]]; then
            while IFS=$'\t' read -r id name; do
                echo "    deleting orphan: $name ($id)"
                if ! delete_output="$(temporal cloud apikey delete --key-id "$id" \
                    --api-key "$TEMPORAL_CLOUD_API_KEY" \
                    --auto-confirm --idempotent 2>&1)"; then
                    echo "    could not delete $name"
                    print_indented "$delete_output"
                    cleanup_failed=true
                fi
            done <<<"$bootstrap_keys"
        else
            echo "    none found"
        fi
    else
        echo "    could not list API keys"
        print_indented "$bootstrap_list"
        cleanup_failed=true
    fi

    echo "==> Checking Temporal Cloud for orphaned demo service accounts"
    # Report a failed lookup instead of swallowing it. Under `set -euo pipefail`
    # a failing lookup here used to abort the whole reset with stderr discarded —
    # so the operator saw neither "Clean." nor any reason why. A sweep that
    # cannot run is exactly when you need to be told.
    # --page-size guards against orphans hiding past the first page on an
    # account with many service accounts.
    if ! sa_list="$(temporal cloud service-account list --api-key "$TEMPORAL_CLOUD_API_KEY" \
        --page-size 100 -o json 2>&1)"; then
        echo "    could not reach Temporal Cloud — check that the setup key in .env is"
        echo "    valid, or remove leftover demo-app-*, demo-k8s-worker*, and"
        echo "    vault-demo-bootstrap-* accounts by hand"
        sa_list='{}'
        cleanup_failed=true
    fi
    # ServiceAccounts, capitalised: `temporal cloud service-account list -o json`
    # capitalises the envelope, unlike `... get -o json` which does not.
    orphans="$(jq -r '.ServiceAccounts[]?
        | select(.spec.name
            | startswith("demo-app-")
                or startswith("demo-k8s-worker")
                or startswith("vault-demo-bootstrap-"))
        | "\(.id)\t\(.spec.name)"' <<<"$sa_list")"
    if [[ -n "$orphans" ]]; then
        while IFS=$'\t' read -r id name; do
            echo "    deleting orphan: $name ($id)"
            if ! delete_output="$(temporal cloud service-account delete \
                --service-account-id "$id" \
                --api-key "$TEMPORAL_CLOUD_API_KEY" \
                --auto-confirm 2>&1)"; then
                echo "    could not delete $name — remove it in the Temporal Cloud UI"
                print_indented "$delete_output"
                cleanup_failed=true
            fi
        done <<<"$orphans"
    elif [[ "$cleanup_failed" == false ]]; then
        echo "    none found"
    fi
fi

echo
if [[ "$cleanup_failed" == true ]]; then
    echo "Cleanup incomplete. Resolve the errors above before running 'make demo'."
    exit 1
fi

echo "Clean. 'make demo' will start from scratch."
