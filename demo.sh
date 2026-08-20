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
    existing="$(tcld --api-key "$TEMPORAL_API_KEY" service-account list --page-size 100 2>/dev/null |
        jq -r '.serviceAccount[]? | select(.spec.name | startswith("demo-app-")) | .spec.name' || true)"
    [[ -z "$existing" ]] && return 0
    echo "ERROR: these demo service accounts already exist in Temporal Cloud:" >&2
    echo "$existing" | sed 's/^/  - /' >&2
    echo "Vault will refuse to recreate them. Run 'make reset' first." >&2
    exit 1
}
preflight_clean

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

# Read-only helper so the narration commands look like the real thing on screen.
tc() { tcld --api-key "$TEMPORAL_API_KEY" "$@"; }

# These two waiters exist for one specific reason, and it is NOT that the plugin
# fails to confirm its work. It does: every mutating Cloud Ops call reads the
# resource back and blocks until it reached the requested state
# (client/confirm.go), with deletion confirmed by RESOURCE_STATE_DELETED rather
# than by waiting for a NotFound. Against the Cloud Ops API, no waiting is
# needed anywhere in this demo — that is why nothing else here polls.
#
# But this demo does not verify through the Cloud Ops API. It verifies by
# *authenticating with the key* (`tcld --api-key "$API_KEY" ...`), and that is a
# different plane with its own lag. Measured on back-to-back runs of this exact
# script: one run had both transitions instant, the next had a freshly minted key
# rejected with Unauthenticated AND a revoked key still listing namespaces — even
# though `apikey list` confirmed zero keys remained. Resource-plane consistency
# does not imply auth-plane consistency.
#
# So: no polling around anything the engine guarantees, polling only around the
# two calls that authenticate. Several consecutive identical results are required
# because a single probe is unreliable in either direction.
CONFIRM_VALID=2
CONFIRM_REVOKED=3

# Both waiters print a dot per probe. Without it the screen sits blank, which
# reads as a hang at the two most dramatic moments of the demo.
wait_for_key_valid() {
    local streak=0
    for _ in {1..20}; do
        if tcld --api-key "$1" namespace list >/dev/null 2>&1; then
            streak=$((streak + 1))
            [[ $streak -ge $CONFIRM_VALID ]] && {
                printf '\nkey is live\n'
                return 0
            }
        else
            streak=0
        fi
        printf '.'
        sleep 3
    done
    printf '\nkey never became valid — check the Temporal Cloud UI\n' >&2
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

# demo-magic's `pe` evals in this shell, so the vault() and tc() functions,
# every .env value, and the SA_BROAD/SA_SCOPED role names common.sh derives are
# all in scope for the commands typed below.

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
say "2. Give Vault one bootstrap credential — the last static key"
########################################################################
# admin_service_account_id is required and not optional trivia: an API key
# token does not say who owns it, and the Cloud Ops API cannot look it up, so
# Vault has to be told.
# Two fields, not three: as of plugin 0.1.0 api_key_id is read-only and a
# supplied value is rejected outright. A Temporal Cloud API key is a JWT that
# names its own ID, so the engine reads it out of the key — which means the ID
# rotate-root will one day delete always matches the key actually stored,
# instead of whatever an operator pasted next to it.
# Kept on one line on purpose: demo-magic runs commands through `eval $@`
# unquoted, so backslash-continuations get mangled before Vault ever sees them.
pe "vault write $MOUNT/config api_key=\"\$TEMPORAL_API_KEY\" admin_service_account_id=\"\$TEMPORAL_ADMIN_SA_ID\""

say "Read it back — the key never comes out again, but note api_key_id: Vault derived that from the key itself."
pe "vault read $MOUNT/config"

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
pe "vault write $MOUNT/service-accounts/$SA_SCOPED account_role=read namespace_access=\"\$TEMPORAL_NAMESPACE=write\" ttl=5m max_ttl=1h description='Account read, plus write on one namespace'"

pe "vault read $MOUNT/service-accounts/$SA_SCOPED"

say "Role C — a different account role entirely: metrics, and nothing else."
# metrics-read exists for the Prometheus/Datadog scrapers that need the Cloud
# metrics endpoint and have no business reading workflows. Worth naming out
# loud: the account role is the axis, namespace_access is the other, and a role
# here is any point on that grid — not just "read" with more or less on top.
pe "vault write $MOUNT/service-accounts/$SA_METRICS account_role=metrics-read ttl=5m max_ttl=1h description='Metrics scraper: no namespace access at all'"

say "All three service accounts now exist in Temporal Cloud:"
# --page-size matters: tcld pages at 10 by default, so on a busy account the
# three just created can fall off the first page entirely. Filtering to
# demo-app- also keeps unrelated service accounts off the projector.
pe "tc service-account list --page-size 100 | jq -r '.serviceAccount[] | select(.spec.name | startswith(\"demo-app-\")) | \"\\(.spec.name)\\t\\(.spec.access.accountAccess.role)\"'"

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

say "The key exists the moment Vault returns it. Its auth layer needs a beat:"
pe_ok "wait_for_key_valid \"\$API_KEY\""
# Be careful what this claims. It proves the key authenticates — nothing more.
# `namespace list` succeeds on the account-level `read`, not on the namespace
# grant, so it is not evidence of scoping. Demonstrating the scoping would take
# a second namespace this key was deliberately not given.
pe_ok "tcld --api-key \"\$API_KEY\" namespace list"

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
pe_ok "tc apikey list | jq -r '.apiKeys[] | select(.spec.displayName | startswith(\"vault-demo-app-\")) | \"\\(.spec.displayName)\\texpires \\(.spec.expiryTime)\"'"

# The expiry on screen says ~24h while the lease says 5m, and that contradiction
# is the first thing a security-minded audience asks about. Answer it unprompted:
# Temporal Cloud rejects any API key expiry under 24 hours, so the plugin floors
# it there. Vault revokes at 5 minutes; the 24h is only the backstop.
printf '\033[90m  The lease is 5 minutes. The Cloud-side expiry is 24 hours because\n  Temporal Cloud will not accept less — it is the self-destruct if Vault\n  dies before it can revoke, not the credential lifetime.\033[0m\n'

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
pe "tcld --api-key \"\$API_KEY\" namespace list || echo '>>> rejected — the key no longer exists in Temporal Cloud'"

say "Deleted, not just forgotten — the same list from a minute ago:"
# The rejection above proves one key stopped working. This proves all of them
# are gone from Temporal Cloud entirely, which is the stronger claim the closing
# slide makes. Expect 0.
pe_ok "tc apikey list | jq '[.apiKeys[] | select(.spec.displayName | startswith(\"vault-demo-app-\"))] | length'"

########################################################################
say "That's the model"
########################################################################
cat <<'EOF'

  - No human ever saw a key an application uses. Exactly one long-lived key
    exists — the bootstrap key in step 2 — and rotate-root retires even that.
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
