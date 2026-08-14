#!/usr/bin/env bash
#
# Vault + Temporal Cloud dynamic secrets — interactive walkthrough.
#
#   ./demo.sh                  type-along, advances on ENTER (live demo)
#   AUTO_PLAY_MODE=1 ./demo.sh unattended, no keypresses (smoke test / recording)
#
# Every step is a real command against a real Temporal Cloud account. Nothing
# here is simulated — the API keys you see appear and disappear for real.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/common.sh"

require_cmd tcld
require_cmd jq
require_vault_running

: "${TEMPORAL_NAMESPACE:?set TEMPORAL_NAMESPACE in .env}"

########################################################################
# demo-magic setup
########################################################################
TYPE_SPEED=40

# demo-magic reads several variables it does not define itself, so the strict
# `set -u` inherited from common.sh has to come off before sourcing it.
set +u

# -n: never wait for a keypress.  -d: don't simulate typing, print instantly.
# Together they turn the type-along demo into a straight-through run.
if [[ "${AUTO_PLAY_MODE:-0}" == "1" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/demo-magic.sh" -n -d
else
    # shellcheck source=/dev/null
    source "$REPO_ROOT/demo-magic.sh"
fi

DEMO_PROMPT="${GREEN}➜ ${CYAN}vault-temporalcloud ${COLOR_RESET}"

# demo-magic wraps every command in `stty -echoctl` / `stty echoctl`, which
# fails when stdout is a pipe rather than a terminal — and under `set -e` that
# failure ends the run. Unattended mode has no terminal to configure, so a
# no-op shim is exactly right; interactive mode keeps the real stty.
if [[ "${AUTO_PLAY_MODE:-0}" == "1" ]]; then
    stty() { :; }
fi

# Read-only helper so the narration commands look like the real thing on screen.
tc() { tcld --api-key "$TEMPORAL_API_KEY" "$@"; }

# Temporal Cloud does not make a key usable the instant it is created, and does
# not reject it the instant it is deleted — propagation across the auth layer
# takes a few seconds either way. Polling for the transition keeps the demo
# honest: the commands the audience sees are real, they just run once the
# platform has caught up instead of racing it.
# Propagation is also uneven across Temporal Cloud's auth nodes: a single probe
# can succeed while the next one fails, and vice versa. Requiring several
# consecutive results in a row is what makes the next command reliable — a
# revoked key that got one rejection can still be accepted a second later.
CONFIRM_VALID=2
CONFIRM_REVOKED=3

wait_for_key_valid() {
    local streak=0
    for _ in {1..20}; do
        if tcld --api-key "$1" namespace list >/dev/null 2>&1; then
            streak=$((streak + 1))
            [[ $streak -ge $CONFIRM_VALID ]] && {
                echo "key is live"
                return 0
            }
        else
            streak=0
        fi
        sleep 3
    done
    echo "key never became valid — check the Temporal Cloud UI" >&2
    return 1
}

wait_for_key_revoked() {
    local streak=0
    for _ in {1..20}; do
        if tcld --api-key "$1" namespace list >/dev/null 2>&1; then
            streak=0
        else
            streak=$((streak + 1))
            [[ $streak -ge $CONFIRM_REVOKED ]] && {
                echo "key is dead"
                return 0
            }
        fi
        sleep 3
    done
    echo "key still works — revocation did not reach Temporal Cloud" >&2
    return 1
}

# demo-magic's `pe` evals in this shell, so the vault() and tc() functions and
# every .env value are all in scope for the commands typed below.
SA_BROAD="demo-app-readonly"
SA_SCOPED="demo-app-namespace"

say() { printf '\n\033[1;33m%s\033[0m\n' "$1"; }

# demo-magic's own `wait` blocks on a keypress even with -n, and returns
# nonzero at EOF — which kills an unattended run outright. This respects
# AUTO_PLAY_MODE and never takes the script down with it.
pause() {
    [[ "${AUTO_PLAY_MODE:-0}" == "1" ]] && return 0
    printf '\033[90m(press ENTER)\033[0m'
    read -rs || true
    printf '\r\033[K'
}

clear
say "Vault as the issuer of Temporal Cloud API keys"
cat <<'EOF'

The problem: Temporal Cloud API keys are static. They get pasted into CI, into
a teammate's shell history, into a secret manager nobody rotates. When someone
leaves, you find out how many places that key lives.

The fix: never issue a long-lived key. An app asks Vault for a Temporal Cloud
credential, Vault mints one, and Vault deletes it in Temporal Cloud the moment
the lease ends.

EOF

# `make demo` starts Vault before this script runs, but the `clear` above wipes
# that output — so reprint it here. Handy for opening the UI on the projector
# alongside the CLI.
printf '\033[1;36m  Vault UI    \033[0m%s/ui\n' "$VAULT_ADDR"
printf '\033[1;36m  API addr    \033[0m%s\n' "$VAULT_ADDR"
printf '\033[1;36m  Login       \033[0m method: Token   token: %s\n' "$VAULT_TOKEN"
printf '\033[90m  (dev mode: in-memory, auto-unsealed, root token in .env)\033[0m\n\n'

pause

########################################################################
say "1. Register the plugin and mount the secrets engine"
########################################################################
# Vault refuses to load a plugin whose binary does not hash to the value it was
# registered with — this is the supply-chain check, and it is why the release
# ships a _SHA256SUMS file. scripts/fetch-plugin.sh already verified the
# archive; this registers the extracted binary by its own hash.
PLUGIN_SHA="$(cat "$REPO_ROOT/.plugin-cache/binary.sha256")"

pe "vault plugin register -sha256=$PLUGIN_SHA secret $PLUGIN_NAME"
pe "vault secrets enable -path=$MOUNT $PLUGIN_NAME"

########################################################################
say "2. Give Vault one bootstrap credential — the last static key"
########################################################################
# admin_service_account_id is required and not optional trivia: an API key
# token does not say who owns it, and the Cloud Ops API cannot look it up, so
# Vault has to be told. api_key_id lets rotate-root delete the key it replaces.
# Kept on one line on purpose: demo-magic runs commands through `eval $@`
# unquoted, so backslash-continuations get mangled before Vault ever sees them.
pe "vault write $MOUNT/config api_key=\"\$TEMPORAL_API_KEY\" api_key_id=\"\$TEMPORAL_API_KEY_ID\" admin_service_account_id=\"\$TEMPORAL_ADMIN_SA_ID\""

say "Read it back — the key itself never comes out again."
pe "vault read $MOUNT/config"

########################################################################
say "3. Define two roles: broad, and least-privilege"
########################################################################
# Each of these creates a real service account in Temporal Cloud. They are
# templates, not credentials — no API key exists yet.
say "Role A — account-wide read."
pe "vault write $MOUNT/service-accounts/$SA_BROAD account_role=read ttl=5m max_ttl=1h description='Broad read access, issued by Vault'"

say "Role B — no account access, write on one namespace only."
# account_role=read is the floor Temporal Cloud requires; the interesting part
# is namespace_access, which is what a real worker should actually get.
pe "vault write $MOUNT/service-accounts/$SA_SCOPED account_role=read namespace_access=\"\$TEMPORAL_NAMESPACE=write\" ttl=5m max_ttl=1h description='Least privilege: one namespace'"

pe "vault read $MOUNT/service-accounts/$SA_SCOPED"

say "Both service accounts now exist in Temporal Cloud:"
pe "tc service-account list | jq -r '.serviceAccount[] | \"\\(.spec.name)\\t\\(.spec.access.accountAccess.role)\"'"

########################################################################
say "4. Ask Vault for a credential"
########################################################################
pe "vault read $MOUNT/creds/$SA_BROAD"

say "Capture one and actually use it."
pe "API_KEY=\$(vault read -field=api_key $MOUNT/creds/$SA_SCOPED)"

say "Temporal Cloud needs a few seconds to propagate a brand-new key:"
pe "wait_for_key_valid \"\$API_KEY\""
pe "tcld --api-key \"\$API_KEY\" namespace list"

say "A credential Vault minted seconds ago, authenticating against Temporal Cloud."
pause

########################################################################
say "5. The lease is the leash"
########################################################################
pe "vault list sys/leases/lookup/$MOUNT/creds/$SA_SCOPED"

say "Renewing extends the lease — and never calls Temporal Cloud."
# The key is minted with a Cloud-side expiry well past max_ttl, so renewal is
# pure Vault bookkeeping. It also means a Vault crash leaves a key that expires
# on its own rather than lingering forever.
LEASE_ID="$(vault list -format=json "sys/leases/lookup/$MOUNT/creds/$SA_SCOPED" | jq -r '.[0]')"
pe "vault lease renew $MOUNT/creds/$SA_SCOPED/$LEASE_ID"

say "Here are the keys Vault has minted, as Temporal Cloud sees them:"
# Vault names every key it mints "vault-<role>-<random>", which is how you tell
# Vault-issued credentials from hand-created ones in the Temporal Cloud UI.
# Note the Cloud-side expiry: well past the 5m lease, so renewal never has to
# call Temporal Cloud — and an orphaned key still dies on its own.
pe "tc apikey list | jq -r '.apiKeys[] | select(.spec.displayName | startswith(\"vault-demo-app-\")) | \"\\(.spec.displayName)\\texpires \\(.spec.expiryTime)\"'"

########################################################################
say "6. Revoke — and watch them disappear from Temporal Cloud"
########################################################################
pe "vault lease revoke -prefix $MOUNT/creds/$SA_BROAD"
pe "vault lease revoke -prefix $MOUNT/creds/$SA_SCOPED"

say "Same key, seconds later:"
pe "wait_for_key_revoked \"\$API_KEY\""
# Expected to fail. That failure is the whole demo.
pe "tcld --api-key \"\$API_KEY\" namespace list || echo '>>> rejected — the key no longer exists in Temporal Cloud'"

########################################################################
say "That's the model"
########################################################################
cat <<'EOF'

  - No human ever saw a long-lived Temporal Cloud key.
  - Access is scoped per role, not per person.
  - Revocation is one command, and it is real: the credential is deleted in
    Temporal Cloud, not just forgotten by Vault.

Worth mentioning if it comes up:
  - Temporal Cloud caps a service account at 20 non-expired keys, so that is
    the ceiling on concurrent leases per role.
  - The bootstrap key has its own TTL (root_key_ttl, 90d default).
    `vault write -f temporalcloud/config/rotate-root` replaces it, and Vault
    then holds a root credential no human has ever seen.

Run `make reset` to delete the service accounts and tear Vault down.

EOF
