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

require_cmd temporal
require_cmd jq
require_vault_running

# demo-magic simulates typing with `pv` and exits at source time without it,
# before a single line of this script runs. Only the type-along path needs it —
# AUTO_PLAY_MODE prints instantly and never calls pv.
[[ "${AUTO_PLAY_MODE:-0}" == "1" ]] || require_cmd pv

# The plugin refuses to create a service account it did not create itself, so a
# leftover from a Ctrl-C'd run — or a colleague demoing against the same Cloud
# account — makes step 3 fail. Discovering that halfway through the walkthrough,
# with two of three roles already created, is the worst possible moment. Check
# before the first slide instead.
preflight_clean() {
    local existing
    # `-o json` capitalises the envelope and snake_cases the fields, which is
    # not what the same CLI does elsewhere: `service-account get -o json`
    # returns camelCase. Each subcommand's shape has to be checked rather than
    # assumed.
    existing="$(temporal cloud service-account list --api-key "$TEMPORAL_CLOUD_API_KEY" \
        --page-size 100 -o json 2>/dev/null |
        jq -r '.ServiceAccounts[]?
            | select(.spec.name | startswith("demo-app-") or startswith("vault-demo-bootstrap-"))
            | .spec.name' || true)"
    [[ -z "$existing" ]] && return 0
    echo "ERROR: these demo service accounts already exist in Temporal Cloud:" >&2
    echo "$existing" | sed 's/^/  - /' >&2
    echo "Vault refuses to recreate them. Run 'make reset' first." >&2
    exit 1
}
preflight_clean

# Keep the personal key in .env as a stable setup credential. For the actual
# demonstration, create a dedicated temporary Global Admin service account and
# one disposable key on it. Vault sees only that service-account key. The exit
# trap removes the temporary account and every key it owns, including the root
# key created by rotate-root, while the personal setup key remains untouched.
create_demo_bootstrap_identity() {
    local service_account_json create_key_json

    DEMO_BOOTSTRAP_SERVICE_ACCOUNT_NAME="vault-demo-bootstrap-$(date +%s)"
    service_account_json="$(temporal cloud service-account create \
        --name "$DEMO_BOOTSTRAP_SERVICE_ACCOUNT_NAME" \
        --description "Temporary root identity created by the Vault demo" \
        --account-role admin \
        --api-key "$TEMPORAL_CLOUD_API_KEY" \
        --auto-confirm -o json)"
    DEMO_ADMIN_SERVICE_ACCOUNT_ID="$(jq -er '.serviceAccountId' <<<"$service_account_json")"

    create_key_json="$(temporal cloud apikey create-for-service-account \
        --service-account-id "$DEMO_ADMIN_SERVICE_ACCOUNT_ID" \
        --display-name "vault-demo-bootstrap-key" \
        --description "Disposable bootstrap key created by the Vault demo" \
        --expiry-duration 24h \
        --api-key "$TEMPORAL_CLOUD_API_KEY" \
        --auto-confirm -o json)"
    DEMO_BOOTSTRAP_KEY="$(jq -er '
        [.. | objects | .token? // empty][0]
    ' <<<"$create_key_json")"
}

cleanup_demo_bootstrap_identity() {
    local service_account_id="${DEMO_ADMIN_SERVICE_ACCOUNT_ID:-}"

    # If account creation succeeded but parsing its response did not, recover
    # the ID by the unique name so an interrupted setup cannot leak an admin
    # service account.
    if [[ -z "$service_account_id" &&
        -n "${DEMO_BOOTSTRAP_SERVICE_ACCOUNT_NAME:-}" ]]; then
        service_account_id="$(temporal cloud service-account list \
            --api-key "$TEMPORAL_CLOUD_API_KEY" --page-size 100 -o json 2>/dev/null |
            jq -r --arg name "$DEMO_BOOTSTRAP_SERVICE_ACCOUNT_NAME" '
                [.ServiceAccounts[]? | select(.spec.name == $name) | .id][0] // empty
            ' || true)"
    fi

    [[ -n "$service_account_id" ]] || return 0
    temporal cloud service-account delete \
        --service-account-id "$service_account_id" \
        --api-key "$TEMPORAL_CLOUD_API_KEY" --auto-confirm --idempotent \
        >/dev/null 2>&1 || true
}

DEMO_BOOTSTRAP_SERVICE_ACCOUNT_NAME=""
DEMO_ADMIN_SERVICE_ACCOUNT_ID=""
DEMO_BOOTSTRAP_KEY=""
trap cleanup_demo_bootstrap_identity EXIT
create_demo_bootstrap_identity

########################################################################
# demo-magic setup
########################################################################
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

# Both of these must be set *after* the source above: demo-magic.sh assigns
# TYPE_SPEED=20 unconditionally at source time, so setting it earlier is silently
# discarded and the demo types at a speed nobody chose.
TYPE_SPEED=40
DEMO_PROMPT="${GREEN}➜ ${CYAN}vault-temporalcloud ${COLOR_RESET}"

# demo-magic wraps every command in `stty -echoctl` / `stty echoctl`, which
# fails when stdout is a pipe rather than a terminal — and under `set -e` that
# failure ends the run. Unattended mode has no terminal to configure, so a
# no-op shim is exactly right; interactive mode keeps the real stty.
if [[ "${AUTO_PLAY_MODE:-0}" == "1" ]]; then
    stty() { :; }
fi

# The plugin verifies a newly minted key with ten independent connections
# to each namespace frontend over at least 450ms before returning it. The probe
# policy is configured once per mount and every role verifies by default.
# Revocation still crosses from the Cloud Ops resource plane to the auth plane,
# so keep one waiter for the deliberately reused key. Several consecutive
# failures are required because a single auth probe can be unreliable.
CONFIRM_REVOKED=3

# Print a dot per probe. Without it the screen sits blank, which reads as a hang
# at the most dramatic moment of the demo.
wait_for_key_revoked() {
    local streak=0
    for _ in {1..20}; do
        if temporal cloud namespace list --api-key "$1" >/dev/null 2>&1; then
            streak=0
        else
            streak=$((streak + 1))
            [[ $streak -ge $CONFIRM_REVOKED ]] && {
                printf '\nkey is dead\n'
                return 0
            }
        fi
        printf '.'
        sleep 3
    done
    printf '\nkey still works — revocation did not reach the auth layer\n' >&2
    return 1
}

# demo-magic's `pe` evals in this shell, so the vault() function, every .env
# value, and the SA_BROAD/SA_SCOPED role names common.sh derives are all in
# scope for the commands typed below.
#
# temporal is spelled out in full at every call site rather than wrapped in a short
# helper. The commands on screen are meant to be ones an audience can copy into
# their own shell, and a local alias is neither copyable nor searchable.

say() { printf '\n\033[1;33m%s\033[0m\n' "$1"; }

# demo-magic's `pe` runs its argument through `eval`, so a nonzero exit trips the
# `set -e` inherited from common.sh and ends the demo instantly, with no error
# and no hint about what to do next. That is right for steps that must succeed —
# if the plugin won't mount, stop. It is wrong for steps whose failure is
# survivable and informative: a lease that aged out during a long Q&A, a
# read-only listing against Temporal Cloud. Those use pe_ok and the walkthrough
# goes on.
pe_ok() { pe "$@" || printf '\033[90m(that command failed — continuing)\033[0m\n'; }

# One outstanding lease ID for a role, or empty if there are none. `vault list`
# exits nonzero on an empty list and `jq '.[0]'` would return the *string*
# "null", so a naive lookup either kills the demo or builds a renew command for
# a lease named "null". Both are handled here rather than at each call site.
first_lease() {
    vault list -format=json "sys/leases/lookup/$MOUNT/creds/$1" 2>/dev/null |
        jq -r '.[0] // empty' || true
}

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

The problem: Temporal Cloud API keys are static. People paste them into CI, into
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
# In production Vault refuses to load a plugin whose binary does not hash to the
# value it was registered with — that is the supply-chain check, and it is why
# the release ships a _SHA256SUMS file. scripts/fetch-plugin.sh already verified
# the archive; this registers the extracted binary by its own hash.
#
# Be honest about this one if asked: docker-compose.yml runs Vault with
# -dev-plugin-dir, which auto-registers everything in the directory, so the
# engine would mount here even without this command. What you are watching is a
# faithful illustration of the production step, not a live demonstration of it.
# To demonstrate it for real, register a deliberately wrong hash and watch
# `secrets enable` refuse.
PLUGIN_SHA="$(cat "$REPO_ROOT/.plugin-cache/binary.sha256")"

pe "vault plugin register -sha256=$PLUGIN_SHA secret $PLUGIN_NAME"
pe "vault secrets enable -path=$MOUNT $PLUGIN_NAME"

########################################################################
say "2. Give Vault one temporary bootstrap credential"
########################################################################
say "The personal key in .env is only the setup identity. This run created a temporary Global Admin service account and a disposable 24-hour key for Vault to consume."

# One field. Everything else about this credential, Vault works out for itself.
#
# api_key_id has been read-only since 0.1.0: a Temporal Cloud API key is a JWT
# that names its own ID, so the engine reads it out of the key rather than
# trusting a pasted value.
#
# The plugin also derives admin_service_account_id. The key's own ID is enough to ask
# Cloud Ops who owns it, so the owning service account is derived too — and the
# same lookup rejects a user-owned key here, at config time, instead of at the
# first `vault read creds/...`. Supplying the field is still allowed as a
# cross-check, but there is nothing an operator can get right that the key does
# not already say.
# Kept on one line on purpose: demo-magic runs commands through `eval $@`
# unquoted, so backslash-continuations get mangled before Vault ever sees them.
pe "vault write $MOUNT/config api_key=\"\$DEMO_BOOTSTRAP_KEY\""

# These are the plugin's own defaults (client/probe.go: 50ms, ten successes), so this
# write changes nothing. It is here to put the knob on screen: the sampling
# policy is set once per mount rather than per role, and an account that
# propagates slowly is tuned here and nowhere else. Say so rather than letting
# the narration imply the demo had to configure it.
say "Propagation sampling is one policy for the whole mount, not a per-role setting. These are the plugin's defaults — writing them changes nothing, but this is the knob to turn if an account propagates slowly."
pe "vault write $MOUNT/config/probe interval=50ms consecutive_successes=10"

say "Read them back — the bootstrap key never comes out again, but note api_key_id and admin_service_account_id: Vault derived both from the key itself."
pe "vault read $MOUNT/config"
pe "vault read $MOUNT/config/probe"

########################################################################
say "3. Define three roles: broad, least-privilege, and metrics-only"
########################################################################
# Each of these creates a real service account in Temporal Cloud. They are
# templates, not credentials — no API key exists yet.
say "Role A — account-wide read, and nothing else."
pe "vault write $MOUNT/service-accounts/$SA_BROAD account_role=read ttl=5m max_ttl=1h description='Account-wide read, issued by Vault'"

say "Role B — that same account-level read, plus write on exactly one namespace."
# Say this one accurately: B is A *plus* a namespace grant, not a narrower
# version of it. The least-privilege story is that a worker gets write on the
# single namespace it runs in and nowhere else — not that B outranks A.
# The `read` floor is this plugin's rule (account_role is required on every
# write), not Temporal Cloud's: the Cloud API accepts a service account with no
# account-level role at all.
# No verify_propagation here: the plugin turns it on by default. All three roles get
# it, but only this one has a namespace_access entry, and a namespace grant is
# the only thing there is to verify — so B is where it does any work.
pe "vault write $MOUNT/service-accounts/$SA_SCOPED account_role=read namespace_access=\"\$TEMPORAL_NAMESPACE=write\" ttl=5m max_ttl=1h description='Account read, plus write on one namespace'"

pe "vault read $MOUNT/service-accounts/$SA_SCOPED"

say "Role C — a different account role entirely: metrics, and nothing else."
# metrics-read exists for the Prometheus/Datadog scrapers that need the Cloud
# metrics endpoint and have no business reading workflows. Worth naming out
# loud: the account role is the axis, namespace_access is the other, and a role
# here is any point on that grid — not just "read" with more or less on top.
pe "vault write $MOUNT/service-accounts/$SA_METRICS account_role=metrics-read ttl=5m max_ttl=1h description='Metrics scraper: no namespace access at all'"

say "All three service accounts now exist in Temporal Cloud:"
# The CLI's own table, filtered to this demo's accounts rather than reshaped by
# jq. --page-size guards against the three just created falling off a first page
# on a busy account; the grep keeps unrelated accounts off the projector.
pe "temporal cloud service-account list --api-key \"\$TEMPORAL_CLOUD_API_KEY\" --page-size 100 | grep demo-app-"

say "And one of them in full, as Temporal Cloud sees it — note the role and the single namespace grant:"
# `get` rather than `list`, because the role is only legible here: `list -o json`
# returns the account role as an integer enum (read is 5), while `get` renders it
# as ROLE_READ. Worth knowing before building anything else on this CLI's JSON.
#
# The ID comes from Vault, which recorded it when it created the account — so
# this is Vault's own record being looked up in Temporal Cloud, not a name match.
pe "temporal cloud service-account get --service-account-id \$(vault read -field=service_account_id $MOUNT/service-accounts/$SA_SCOPED) --api-key \"\$TEMPORAL_CLOUD_API_KEY\""

########################################################################
say "4. Ask Vault for a credential"
########################################################################
pe "vault read $MOUNT/creds/$SA_BROAD"

# Same command, twice more. Nothing is cached and nothing is shared: every read
# mints a brand-new API key in Temporal Cloud under its own lease, so lease_id
# and api_key_id differ each time.
say "Run the exact same command twice more — watch lease_id and api_key_id change."
pe "vault read $MOUNT/creds/$SA_BROAD"
pe "vault read $MOUNT/creds/$SA_BROAD"

say "Three reads, three independent leases:"
pe_ok "vault list sys/leases/lookup/$MOUNT/creds/$SA_BROAD"

# The independence is worth proving rather than asserting: revoke one lease and
# the other two keep working. This is what lets one consumer's credential be
# pulled without an outage for everyone else sharing the role. (Step 6 uses
# -prefix to revoke a whole role at once, which is the other, blunter tool.)
ONE_LEASE="$(first_lease "$SA_BROAD")"
if [[ -n "$ONE_LEASE" ]]; then
    say "Revoke exactly one of the three:"
    pe_ok "vault lease revoke $MOUNT/creds/$SA_BROAD/$ONE_LEASE"
    say "The other two are untouched:"
    pe_ok "vault list sys/leases/lookup/$MOUNT/creds/$SA_BROAD"
fi

say "Capture one and actually use it."
pe "API_KEY=\$(vault read -field=api_key $MOUNT/creds/$SA_SCOPED)"

say "The plugin verified the key on ten independent frontend connections before Vault returned it — on by default, nothing to opt into:"
# Be careful what this claims. The command proves the key authenticates;
# propagation verification is what tested the namespace grant before the creds
# read returned. Demonstrating exclusion would take a second namespace this key
# was deliberately not given.
pe_ok "temporal cloud namespace list --api-key \"\$API_KEY\""

say "A credential Vault minted seconds ago, authenticating against Temporal Cloud."
pause

########################################################################
say "5. The lease is the leash"
########################################################################
pe_ok "vault list sys/leases/lookup/$MOUNT/creds/$SA_SCOPED"

say "Renewing extends the lease — and never calls Temporal Cloud."
# The key is minted with a Cloud-side expiry well past max_ttl, so renewal is
# pure Vault bookkeeping. It also means a Vault crash leaves a key that expires
# on its own rather than lingering forever.
# The guard matters live: the lease is 5 minutes, and a long Q&A after step 4
# will outlast it. Without this the demo dies here with no message at all.
LEASE_ID="$(first_lease "$SA_SCOPED")"
if [[ -n "$LEASE_ID" ]]; then
    pe "vault lease renew $MOUNT/creds/$SA_SCOPED/$LEASE_ID"
else
    say "That lease already expired — Vault revoked the key on its own. Re-read $MOUNT/creds/$SA_SCOPED to mint another."
fi

say "Here are the keys Vault has minted, as Temporal Cloud sees them:"
# Vault names every key it mints "vault-<role>-<random>", which is how you tell
# Vault-issued credentials from hand-created ones in the Temporal Cloud UI.
# jq rather than the plain table here because expiry is the whole point of this
# step, and the table has no expiry column. `expiry_time` arrives as an epoch
# object, so `.seconds | todate` is what makes it readable.
pe_ok "temporal cloud apikey list --api-key \"\$TEMPORAL_CLOUD_API_KEY\" -o json | jq -r '.ApiKeys[] | select(.spec.display_name | startswith(\"vault-demo-app-\")) | \"\\(.spec.display_name)\\texpires \\(.spec.expiry_time.seconds | todate)\"'"

# The expiry on screen says ~24h while the lease says 5m, and that contradiction
# is the first thing a security-minded audience asks about. Answer it unprompted:
# Temporal Cloud rejects any API key expiry under 24 hours, so the plugin floors
# it there. Vault revokes at 5 minutes; the 24h is only the backstop.
printf '\033[90m  The lease is 5 minutes. The Cloud-side expiry is 24 hours because\n  Temporal Cloud does not accept less — it is the self-destruct if Vault\n  dies before it can revoke, not the credential lifetime.\033[0m\n'

########################################################################
say "6. Revoke — and watch them disappear from Temporal Cloud"
########################################################################
pe "vault lease revoke -prefix $MOUNT/creds/$SA_BROAD"
pe "vault lease revoke -prefix $MOUNT/creds/$SA_SCOPED"

say "Vault has already deleted it in Temporal Cloud. Same key, seconds later:"
# pe_ok, not pe: if this times out the rejection below is still the evidence
# worth showing. A timeout must not swallow the punchline.
pe_ok "wait_for_key_revoked \"\$API_KEY\""
# Expected to fail. That failure is the whole demo.
pe "temporal cloud namespace list --api-key \"\$API_KEY\" || echo '>>> rejected — the key no longer exists in Temporal Cloud'"

say "Deleted, not just forgotten — the same list from a minute ago:"
# The rejection above proves one key stopped working. This proves all of them
# are gone from Temporal Cloud entirely, which is the stronger claim the closing
# slide makes. Expect 0.
pe_ok "temporal cloud apikey list --api-key \"\$TEMPORAL_CLOUD_API_KEY\" -o json | jq '[.ApiKeys[] | select(.spec.display_name | startswith(\"vault-demo-app-\"))] | length'"

pause

########################################################################
say "7. Retire the temporary bootstrap key"
########################################################################
# rotate-root deletes the disposable key created for this run. The personal
# setup key in .env is never handed to Vault and remains available to remove the
# temporary admin service account when the script exits.
say "Everything so far rested on the temporary bootstrap key created for this run. Note the api_key_id Vault is holding now:"
pe "vault read $MOUNT/config"

say "rotate-root mints a replacement on the same service account, verifies it, stores it, and deletes the key it replaced."
pe "vault write -f $MOUNT/config/rotate-root"

say "Different api_key_id. Vault minted this one for itself, and no human has ever seen it:"
pe "vault read $MOUNT/config"

say "The temporary bootstrap key is now gone from Temporal Cloud. This is expected to fail:"
# The strongest proof available: the disposable credential supplied to Vault
# is the one being rejected. The setup key in .env remains untouched.
pe "temporal cloud namespace list --api-key \"\$DEMO_BOOTSTRAP_KEY\" || echo '>>> rejected — the temporary bootstrap key no longer exists'"

say "Vault carries on regardless, still minting against Temporal Cloud:"
# Proof the mount is healthy on the new credential rather than merely quiet.
# This mints one more key, which `make reset` cleans up with everything else.
pe "vault read $MOUNT/creds/$SA_BROAD"

########################################################################
say "That's the model"
########################################################################
# Held back from the printed summary — talk track, not slide. Paste the block
# back inside the heredoc below to show it on screen again. It cannot be
# commented out in place: heredoc content is literal, so a leading '#' would
# print rather than comment.
#
# Worth mentioning if it comes up:
#   - Temporal Cloud caps a service account at 20 non-expired keys, so that is
#     the ceiling on concurrent leases per role.
#   - The replacement root key carries root_key_ttl (90 days by default), so
#     even Vault's own credential expires. Running rotate-root again before then
#     is how you keep it fresh, and nothing outside Vault ever holds it.
cat <<'EOF'

  - No human ever saw a key an application uses. The demo created its own
    temporary bootstrap key in step 2, and step 7 deleted it.
  - The personal setup key in .env remains available for cleanup and future
    demos; the temporary admin service account is removed when this script exits.
  - Access is scoped per role, not per person.
  - Revocation is one command, and it is real: the credential is deleted in
    Temporal Cloud, not just forgotten by Vault.

To delete the service accounts and tear Vault down, run `make reset`.

EOF

printf '\033[1;32mThe personal key in .env was not handed to Vault and still works.\n'
printf "The temporary bootstrap service account will be removed as the demo exits.\n"
printf "Run 'make reset'\n"
printf 'to remove the application service accounts and stop Vault.\033[0m\n\n'
