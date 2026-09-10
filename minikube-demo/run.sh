#!/usr/bin/env bash
#
# A Temporal worker in Kubernetes, holding an API key that Vault issued and
# will delete when its lease ends.
#
#   ./run.sh up        bring up Vault, VSO, minikube, the image and the worker
#   ./run.sh transfer  start one money transfer from this laptop
#   ./run.sh status    what exists right now, on all three sides
#   ./run.sh watch     watch VSO replace the credential, live
#   ./run.sh logs      read the worker's logs
#   ./run.sh down      remove everything this script created
#
# The argument: a long-running worker and a credential measured in minutes are
# not in conflict. The worker re-reads its key on every request, so Vault can
# delete the key it started with and the process never notices.

# common.sh loads .env, derives VAULT_ADDR from VAULT_PORT, and defines the
# vault() wrapper that drives the CLI inside the container. Reused rather than
# duplicated so this demo can never disagree with the parent one about ports,
# credentials or the mount path.
# shellcheck source=../scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"

DEMO_DIR="$REPO_ROOT/minikube-demo"
K8S_NAMESPACE="temporal-demo"
IMAGE="money-transfer-worker:local"
SECRET_NAME="temporal-api-key"
DEPLOYMENT="money-transfer-worker"
TASK_QUEUE="TRANSFER_MONEY_TASK_QUEUE"

# The worker's Vault role is dedicated to VSO. ttl == max_ttl is the point:
# renewal can never extend a lease, so VSO must mint a genuinely new Temporal
# Cloud API key every couple of minutes instead of keeping one key alive.
WORKER_ROLE="demo-k8s-worker-vso"
WORKER_TTL="2m"

# Older versions of this demo had a script-managed Secret path under this role.
# `down` still removes it so a checkout upgraded in place can be cleaned fully;
# no current command reads credentials from it or writes them into Kubernetes.
LEGACY_WORKER_ROLE="demo-k8s-worker"

# Kubernetes auth, so nothing in the cluster holds a long-lived Vault
# credential. VSO presents its ServiceAccount token; Vault verifies it with the
# cluster's own TokenReview API and hands back a short-lived Vault token.
K8S_AUTH_PATH="kubernetes"
K8S_AUTH_ROLE="temporal-worker"
K8S_AUTH_POLICY="temporal-worker-vso"
K8S_AUTH_AUDIENCE="vault"
VSO_SA="vso-temporal"

# Pinned. An operator that changes version between demos is a variable nobody
# wants to discover on stage.
VSO_CHART_VERSION="1.5.1"
VSO_NAMESPACE="vault-secrets-operator-system"

say() { printf '\n\033[1;33m==> %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }
fail() {
    printf '\033[1;31mERROR: %s\033[0m\n' "$1" >&2
    exit 1
}

kc() { kubectl --namespace "$K8S_NAMESPACE" "$@"; }

########################################################################
# Preflight
########################################################################
preflight() {
    for cmd in minikube kubectl docker jq temporal helm; do
        require_cmd "$cmd"
    done
    docker info >/dev/null 2>&1 || fail "the Docker daemon is not running"
}

# The regional gRPC endpoint and the namespace both differ per Temporal Cloud
# account, so they are read from the account rather than hardcoded. An API key
# authenticates against the regional endpoint, which is not the same host as the
# mTLS one in the namespace's `grpc` field — using that one fails in a way that
# looks like a credential problem and is not.
resolve_endpoint() {
    local ns_json
    ns_json="$(temporal cloud namespace get --namespace "$TEMPORAL_NAMESPACE" \
        --api-key "$TEMPORAL_CLOUD_API_KEY" -o json 2>/dev/null)" ||
        fail "could not read namespace $TEMPORAL_NAMESPACE from Temporal Cloud"

    # camelCase here, unlike `service-account list -o json` which is snake_case
    # under a capitalised envelope. The shape is per-subcommand, so both spellings
    # appear in this repo on purpose.
    TEMPORAL_ADDRESS="$(jq -r '.endpoints.grpcAddress // empty' <<<"$ns_json")"
    [[ -n "$TEMPORAL_ADDRESS" ]] ||
        fail "namespace $TEMPORAL_NAMESPACE reports no regional gRPC endpoint"

    # A boolean now rather than an authMethod string: the namespace can have API
    # key auth enabled alongside mTLS, so this asks whether keys are accepted
    # rather than which single method is configured.
    local api_key_auth
    api_key_auth="$(jq -r '.spec.apiKeyAuth.enabled // false' <<<"$ns_json")"
    [[ "$api_key_auth" == "true" ]] ||
        fail "namespace $TEMPORAL_NAMESPACE does not have API key auth enabled"
}

########################################################################
# Vault: the secrets engine and this demo's role
########################################################################
# Every step here is written to be safe on a second run: `up` is the recovery
# path after a half-finished demo, so it cannot be a command that only works
# once.
vault_up() {
    say "Vault"
    if vault status >/dev/null 2>&1; then
        info "already running at $VAULT_ADDR"
    else
        (cd "$REPO_ROOT" && make up >/dev/null) || fail "could not start Vault"
        info "started at $VAULT_ADDR"
    fi

    if vault secrets list -format=json 2>/dev/null | grep -q "\"$MOUNT/\""; then
        info "$MOUNT/ already mounted"
    else
        local sha
        sha="$(cat "$REPO_ROOT/.plugin-cache/binary.sha256")"
        vault plugin register -sha256="$sha" secret "$PLUGIN_NAME" >/dev/null
        vault secrets enable -path="$MOUNT" "$PLUGIN_NAME" >/dev/null
        info "registered by sha256 and mounted at $MOUNT/"
    fi

    if vault read "$MOUNT/config" >/dev/null 2>&1; then
        info "bootstrap credential already configured"
    else
        # One field: the plugin derives both the key's ID and its owning service
        # account from the key itself.
        vault write "$MOUNT/config" \
            api_key="$TEMPORAL_CLOUD_API_KEY" >/dev/null
        info "bootstrap credential configured"
    fi

    vault write "$MOUNT/config/probe" \
        interval=50ms consecutive_successes=10 >/dev/null ||
        fail "could not configure propagation probes"
    info "propagation probe configured (10 successes, 50ms interval)"
}

vault_role() {
    say "Vault role for VSO"
    if vault read "$MOUNT/service-accounts/$WORKER_ROLE" >/dev/null 2>&1; then
        info "$WORKER_ROLE already exists"
        return
    fi

    # Vault runs in dev mode here, so restarting its container wipes every role
    # while the Temporal Cloud service accounts those roles created live on. The
    # plugin will not mint against an account it did not create, so without this
    # `up` fails permanently on a name it created itself — and `up` is the
    # documented recovery path after a half-finished demo.
    #
    # force=true adopts the orphan and resets its permissions to the spec below.
    # Adoption also makes it fully Vault-managed again, which is what puts it
    # back within reach of `down`.
    #
    # Decided by asking Temporal Cloud rather than by matching the plugin's
    # error text, which is not an API and changes between versions.
    #
    # verify_propagation below is the plugin's default. It is passed explicitly so
    # this demo's behaviour stays put if that default ever moves again.
    local force=false adopted="" existing_id="" out=""
    existing_id="$(temporal cloud service-account list --api-key "$TEMPORAL_CLOUD_API_KEY" \
        --page-size 100 -o json 2>/dev/null |
        jq -r --arg n "$WORKER_ROLE" \
            'first(.ServiceAccounts[]? | select(.spec.name == $n) | .id) // empty')" || true
    if [[ -n "$existing_id" ]]; then
        force=true
        adopted=", adopted from a previous run"
    fi

    if ! out="$(vault write "$MOUNT/service-accounts/$WORKER_ROLE" \
        account_role=read \
        namespace_access="$TEMPORAL_NAMESPACE=write" \
        verify_propagation=true \
        force="$force" \
        ttl="$WORKER_TTL" max_ttl="$WORKER_TTL" \
        description='Money-transfer worker, credential synced by VSO' 2>&1)"; then

        # The plugin adopts by issuing UpdateServiceAccount unconditionally,
        # and Temporal Cloud rejects an update that changes nothing. An orphan
        # this demo created already matches this spec exactly, so the most
        # ordinary recovery of all is the one adoption cannot complete. Say so
        # with the command that fixes it rather than printing a Vault 400 and
        # leaving the operator to work it out mid-demo.
        if [[ "$out" == *"nothing to change"* ]]; then
            printf '\033[1;31mERROR: %s already exists in Temporal Cloud (id %s) with exactly\n' \
                "$WORKER_ROLE" "$existing_id" >&2
            printf '  these permissions, and plugin %s cannot adopt an account it has nothing\n' \
                "$PLUGIN_VERSION" >&2
            printf '  to change. Delete the orphan and re-run ./run.sh up:\n\n' >&2
            printf '    temporal cloud service-account delete \\\n' >&2
            printf '      --service-account-id %s \\\n' "$existing_id" >&2
            printf '      --api-key "$TEMPORAL_CLOUD_API_KEY"\n\033[0m' >&2
            exit 1
        fi

        printf '%s\n' "$out" >&2
        fail "could not create $WORKER_ROLE"
    fi
    info "created $WORKER_ROLE (ttl=max_ttl=$WORKER_TTL, propagation verified$adopted)"
}

vault_k8s_auth() {
    say "Vault Kubernetes auth"

    vault auth list -format=json 2>/dev/null |
        jq -e --arg p "$K8S_AUTH_PATH/" 'has($p)' >/dev/null ||
        vault auth enable "$K8S_AUTH_PATH" >/dev/null

    # Vault runs in a container on a different docker network from minikube, so
    # the address kubectl uses is wrong here twice over: it is a host-forwarded
    # port, and inside the Vault container 127.0.0.1 is the container itself.
    # The minikube container's own address is what works — Docker Desktop routes
    # between the two bridge networks.
    local api_server reviewer_jwt ca_cert
    api_server="https://$(minikube ip):8443"

    # Vault has no in-cluster ServiceAccount token to authenticate its
    # TokenReview calls with, so it is given one belonging to a ServiceAccount
    # that holds system:auth-delegator and nothing else.
    reviewer_jwt="$(kc get secret vault-auth-token \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)"
    [[ -n "$reviewer_jwt" ]] ||
        fail "vault-auth-token is empty — apply k8s/vso/rbac.yaml first"

    ca_cert="$(cat "$HOME/.minikube/ca.crt")" ||
        fail "could not read $HOME/.minikube/ca.crt"

    # disable_local_ca_jwt because Vault is not running in this cluster and has
    # no in-pod CA bundle or token to fall back on.
    vault write "auth/$K8S_AUTH_PATH/config" \
        kubernetes_host="$api_server" \
        kubernetes_ca_cert="$ca_cert" \
        token_reviewer_jwt="$reviewer_jwt" \
        disable_local_ca_jwt=true >/dev/null ||
        fail "could not configure auth/$K8S_AUTH_PATH"
    info "configured against $api_server"

    # Least privilege, and worth reading aloud in a demo: VSO can read exactly
    # one credential path and do nothing else in Vault.
    printf 'path "%s/creds/%s" {\n  capabilities = ["read"]\n}\n' \
        "$MOUNT" "$WORKER_ROLE" |
        vault policy write "$K8S_AUTH_POLICY" - >/dev/null ||
        fail "could not write policy $K8S_AUTH_POLICY"
    info "wrote policy $K8S_AUTH_POLICY (read on $MOUNT/creds/$WORKER_ROLE)"

    # The audience is set even though Vault 1.20 does not require it: 1.21 makes
    # it mandatory, and a role without one starts failing on a Vault upgrade
    # rather than at the moment it was misconfigured. It must match the
    # audiences field in k8s/vso/vault-auth.yaml, because that is what VSO asks
    # the apiserver to mint its token for.
    vault write "auth/$K8S_AUTH_PATH/role/$K8S_AUTH_ROLE" \
        bound_service_account_names="$VSO_SA" \
        bound_service_account_namespaces="$K8S_NAMESPACE" \
        audience="$K8S_AUTH_AUDIENCE" \
        token_policies="$K8S_AUTH_POLICY" \
        ttl=1h >/dev/null ||
        fail "could not create auth role $K8S_AUTH_ROLE"
    info "role $K8S_AUTH_ROLE bound to $K8S_NAMESPACE/$VSO_SA (audience=$K8S_AUTH_AUDIENCE)"
}

vso_install() {
    say "Vault Secrets Operator"
    if helm status vault-secrets-operator -n "$VSO_NAMESPACE" >/dev/null 2>&1; then
        info "already installed"
    else
        helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
        helm repo update hashicorp >/dev/null 2>&1
        helm install vault-secrets-operator hashicorp/vault-secrets-operator \
            --version "$VSO_CHART_VERSION" \
            --namespace "$VSO_NAMESPACE" --create-namespace \
            --wait --timeout 5m >/dev/null ||
            fail "could not install the Vault Secrets Operator"
        info "installed chart $VSO_CHART_VERSION"
    fi

    # Selected by label rather than by name: the chart's Deployment name is its
    # own business and has changed between versions.
    kubectl wait --for=condition=Available deployment \
        -l app.kubernetes.io/name=vault-secrets-operator \
        -n "$VSO_NAMESPACE" --timeout=180s >/dev/null ||
        fail "the operator did not become ready"
    info "operator ready"
}

apply_vso_manifests() {
    say "VSO custom resources"
    kc apply -f "$DEMO_DIR/k8s/vso/rbac.yaml" >/dev/null ||
        fail "could not apply k8s/vso/rbac.yaml"

    # Substituted rather than committed: the Vault port comes from .env so the
    # demo can move off 8200 when something else is holding it.
    sed -e "s|PLACEHOLDER_VAULT_ADDRESS|http://host.minikube.internal:${VAULT_PORT:-8200}|" \
        "$DEMO_DIR/k8s/vso/vault-connection.yaml" | kc apply -f - >/dev/null ||
        fail "could not apply the VaultConnection"

    kc apply -f "$DEMO_DIR/k8s/vso/vault-auth.yaml" >/dev/null ||
        fail "could not apply the VaultAuth"
    kc apply -f "$DEMO_DIR/k8s/vso/dynamic-secret.yaml" >/dev/null ||
        fail "could not apply the VaultDynamicSecret"
    info "applied rbac, VaultConnection, VaultAuth, VaultDynamicSecret"
}

# Mints a key and prints "<lease_id> <api_key>". This is used only for the
# short-lived local starter and verification probes. The Worker's credential is
# read by VSO directly from Vault and is never handled by this script.
mint_key() {
    local out
    out="$(vault read -format=json "$MOUNT/creds/$1")" ||
        fail "could not read $MOUNT/creds/$1"
    jq -r '"\(.lease_id) \(.data.api_key)"' <<<"$out"
}

# A credential for one command — the starter, or a probe that queries Temporal
# Cloud — as distinct from the dynamic credential VSO supplies to the Worker.
#
# These are revoked on the way out rather than left to expire, because Temporal
# Cloud caps a service account at 20 non-expired keys and a demo being driven
# from the keyboard mints them faster than a two-minute TTL retires them. Without
# this, the twentieth `transfer` fails for a reason that has nothing to do with
# what is being demonstrated.
TEMP_LEASES=()

# Sets TEMP_KEY rather than printing the key, and that is not a style choice.
# A function whose output is captured with $(...) runs in a subshell, so the
# TEMP_LEASES entry it appended would be discarded when that subshell exits —
# leaving every temporary key to sit in the quota until it expired. Assigning to
# a global keeps the bookkeeping in the shell that owns the trap.
TEMP_KEY=""

mint_temp_key() {
    local lease
    read -r lease TEMP_KEY <<<"$(mint_key "$1")"
    # mint_key's fail() runs inside $(...), so its `exit 1` ends only that
    # subshell — this function keeps going with an empty key. `read` does not
    # catch it either: an empty substitution is still a line, so it returns 0.
    # Testing the value is the only thing that works, and without it the array
    # append below would make every failure look like a success to the caller.
    [[ -n "$TEMP_KEY" ]] || return 1
    TEMP_LEASES+=("$lease")
}

# On the EXIT trap so a failed or interrupted run cleans up too — the case that
# would otherwise quietly fill the quota.
revoke_temp_keys() {
    local lease
    for lease in ${TEMP_LEASES[@]+"${TEMP_LEASES[@]}"}; do
        vault lease revoke "$lease" >/dev/null 2>&1 || true
    done
    TEMP_LEASES=()
}
trap revoke_temp_keys EXIT

########################################################################
# minikube and the image
########################################################################
minikube_up() {
    say "minikube"
    if minikube status --format '{{.Host}}' 2>/dev/null | grep -q Running; then
        info "already running"
    else
        # Deliberately not silenced. Creating a cluster for the first time pulls
        # an ISO and the control-plane images, which takes minutes — hiding that
        # output turns a working script into one that looks wedged.
        info "starting a cluster (first run pulls images; this takes a few minutes)"
        minikube start || fail "could not start minikube"
    fi
    kubectl get namespace "$K8S_NAMESPACE" >/dev/null 2>&1 ||
        kubectl create namespace "$K8S_NAMESPACE" >/dev/null
    info "namespace $K8S_NAMESPACE ready"
}

build_image() {
    say "Worker image"
    # Built by the host daemon, then side-loaded. The build cache stays on the
    # host, so a rebuild after a code change is seconds rather than a full
    # module download inside the cluster's daemon.
    # Also not silenced: the first build downloads the Go toolchain image and
    # the module cache, and the transfer into the cluster moves ~15MB.
    docker build -t "$IMAGE" "$DEMO_DIR" || fail "docker build failed"
    info "built $IMAGE"
    minikube image load "$IMAGE" || fail "could not load $IMAGE into minikube"
    info "loaded into the cluster"
}

########################################################################
# The Worker that consumes VSO's destination Secret
########################################################################
deploy_worker() {
    say "Worker deployment"

    # The endpoint and namespace are substituted here rather than committed,
    # because both are account-specific. sed over two known placeholders keeps
    # the manifest readable as a manifest — it stays valid YAML a customer can
    # apply by hand after filling in two fields.
    sed -e "s|PLACEHOLDER_ADDRESS|$TEMPORAL_ADDRESS|" \
        -e "s|PLACEHOLDER_NAMESPACE|$TEMPORAL_NAMESPACE|" \
        "$DEMO_DIR/k8s/worker.yaml" | kc apply -f - >/dev/null ||
        fail "could not apply the worker manifest"
    info "applied k8s/worker.yaml"

    # Restart on every `up` so a rebuilt image is actually picked up. Without
    # this, a code change plus `up` silently keeps the old pod running, and the
    # bug looks like it is in the new code.
    kc rollout restart "deployment/$DEPLOYMENT" >/dev/null
    kc rollout status "deployment/$DEPLOYMENT" --timeout=120s >/dev/null ||
        fail "the worker did not become ready — try './run.sh logs'"
    info "worker is running"
}

current_pod() {
    kc get pod -l app="$DEPLOYMENT" -o jsonpath='{.items[0].metadata.name}'
}

# Retried, because a single describe can fail for two unrelated reasons and
# neither deserves a wrong answer.
#
# It is no longer the credential. This role sets verify_propagation=true, so
# the plugin confirmed the namespace grant on ten frontend connections before
# Vault returned the key — a refusal here should now be rare rather than
# expected. What remains is that the probe samples the frontends it can reach,
# and that the worker may simply not have polled yet. Retrying covers both
# without claiming which one it was.
#
# `status` previously queried once, hid the error, and printed "(none)" —
# telling the operator the worker was dead when it was polling normally, which
# is the most misleading thing it could have said.
#
# Prints the describe output and returns 0, or prints the last error and
# returns 1. The caller decides how to present each case; they are not the same
# result and must not look the same.
describe_task_queue() {
    local key="$1" attempts="${2:-10}" out="" attempt
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if out="$(temporal task-queue describe \
            --address "$TEMPORAL_ADDRESS" \
            --namespace "$TEMPORAL_NAMESPACE" \
            --api-key "$key" \
            --task-queue "$TASK_QUEUE" 2>&1)"; then
            printf '%s\n' "$out"
            return 0
        fi
        sleep 3
    done
    printf '%s\n' "$out"
    return 1
}

# Proof from outside the worker: Temporal Cloud reports which pollers are
# attached to the task queue, so the credential is confirmed without trusting
# the worker's own logs — and without a shell in the image, which distroless has
# not got.
#
# Both filters below are load-bearing, and leaving either out produces a check
# that passes when the worker is dead:
#
#   - Temporal Cloud keeps reporting a poller for minutes after the process
#     behind it has gone. Without matching the identity against the pod that is
#     running now, a long-deleted pod satisfies the check.
#   - A poller that last polled before the reference time proves nothing about
#     the credential supplied by the current VSO reconciliation.
#
# Usage: wait_for_poller <pod> <since-epoch> [timeout-seconds]
wait_for_poller() {
    local pod="$1" since="$2" deadline=$((SECONDS + ${3:-120}))
    while ((SECONDS < deadline)); do
        if temporal task-queue describe \
            --address "$TEMPORAL_ADDRESS" \
            --namespace "$TEMPORAL_NAMESPACE" \
            --api-key "$STARTER_KEY" \
            --task-queue "$TASK_QUEUE" \
            --output json 2>/dev/null |
            jq -e --arg pod "$pod" --argjson since "$since" '
                [ .pollers[]?
                  | select(.taskQueueType == "workflow")
                  | select(.identity | contains($pod))
                  # Fractional seconds have to go before fromdateiso8601 will
                  # parse this, and comparing the strings instead would order
                  # "…:15.6Z" before "…:15Z".
                  | select((.lastAccessTime
                            | sub("\\.[0-9]+Z$"; "Z")
                            | fromdateiso8601) > $since)
                ] | length > 0' >/dev/null; then
            return 0
        fi
        printf '.'
        sleep 3
    done
    return 1
}

########################################################################
# Subcommands
########################################################################
cmd_up() {
    # Validated before any work happens: a typo should cost nothing, not a
    # minikube start and an image build.
    [[ -z "${1:-}" ]] || fail "unknown argument: $1"

    preflight
    resolve_endpoint
    vault_up
    minikube_up
    build_image

    vault_role

    # rbac.yaml comes first because Vault's Kubernetes auth configuration reads
    # the token reviewer's token from the Secret this manifest creates.
    kc apply -f "$DEMO_DIR/k8s/vso/rbac.yaml" >/dev/null ||
        fail "could not apply k8s/vso/rbac.yaml"
    vault_k8s_auth
    vso_install

    # Migrate checkouts that previously ran the script-managed Secret mode.
    # VSO's destination is the only writer now, so a Secret without the matching
    # VaultDynamicSecret is legacy state and must be removed before handover.
    say "VSO credential ownership"
    if kc get secret "$SECRET_NAME" >/dev/null 2>&1 &&
        ! kc get vaultdynamicsecret "$SECRET_NAME" >/dev/null 2>&1; then
        kc delete secret "$SECRET_NAME" >/dev/null
        info "removed the legacy script-managed Secret"
    else
        info "Secret is ready for VSO ownership"
    fi
    rm -f "$DEMO_DIR/.worker-lease"

    apply_vso_manifests

    deploy_worker

    say "Confirming the worker authenticated"
    # Said here rather than left to `set -e`: without a key there is nothing to
    # query Temporal Cloud with, and the poller wait below would spend 150s
    # failing and then blame the worker for a Vault problem.
    mint_temp_key "$WORKER_ROLE" ||
        fail "could not mint a key to confirm with — check 'vault read $MOUNT/config'"
    STARTER_KEY="$TEMP_KEY"
    local pod since
    pod="$(current_pod)"
    # Only polls from here on count, so a poller left over from a previous run
    # of this script cannot stand in for the one just deployed.
    since="$(date -u +%s)"
    if wait_for_poller "$pod" "$since" 150; then
        printf '\n'
        info "Temporal Cloud reports $pod polling $TASK_QUEUE"
    else
        printf '\n'
        fail "no poller appeared — run './run.sh logs' to see why"
    fi

    say "Ready"
    info "./run.sh transfer   start a money transfer"
    info "./run.sh status     what exists right now"
    info "./run.sh watch      watch VSO replace the credential, live"
    printf '\n\033[90m    VSO replaces this key about every 60-70s, comfortably inside its %s\n' "$WORKER_TTL"
    printf '    lease. Nothing to trigger: the lease drives the rotation automatically.\033[0m\n'
}

cmd_transfer() {
    preflight
    resolve_endpoint
    require_vault_running
    say "Starting a transfer"
    # A short-lived credential for a short-lived process. This one is thrown
    # away when the transfer finishes; it is not the worker's key.
    vault read "$MOUNT/service-accounts/$WORKER_ROLE" >/dev/null 2>&1 ||
        fail "no VSO worker role exists — run './run.sh up' first"
    local key
    mint_temp_key "$WORKER_ROLE" ||
        fail "could not mint a starter credential — check 'vault read $MOUNT/config'"
    key="$TEMP_KEY"
    info "minted a starter credential from $MOUNT/creds/$WORKER_ROLE"
    # One name for a Temporal Cloud API key throughout the demo. In .env it
    # holds the admin bootstrap key; here it holds the short-lived,
    # namespace-scoped key Vault just minted, and this assignment shadows the
    # inherited admin value for the starter alone. The starter therefore never
    # runs as the account admin, and nothing downstream has to learn a second
    # variable name.
    #
    # This handoff is for a process the demo launches. Workloads in the cluster
    # take no part in it: the worker reads its key from the mounted Secret at
    # /vault/creds/api-key, so a rotated credential reaches it without any
    # environment variable being involved.
    (
        cd "$DEMO_DIR/app" &&
            TEMPORAL_ADDRESS="$TEMPORAL_ADDRESS" \
                TEMPORAL_NAMESPACE="$TEMPORAL_NAMESPACE" \
                TEMPORAL_CLOUD_API_KEY="$key" \
                go run ./start
    ) || fail "the transfer did not complete"
}

cmd_status() {
    preflight
    resolve_endpoint

    say "Vault"
    if vault status >/dev/null 2>&1; then
        info "reachable at $VAULT_ADDR"
        vault list "$MOUNT/service-accounts" 2>/dev/null | sed 's/^/    /' ||
            info "(no roles)"
        info "outstanding leases for $WORKER_ROLE:"
        vault list "sys/leases/lookup/$MOUNT/creds/$WORKER_ROLE" 2>/dev/null |
            sed 's/^/      /' || info "      (none)"
    else
        info "not running"
    fi

    say "Kubernetes"
    if minikube status --format '{{.Host}}' 2>/dev/null | grep -q Running; then
        kc get deployment,pod,secret 2>/dev/null | sed 's/^/    /' ||
            info "nothing in $K8S_NAMESPACE"

        if kc get vaultdynamicsecret "$SECRET_NAME" >/dev/null 2>&1; then
            info ""
            info "credential owner: Vault Secrets Operator"
            # Conditions, not a `valid` field — VSO 1.5.1 reports health this way.
            #
            # LeaseRenewal=False is expected here and not a fault. This role's
            # ttl equals its max_ttl, so a renewal can never succeed; VSO reads
            # a new credential instead, which is the behaviour being
            # demonstrated. Ready and SecretSynced are the ones to read.
            kc get vaultdynamicsecret "$SECRET_NAME" \
                -o jsonpath='{range .status.conditions[*]}    {.type}={.status}{"\n"}{end}' 2>/dev/null |
                sed 's/^/    /' || true
        else
            info ""
            info "credential owner: not configured (VaultDynamicSecret missing)"
        fi
    else
        info "minikube is not running"
    fi

    say "Temporal Cloud"
    info "namespace $TEMPORAL_NAMESPACE at $TEMPORAL_ADDRESS"
    local key
    vault read "$MOUNT/service-accounts/$WORKER_ROLE" >/dev/null 2>&1 || {
        info "(the VSO worker role does not exist yet, so there is nothing to query with)"
        return 0
    }
    mint_temp_key "$WORKER_ROLE" 2>/dev/null || {
        info "(could not mint a key to query with)"
        return 0
    }
    key="$TEMP_KEY"
    info "pollers on $TASK_QUEUE:"
    local describe_out
    if describe_out="$(describe_task_queue "$key")"; then
        printf '%s\n' "$describe_out" | sed 's/^/      /'
    else
        # Deliberately not "(none)". A refused query and an idle task queue are
        # different facts, and conflating them is what made this command lie.
        info "      query failed: $(printf '%s' "$describe_out" | head -1)"
    fi
}

cmd_logs() {
    kc logs -l app="$DEPLOYMENT" --tail=50 --all-containers 2>&1 ||
        fail "no worker pod found"
}

# The VSO lifecycle is automatic: there is nothing to trigger, only something
# to watch.
#
# Deliberately reads only the Kubernetes API. cmd_status mints a probe key on
# every call, and a loop built on that would mint one every few seconds and
# exhaust Temporal Cloud's 20-non-expired-keys-per-service-account cap within a
# minute — turning the observation tool into the thing that breaks the demo.
#
# Watches the Secret's Kubernetes resourceVersion. It proves the destination
# object changed without reading, decoding, or printing the API key itself.
cmd_watch() {
    say "Watching $SECRET_NAME"
    info "VSO updates the Secret about every 60-70s; the restart count should not"
    printf '\n'

    local last=""
    while true; do
        local revision pod restarts marker
        # `|| true` on every lookup below, and it is not decoration. The script
        # runs under `set -e -o pipefail`, so a missing Secret or a missing pod
        # would fail the assignment and kill the loop — turning "nothing to watch
        # yet" into a silent exit 1. Watching is exactly what someone does while
        # waiting for those things to appear.
        revision="$(kc get secret "$SECRET_NAME" \
            -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null)" || true
        if [[ -z "$revision" ]]; then
            printf '    %s   no %s yet\n' "$(date -u +%H:%M:%S)" "$SECRET_NAME"
            sleep 5
            continue
        fi

        # The pod name is printed rather than assumed constant: during a rollout
        # there are briefly two. A changed name here means the Secret update
        # coincided with a rollout, which weakens the no-restart demonstration.
        pod="$(kc get pod -l app="$DEPLOYMENT" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || true
        restarts="$(kc get pod -l app="$DEPLOYMENT" \
            -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null)" || true

        marker=""
        [[ -n "$last" && "$revision" != "$last" ]] && marker="   <- Secret updated"
        last="$revision"

        printf '    %s   secret-rv %s   pod %s   restarts %s%s\n' \
            "$(date -u +%H:%M:%S)" "$revision" "${pod:-none}" "${restarts:-?}" "$marker"
        sleep 10
    done
}

# Deletes every VSO custom resource, and does not trust their finalizers.
#
# All three kinds carry a finalizer that only the operator can clear, so all
# three must go before the operator does. Deleting the namespace first, or
# uninstalling VSO first, leaves those finalizers unprocessable and wedges the
# namespace in Terminating indefinitely — recoverable only by patching the
# finalizers out by hand.
#
# The VaultDynamicSecret is first of the three because its revoke finalizer is
# the one that asks Vault to delete the key in Temporal Cloud, and that only
# works while the operator is still running.
#
# If the operator has already gone — an interrupted `down`, a manual
# `helm uninstall` — no finalizer can ever be processed and `kubectl delete`
# blocks forever. `down` is the command people reach for when things are already
# broken, so it strips the finalizer instead of hanging.
remove_vso_resources() {
    local kind res
    for kind in vaultdynamicsecret vaultauth vaultconnection; do
        while read -r res; do
            [[ -n "$res" ]] || continue
            if kc delete "$res" --wait --timeout=45s >/dev/null 2>&1; then
                info "deleted $res"
            else
                kc patch "$res" --type=merge \
                    -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
                kc delete "$res" --ignore-not-found >/dev/null 2>&1 || true
                info "force-removed $res (finalizer could not be processed)"
            fi
        done < <(kc get "$kind" -o name 2>/dev/null || true)
    done
}

# Removes only what this script created. minikube itself is left running unless
# --all is passed: someone running `down` to tidy up after a demo should not
# lose a cluster they were using for something else.
cmd_down() {
    say "Removing the Kubernetes resources"
    if minikube status --format '{{.Host}}' 2>/dev/null | grep -q Running; then
        remove_vso_resources

        if helm status vault-secrets-operator -n "$VSO_NAMESPACE" >/dev/null 2>&1; then
            helm uninstall vault-secrets-operator -n "$VSO_NAMESPACE" \
                --wait >/dev/null 2>&1 &&
                info "uninstalled the Vault Secrets Operator"
            kubectl delete namespace "$VSO_NAMESPACE" \
                --ignore-not-found >/dev/null 2>&1
        fi

        # Cluster-scoped, so deleting the namespace does not remove it.
        kubectl delete clusterrolebinding temporal-demo-vault-auth-delegator \
            --ignore-not-found >/dev/null 2>&1 &&
            info "removed the auth-delegator binding"

        kubectl delete namespace "$K8S_NAMESPACE" --ignore-not-found >/dev/null 2>&1 &&
            info "deleted namespace $K8S_NAMESPACE"
        minikube image rm "$IMAGE" >/dev/null 2>&1 && info "removed $IMAGE"
    else
        info "minikube is not running, nothing to remove"
    fi

    say "Revoking credentials and deleting the role"
    if vault status >/dev/null 2>&1; then
        # Deleting the service account matters more here than revoking leases.
        # Temporal Cloud issues these keys with a ~24-hour expiry and Vault is
        # what cuts them short, so if this dev Vault ever restarts with leases
        # in flight, the keys it was tracking stay valid for a day against a cap
        # of 20 per service account. At a two-minute cadence that adds up fast.
        # Deleting the service account removes them all.
        local role
        for role in "$WORKER_ROLE" "$LEGACY_WORKER_ROLE"; do
            if vault read "$MOUNT/service-accounts/$role" >/dev/null 2>&1; then
                vault lease revoke -prefix "$MOUNT/creds/$role" >/dev/null 2>&1 || true
                vault delete "$MOUNT/service-accounts/$role" >/dev/null 2>&1 &&
                    info "deleted $role and its Temporal Cloud service account"
            fi
        done

        if vault auth list -format=json 2>/dev/null |
            jq -e --arg p "$K8S_AUTH_PATH/" 'has($p)' >/dev/null; then
            vault auth disable "$K8S_AUTH_PATH" >/dev/null 2>&1 &&
                info "disabled auth/$K8S_AUTH_PATH"
            vault policy delete "$K8S_AUTH_POLICY" >/dev/null 2>&1 || true
        fi
    else
        info "Vault is not running — leases will expire on their own"
    fi
    rm -f "$DEMO_DIR/.worker-lease"

    if [[ "${1:-}" == "--all" ]]; then
        say "Stopping minikube and Vault"
        minikube stop >/dev/null 2>&1 && info "minikube stopped"
        (cd "$REPO_ROOT" && docker compose down -v >/dev/null 2>&1) &&
            info "Vault stopped"
    else
        info ""
        info "minikube and Vault are still running. './run.sh down --all' stops both."
    fi

    say "Clean"
}

case "${1:-}" in
up) cmd_up "${2:-}" ;;
transfer) cmd_transfer ;;
status) cmd_status ;;
logs) cmd_logs ;;
watch) cmd_watch ;;
down) cmd_down "${2:-}" ;;
*)
    printf 'usage: %s {up|transfer|status|logs|watch|down [--all]}\n' "${0##*/}"
    exit 1
    ;;
esac
