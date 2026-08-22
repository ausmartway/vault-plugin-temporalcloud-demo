#!/usr/bin/env bash
#
# A Temporal worker in Kubernetes, holding an API key that Vault issued and
# will delete when its lease ends.
#
#   ./run.sh up        bring up Vault, minikube, the image and the worker
#   ./run.sh up --vso  the same, but the Vault Secrets Operator syncs the key
#   ./run.sh transfer  start one money transfer from this laptop
#   ./run.sh rotate    replace the worker's key without restarting the pod
#   ./run.sh status    what exists right now, on all three sides
#   ./run.sh watch     watch VSO replace the credential, live
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

# The worker's Vault role. Its own, not one demo.sh created: this demo has to
# stand up on a clean checkout without the other one having been run, and
# `make reset` must not delete the worker's credential out from under it.
#
# ttl/max_ttl are deliberately short. A worker that only survives because its
# credential outlasts the meeting proves nothing; these values guarantee at
# least one rotation happens while anyone is watching.
WORKER_ROLE="demo-k8s-worker"
WORKER_TTL="10m"
WORKER_MAX_TTL="1h"

# The VSO path gets its own role, so the manual path's timings are untouched
# and either mode can be torn down without disturbing the other.
#
# ttl == max_ttl is the whole point. Renewal can never extend a lease past
# max_ttl, so VSO cannot keep one key alive — it has to mint a genuinely new
# credential every couple of minutes. A longer max_ttl would have VSO quietly
# renewing the same key for an hour, which demonstrates nothing in a meeting.
WORKER_ROLE_VSO="demo-k8s-worker-vso"
VSO_TTL="2m"

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
    for cmd in minikube kubectl docker jq tcld temporal helm; do
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
    ns_json="$(tcld --api-key "$TEMPORAL_API_KEY" namespace get \
        --namespace "$TEMPORAL_NAMESPACE" 2>/dev/null)" ||
        fail "could not read namespace $TEMPORAL_NAMESPACE from Temporal Cloud"

    TEMPORAL_ADDRESS="$(jq -r '.uri.regionalGrpc // empty' <<<"$ns_json")"
    [[ -n "$TEMPORAL_ADDRESS" ]] ||
        fail "namespace $TEMPORAL_NAMESPACE reports no regional gRPC endpoint"

    local auth_method
    auth_method="$(jq -r '.spec.authMethod // empty' <<<"$ns_json")"
    [[ "$auth_method" == "ApiKey" ]] ||
        fail "namespace $TEMPORAL_NAMESPACE uses authMethod=$auth_method; API keys need ApiKey"
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
        vault write "$MOUNT/config" \
            api_key="$TEMPORAL_API_KEY" \
            admin_service_account_id="$TEMPORAL_ADMIN_SA_ID" >/dev/null
        info "bootstrap credential configured"
    fi
}

vault_role() {
    say "Vault role for the worker"
    if vault read "$MOUNT/service-accounts/$WORKER_ROLE" >/dev/null 2>&1; then
        info "$WORKER_ROLE already exists"
    else
        # account_role=read is this plugin's floor — it requires an account role
        # on every write. The grant that matters is namespace write, which is
        # what lets the worker poll a task queue and complete tasks.
        vault write "$MOUNT/service-accounts/$WORKER_ROLE" \
            account_role=read \
            namespace_access="$TEMPORAL_NAMESPACE=write" \
            ttl="$WORKER_TTL" max_ttl="$WORKER_MAX_TTL" \
            description='Money-transfer worker in minikube, issued by Vault' >/dev/null
        info "created $WORKER_ROLE (ttl=$WORKER_TTL, max_ttl=$WORKER_MAX_TTL)"
    fi
}

vault_role_vso() {
    say "Vault role for VSO"
    if vault read "$MOUNT/service-accounts/$WORKER_ROLE_VSO" >/dev/null 2>&1; then
        info "$WORKER_ROLE_VSO already exists"
    else
        vault write "$MOUNT/service-accounts/$WORKER_ROLE_VSO" \
            account_role=read \
            namespace_access="$TEMPORAL_NAMESPACE=write" \
            ttl="$VSO_TTL" max_ttl="$VSO_TTL" \
            description='Money-transfer worker, credential synced by VSO' >/dev/null ||
            fail "could not create $WORKER_ROLE_VSO"
        info "created $WORKER_ROLE_VSO (ttl=max_ttl=$VSO_TTL)"
    fi
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
        "$MOUNT" "$WORKER_ROLE_VSO" |
        vault policy write "$K8S_AUTH_POLICY" - >/dev/null ||
        fail "could not write policy $K8S_AUTH_POLICY"
    info "wrote policy $K8S_AUTH_POLICY (read on $MOUNT/creds/$WORKER_ROLE_VSO)"

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

# Mints a key and prints "<lease_id> <api_key>". Both halves are needed: the
# lease is how the caller later revokes exactly the key it issued, which is what
# makes the rotation proof airtight.
mint_key() {
    local out
    out="$(vault read -format=json "$MOUNT/creds/$1")" ||
        fail "could not read $MOUNT/creds/$1"
    jq -r '"\(.lease_id) \(.data.api_key)"' <<<"$out"
}

# A credential for one command — the starter, or a probe that queries Temporal
# Cloud — as distinct from the long-lived one the worker holds.
#
# These are revoked on the way out rather than left to expire, because Temporal
# Cloud caps a service account at 20 non-expired keys and a demo being driven
# from the keyboard mints them faster than a 10-minute TTL retires them. Without
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
# The credential, and the worker that holds it
########################################################################
# Writing the Secret through `create --dry-run | apply` rather than `create`
# makes this idempotent: the same command installs the first key and replaces
# every later one, which is exactly what `rotate` needs.
#
# The data key is api_key with an underscore, matching the field name the Vault
# plugin returns. VSO names Secret keys after the Vault response fields, so
# using the same name here means both credential paths produce an identical
# Secret and the Deployment does not care which one filled it. The mounted
# filename is still api-key — see the items block in k8s/worker.yaml.
write_secret() {
    kubectl create secret generic "$SECRET_NAME" \
        --namespace "$K8S_NAMESPACE" \
        --from-literal=api_key="$1" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null ||
        fail "could not write the $SECRET_NAME secret"
}

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

# The key the worker is holding right now, read back out of the cluster. Needed
# so `rotate` can prove the old key is dead rather than assume it.
current_secret_key() {
    kc get secret "$SECRET_NAME" -o jsonpath='{.data.api_key}' 2>/dev/null |
        base64 -d 2>/dev/null
}

# Blocks until a key is definitively rejected by Temporal Cloud.
#
# Revoking a lease deletes the key, but the auth layer keeps honouring it for a
# few seconds — the parent demo documents the same lag in the other direction.
# That lag is why `rotate` cannot treat "the worker polled after revocation" as
# proof on its own: for a moment, polling with the deleted key still works.
#
# Several consecutive failures are required because a single probe is unreliable
# in either direction.
wait_for_key_dead() {
    local key="$1" deadline=$((SECONDS + ${2:-120})) streak=0
    while ((SECONDS < deadline)); do
        if temporal workflow list --address "$TEMPORAL_ADDRESS" \
            --namespace "$TEMPORAL_NAMESPACE" --api-key "$key" \
            --limit 1 >/dev/null 2>&1; then
            streak=0
        else
            streak=$((streak + 1))
            ((streak >= 3)) && return 0
        fi
        printf '.'
        sleep 3
    done
    return 1
}

# One-shot poller queries are unreliable for a reason that has nothing to do
# with the worker: a freshly minted key is refused for the first few seconds
# while its namespace grant propagates. `up` and `rotate` never notice because
# wait_for_poller retries. `status` queried once, hid the error, and printed
# "(none)" — telling the operator the worker was dead when it was polling
# normally, which is the most misleading thing it could have said.
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
#     the credential in use since. `rotate` passes the moment it revoked the old
#     key, which is what makes a fresh poll evidence that the new key works.
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
    local vso_mode=0
    if [[ -n "${1:-}" ]]; then
        if [[ "$1" == "--vso" ]]; then
            vso_mode=1
        else
            fail "unknown argument: $1 (did you mean --vso?)"
        fi
    fi

    preflight
    resolve_endpoint
    vault_up
    minikube_up
    build_image

    # Which role the confirmation probe draws its key from. It cannot be assumed
    # to be the push-mode role: a clean checkout driven only with --vso never
    # creates that one.
    local probe_role="$WORKER_ROLE"

    if ((vso_mode)); then
        probe_role="$WORKER_ROLE_VSO"
        vault_role_vso

        # rbac.yaml before Vault is configured, because the token reviewer's
        # token is read out of a Secret this creates.
        kc apply -f "$DEMO_DIR/k8s/vso/rbac.yaml" >/dev/null ||
            fail "could not apply k8s/vso/rbac.yaml"
        vault_k8s_auth
        vso_install

        # The two modes cannot both own the Secret. VSO's destination.create
        # makes it the owner, so any hand-written Secret is removed first —
        # otherwise VSO and `kubectl apply` quietly contend over it and the
        # worker's credential depends on which one wrote last.
        say "Handing the Secret over to VSO"
        if kc get secret "$SECRET_NAME" >/dev/null 2>&1 &&
            ! kc get vaultdynamicsecret "$SECRET_NAME" >/dev/null 2>&1; then
            kc delete secret "$SECRET_NAME" >/dev/null
            info "removed the hand-written Secret"
        else
            info "nothing to hand over"
        fi
        # Push mode's bookkeeping does not apply here: VSO owns the lease now,
        # and a stale file would let `rotate` revoke a lease it does not manage.
        rm -f "$DEMO_DIR/.worker-lease"

        apply_vso_manifests
    else
        vault_role

        # Leaving the VaultDynamicSecret in place would have VSO overwrite the
        # key this mode is about to write by hand.
        if kc get vaultdynamicsecret "$SECRET_NAME" >/dev/null 2>&1; then
            say "Taking the Secret back from VSO"
            kc delete vaultdynamicsecret "$SECRET_NAME" --wait >/dev/null
            kc delete secret "$SECRET_NAME" --ignore-not-found >/dev/null
            info "VSO no longer owns $SECRET_NAME"
        fi

        say "Credential"
        read -r WORKER_LEASE WORKER_KEY <<<"$(mint_key "$WORKER_ROLE")"
        write_secret "$WORKER_KEY"
        info "minted a key and wrote it to secret/$SECRET_NAME"
        info "lease: $WORKER_LEASE"
        # Recorded so `rotate` can revoke precisely this lease later, proving the
        # worker moved off this key rather than merely still having a valid one.
        printf '%s\n' "$WORKER_LEASE" >"$DEMO_DIR/.worker-lease"
    fi

    deploy_worker

    say "Confirming the worker authenticated"
    mint_temp_key "$probe_role"
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
    if ((vso_mode)); then
        info "./run.sh watch      watch VSO replace the credential, live"
        # The opposite caveat from push mode: here the credential keeps being
        # replaced on its own, so there is nothing to run and nothing to expire.
        printf '\n\033[90m    VSO replaces this key about every %s. Nothing to run:\n' "$VSO_TTL"
        printf '    the rotation is the demo.\033[0m\n'
    else
        info "./run.sh rotate     replace the key without restarting the pod"
        # Nothing renews this lease, so the worker stops working when it expires.
        # Better said here than discovered mid-meeting.
        printf '\n\033[90m    The lease expires in %s. Nothing renews it, so the worker stops\n' "$WORKER_TTL"
        printf '    working then — run "./run.sh rotate" to hand it a fresh key.\033[0m\n'
    fi
}

cmd_transfer() {
    preflight
    resolve_endpoint
    require_vault_running
    say "Starting a transfer"
    # A short-lived credential for a short-lived process. This one is thrown
    # away when the transfer finishes; it is not the worker's key.
    local key
    mint_temp_key "$WORKER_ROLE"
    key="$TEMP_KEY"
    info "minted a starter credential from $MOUNT/creds/$WORKER_ROLE"
    (
        cd "$DEMO_DIR/app" &&
            TEMPORAL_ADDRESS="$TEMPORAL_ADDRESS" \
                TEMPORAL_NAMESPACE="$TEMPORAL_NAMESPACE" \
                TEMPORAL_API_KEY="$key" \
                go run ./start
    ) || fail "the transfer did not complete"
}

# The demo's strongest moment. Everything here is arranged so the conclusion
# cannot be explained any other way than "the worker is using the new key".
cmd_rotate() {
    preflight
    resolve_endpoint
    require_vault_running

    say "Before"
    local pod_before restarts_before
    pod_before="$(kc get pod -l app="$DEPLOYMENT" -o jsonpath='{.items[0].metadata.name}')"
    restarts_before="$(kc get pod "$pod_before" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
    info "pod $pod_before, restarts: $restarts_before"

    local old_lease=""
    [[ -f "$DEMO_DIR/.worker-lease" ]] && old_lease="$(cat "$DEMO_DIR/.worker-lease")"
    [[ -n "$old_lease" ]] ||
        fail "no recorded lease to rotate away from — run './run.sh up' first"

    # Captured before it is overwritten: proving this exact key stops working is
    # what rules out "the worker just kept using the old one".
    local old_key
    old_key="$(current_secret_key)"
    [[ -n "$old_key" ]] || fail "could not read the current key from secret/$SECRET_NAME"

    say "Issuing a replacement key"
    local new_lease new_key
    read -r new_lease new_key <<<"$(mint_key "$WORKER_ROLE")"
    write_secret "$new_key"
    printf '%s\n' "$new_lease" >"$DEMO_DIR/.worker-lease"
    info "new lease: $new_lease"

    # Revoking the old lease deletes that key in Temporal Cloud. From here on,
    # a worker still holding it cannot authenticate at all — so continued
    # polling is only possible on the new key.
    say "Deleting the key the worker started with"
    vault lease revoke "$old_lease" >/dev/null 2>&1 ||
        info "(that lease had already expired)"
    info "revoked $old_lease — the old key no longer exists in Temporal Cloud"

    # Not enough on its own. Deletion reaches the auth layer a few seconds after
    # Vault returns, so polling with the old key still succeeds for a moment.
    # Wait until it is genuinely refused before starting to collect evidence.
    say "Confirming the old key is actually dead"
    if wait_for_key_dead "$old_key" 120; then
        printf '\n'
        info "the old key is now rejected by Temporal Cloud"
    else
        printf '\n'
        fail "the old key still authenticates — cannot prove anything yet"
    fi

    # Everything after this instant is the evidence, and the instant is here
    # rather than at revocation time on purpose: a poll recorded in between could
    # have used the old key while it was still being honoured.
    local since
    since="$(date -u +%s)"

    # kubelet refreshes a mounted Secret on its sync interval, not instantly, so
    # this legitimately takes up to about a minute. The worker's requests fail
    # with Unauthenticated until the file changes, and the SDK's retry carries it
    # across the gap. Say so out loud rather than letting it look like a hang.
    say "Waiting for kubelet to refresh the mounted Secret"
    info "up to ~60s: this is the kubelet sync interval, not Vault or Temporal"
    mint_temp_key "$WORKER_ROLE"
    STARTER_KEY="$TEMP_KEY"
    if wait_for_poller "$pod_before" "$since" 240; then
        printf '\n'
        info "$pod_before polled successfully after its old key was deleted"
    else
        printf '\n'
        fail "the worker did not come back — './run.sh logs' will say why"
    fi

    say "After"
    local pod_after restarts_after
    pod_after="$(kc get pod -l app="$DEPLOYMENT" -o jsonpath='{.items[0].metadata.name}')"
    restarts_after="$(kc get pod "$pod_after" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
    info "pod $pod_after, restarts: $restarts_after"

    if [[ "$pod_before" == "$pod_after" && "$restarts_before" == "$restarts_after" ]]; then
        printf '\n\033[1;32m    Same pod, same restart count, and the key it booted with is deleted.\n'
        printf '    The credential rotated underneath a process that never stopped.\033[0m\n'
    else
        # Reported rather than hidden: a restart means the SDK did not ride out
        # the gap, and the claim above would be false.
        printf '\n\033[1;31m    The pod restarted (%s/%s -> %s/%s).\n' \
            "$pod_before" "$restarts_before" "$pod_after" "$restarts_after"
        printf '    Rotation worked, but not without a restart — say so.\033[0m\n'
        return 1
    fi
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

        # Which of the two credential paths is live. Worth stating outright: the
        # Secret looks identical either way, so there is otherwise no way to tell
        # from the output above who is filling it.
        if kc get vaultdynamicsecret "$SECRET_NAME" >/dev/null 2>&1; then
            info ""
            info "credential owner: VSO (pull)"
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
            info "credential owner: run.sh (push)"
        fi
    else
        info "minikube is not running"
    fi

    say "Temporal Cloud"
    info "namespace $TEMPORAL_NAMESPACE at $TEMPORAL_ADDRESS"
    local key
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

# The VSO demo, such as it is: nothing to run, just something to watch.
#
# Deliberately reads only the Kubernetes API. cmd_status mints a probe key on
# every call, and a loop built on that would mint one every few seconds and
# exhaust Temporal Cloud's 20-non-expired-keys-per-service-account cap within a
# minute — turning the observation tool into the thing that breaks the demo.
#
# Prints a fingerprint of the key, never the key.
cmd_watch() {
    say "Watching $SECRET_NAME"
    info "the key changes about every $VSO_TTL; the restart count should not"
    printf '\n'

    local last=""
    while true; do
        local key fp pod restarts marker
        # `|| true` on every lookup below, and it is not decoration. The script
        # runs under `set -e -o pipefail`, so a missing Secret or a missing pod
        # would fail the assignment and kill the loop — turning "nothing to watch
        # yet" into a silent exit 1. Watching is exactly what someone does while
        # waiting for those things to appear.
        key="$(kc get secret "$SECRET_NAME" \
            -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d 2>/dev/null)" || true
        if [[ -z "$key" ]]; then
            printf '    %s   no %s yet\n' "$(date -u +%H:%M:%S)" "$SECRET_NAME"
            sleep 5
            continue
        fi
        fp="$(printf '%s' "$key" | shasum -a 256 | cut -c1-12)"

        # The pod name is printed rather than assumed constant: during a rollout
        # there are briefly two, and a changed name here means the credential was
        # picked up by a new process, which would not prove what this demo
        # claims.
        pod="$(kc get pod -l app="$DEPLOYMENT" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || true
        restarts="$(kc get pod -l app="$DEPLOYMENT" \
            -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null)" || true

        marker=""
        [[ -n "$last" && "$fp" != "$last" ]] && marker="   <- rotated"
        last="$fp"

        printf '    %s   key %s   pod %s   restarts %s%s\n' \
            "$(date -u +%H:%M:%S)" "$fp" "${pod:-none}" "${restarts:-?}" "$marker"
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
        vault lease revoke -prefix "$MOUNT/creds/$WORKER_ROLE" >/dev/null 2>&1 &&
            info "revoked outstanding leases"
        vault delete "$MOUNT/service-accounts/$WORKER_ROLE" >/dev/null 2>&1 &&
            info "deleted $WORKER_ROLE from Vault and Temporal Cloud"

        # Deleting the service account matters more here than revoking leases.
        # Temporal Cloud issues these keys with a ~24-hour expiry and Vault is
        # what cuts them short, so if this dev Vault ever restarts with leases
        # in flight, the keys it was tracking stay valid for a day against a cap
        # of 20 per service account. At a two-minute cadence that adds up fast.
        # Deleting the service account removes them all.
        if vault read "$MOUNT/service-accounts/$WORKER_ROLE_VSO" >/dev/null 2>&1; then
            vault lease revoke -prefix "$MOUNT/creds/$WORKER_ROLE_VSO" >/dev/null 2>&1 || true
            vault delete "$MOUNT/service-accounts/$WORKER_ROLE_VSO" >/dev/null 2>&1 &&
                info "deleted $WORKER_ROLE_VSO and its Temporal Cloud service account"
        fi

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
rotate) cmd_rotate ;;
status) cmd_status ;;
logs) cmd_logs ;;
watch) cmd_watch ;;
down) cmd_down "${2:-}" ;;
*)
    printf 'usage: %s {up|transfer|rotate|status|logs|down [--all]}\n' "${0##*/}"
    exit 1
    ;;
esac
