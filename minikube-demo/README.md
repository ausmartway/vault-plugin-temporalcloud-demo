# A Temporal worker in Kubernetes, on a credential that expires

The [money-transfer sample](https://github.com/temporalio/money-transfer-project-template-go)
running as a Kubernetes Deployment, connected to Temporal Cloud with an API key
that HashiCorp Vault issued minutes ago and will delete when its lease ends.

```bash
./run.sh up          # Vault, VSO, minikube, the image, and the worker
./run.sh transfer    # start one money transfer
./run.sh watch       # watch VSO replace the credential, live
./run.sh status      # inspect Vault, VSO, Kubernetes, and Temporal Cloud
./run.sh down        # remove everything this created
```

This builds on the demo in the parent directory, which shows Vault minting and
deleting Temporal Cloud API keys. That one proves the credential lifecycle. This
one answers the question it provokes: *fine, but my workers run for weeks.*

---

## The problem this solves

A Temporal worker is a long-running process. The usual way it reaches Temporal
Cloud is an API key in a Kubernetes Secret, pasted in once by whoever set up the
cluster. That key outlives the person who created it.

Short-lived credentials look incompatible with long-running workers. If the key
expires in 10 minutes and the worker runs for a month, the worker breaks — so
teams either issue long-lived keys or wire up a restart on every rotation.

Neither is necessary. The Temporal Go SDK can take a *callback* for its
credential instead of a fixed string:

```go
credentials := client.NewAPIKeyDynamicCredentials(
    func(context.Context) (string, error) { return readAPIKey() },
)
```

That callback runs on every request. Point it at a file, mount a Kubernetes
Secret at that path, and the credential becomes something Vault can replace
underneath a process that never stops.

| | Static API key in a Secret | This VSO demo |
|---|---|---|
| Key lifetime | Until someone rotates it | The Vault lease (2 minutes) |
| Rotation | Manual Secret update, often followed by a rollout | Automatic and lease-driven |
| Credential owner | A person or deployment script | Vault Secrets Operator |
| On leak | Valid until noticed and revoked | Deleted when its Vault lease ends |
| Worker downtime to rotate | Commonly one rollout | None |
| Worker API key handled by `run.sh` | Usually | Never |

---

## The VSO credential path

The Kubernetes demo has one credential-delivery path. The
[Vault Secrets Operator](https://developer.hashicorp.com/vault/docs/platform/k8s/vso)
runs in the cluster, authenticates to Vault with Kubernetes auth, reads the
dynamic secret, and owns `Secret/temporal-api-key`:

```text
Vault dynamic secret
        │  leased API key
        ▼
VaultDynamicSecret ──VSO──► Kubernetes Secret
                                    │ mounted file
                                    ▼
                          Temporal Worker callback
```

`run.sh` configures this path but never reads or writes the Worker's API key.
The only credentials it mints are temporary keys for the laptop-side workflow
starter and for independent Temporal Cloud poller queries; each is revoked when
the command exits.

The VSO resource reads `temporalcloud/creds/demo-k8s-worker-vso`. Its Vault role
uses `ttl=2m` and `max_ttl=2m`, so the lease cannot be extended. VSO must read a
new dynamic secret, write the new API key to its destination Secret, and let the
old lease expire. The Worker reads the mounted file through the Temporal SDK's
dynamic-credentials callback, so it uses the refreshed value without a rollout.

Run `./run.sh status` to see the `VaultDynamicSecret` conditions and confirm that
VSO is the credential owner. Run `./run.sh watch` to see the Secret's
`resourceVersion` change while the pod name and restart count stay stable. The
command never reads the Secret's data.

### How VSO authenticates

VSO sends the `vso-temporal` ServiceAccount's token to Vault. Vault verifies that
token against the cluster's own TokenReview API and returns a short-lived Vault
token whose policy allows one action: read
`temporalcloud/creds/demo-k8s-worker-vso`. No long-lived Vault credential exists
in the cluster.

Vault runs outside the cluster here, which has two consequences that cost real
debugging time:

- Vault needs a token reviewer of its own, because it has no in-cluster
  ServiceAccount token to authenticate its TokenReview calls with. That is the
  `vault-auth` ServiceAccount and its `system:auth-delegator` binding in
  `k8s/vso/rbac.yaml`. Its token comes from an explicit Secret, because
  Kubernetes stopped creating those automatically in 1.24 and
  `kubectl create token` returns one the API server expires.
- Vault must reach the API server at the minikube container's own address,
  `https://$(minikube ip):8443`. The address in your kubeconfig is a
  host-forwarded `127.0.0.1` port, and inside the Vault container `127.0.0.1` is
  the container itself. Using it fails in a way that looks like a bad token.

### What VSO does not do

`rolloutRestartTargets` is absent from `k8s/vso/dynamic-secret.yaml` on purpose.
VSO offers that field for applications that cannot pick up a rotated credential
without restarting. This worker re-reads its key on every request, so restarting
the pod is the exact thing the demo disproves. Setting the field leaves the demo
working and proving nothing.

`revoke` fires when you delete the `VaultDynamicSecret`, not on every rotation.
A lease VSO rotates away from expires on Vault's own timer instead of being
revoked. With `ttl` equal to `max_ttl` that arrives two minutes after issue, so
the effect is the same.

Temporal Cloud issues these keys with an expiry about 24 hours out regardless of
the lease. The short lifetime comes from Vault *deleting* the key when the lease
ends, not from the key expiring. So if this dev-mode Vault restarts while leases
are outstanding, it forgets them and those keys stay valid for a day, against a
cap of 20 per service account. `./run.sh down` deletes the service account for
that reason.

---

## What `run.sh up` does

1. **Starts Vault** and mounts the Temporal Cloud secrets engine, registering
   the plugin by its binary's SHA256.
2. **Creates the VSO Vault role** — `demo-k8s-worker-vso`, with account-level
   read and *write* on your namespace. Write is what lets a Worker poll a task
   queue and complete tasks. The role uses a two-minute, non-extendable lease.
3. **Starts minikube** and creates the `temporal-demo` namespace.
4. **Builds the worker image** with the host Docker daemon, then side-loads it
   with `minikube image load`. No registry involved.
5. **Installs VSO** at the pinned chart version and configures Vault Kubernetes
   auth for the `vso-temporal` ServiceAccount.
6. **Applies `VaultConnection`, `VaultAuth`, and `VaultDynamicSecret`**. VSO
   reads the dynamic secret and creates `Secret/temporal-api-key`; `run.sh`
   never handles the Worker's API key.
7. **Applies the Deployment** and waits for the rollout.
8. **Checks Temporal Cloud's task-queue pollers** for the current pod. This
   verification is performed externally by `run.sh`; the Worker does not report
   or confirm which credential it is using.

Then `./run.sh transfer` starts a transfer from your laptop, and the worker in
the cluster executes it.

---

## Automatic rotation

There is no `rotate` command. The lease is the clock and VSO is the controller:

1. VSO authenticates to Vault with the `vso-temporal` ServiceAccount.
2. VSO reads `temporalcloud/creds/demo-k8s-worker-vso` and receives a leased API
   key.
3. VSO writes the API key to `Secret/temporal-api-key`.
4. At the lease boundary, VSO reads a new dynamic secret and updates the
   destination Secret. Vault deletes the older Temporal Cloud API key when its
   lease expires.
5. kubelet refreshes the projected Secret volume and the SDK callback reads the
   new file value on a subsequent request.

Run `./run.sh watch`. It prints the Kubernetes Secret's `resourceVersion` beside
the pod name and restart count, without reading the Secret's data. Every 60–70
seconds the resource version changes; the pod identity and restart count should
not. This demonstrates VSO updating the destination Secret without a rollout.
It does not claim that the Worker itself reports which key version it is
using—the Worker has no such reporting behaviour.

The rotation happens well inside the two-minute lease on purpose, and the reason
is kubelet rather than Vault. Vault deletes the old Temporal Cloud key the
instant its lease expires, while kubelet refreshes a mounted Secret only on its
own sync cycle — up to a minute. The gap between VSO writing the new key and
Vault deleting the old one is the budget kubelet has to project it into the
pod; run out of budget and the Worker is holding a key that no longer exists,
which it reports as `Request unauthorized` until the file catches up.

`renewalPercent: 25` in `k8s/vso/dynamic-secret.yaml` is what buys that
budget — about 54 seconds of it, measured. At the 90% this demo used
previously the budget was ~12 seconds, and every rotation produced a burst of
refused polls; the SDK retried through them without restarting, but the backoff
was enough to stall an in-flight transfer for a minute. That file records the
measurements behind the number.

---

## Prerequisites

Everything the parent demo needs, plus:

| Tool | Why |
|---|---|
| `minikube` | Runs the cluster. Any driver works; `docker` is the default. |
| `kubectl` | Applies the manifest and reads pod state. |
| `go` | Builds the starter, which runs on your laptop rather than in the cluster. |
| `temporal` | Reads the task-queue pollers — the independent evidence. |
| `helm` | Installs the Vault Secrets Operator during `up`. |

Your `.env` in the parent directory supplies everything else. The regional gRPC
endpoint is read from your account with `tcld namespace get`, not hardcoded,
because it differs per account and per region.

Note: **API key authentication requires the *regional* endpoint**
(`us-west-2.aws.api.temporal.io:7233`), not the namespace's own
`<namespace>.tmprl.cloud:7233` address. Using the latter fails in a way that
looks like a bad credential and is not. `run.sh` reads the right one and checks
that your namespace has `authMethod: ApiKey`.

---

## Two Temporal Cloud behaviours worth knowing

Both cost real debugging time here, and neither is obvious from the outside.

**A new service account's grants do not all arrive at once.** Account-level read
propagates to the data plane before namespace write does. The visible effect is a
credential that connects successfully and is then refused when it tries to do
anything: `client.Dial` returns a working client, and the worker's first poll
comes back `Request unauthorized`.

The plugin closes that window itself now. Propagation verification is on by
default as of 0.3.1 — this role sets `verify_propagation=true` explicitly anyway,
so the behaviour stays pinned if that default ever moves — and
`temporalcloud/config/probe` sets the policy for the mount: ten independent
connections to the namespace frontend, 50ms apart, returning the key only once
all ten succeed. The wait happens inside `vault read creds/…` — before anything
in the cluster ever sees the credential.

The worker still retries, and the retry still has to wrap the *first poll*, not
just the dial. That matters if you ever mint a key without the probe: protecting
only the dial produces a worker that exits, gets restarted by Kubernetes, and
comes up whenever the grant happens to land — a crash loop wearing a startup
delay as a disguise.

**`serviceerror.PermissionDenied` is invisible to `status.Code()`.** It carries
its gRPC status on a method called `Status()`, while `status.FromError` looks for
`GRPCStatus()`. So the idiomatic check silently returns `Unknown` for exactly the
error you are trying to catch:

```go
// Misses a refused namespace grant entirely.
if status.Code(err) == codes.PermissionDenied { ... }

// Catches it.
var denied *serviceerror.PermissionDenied
if errors.As(err, &denied) { ... }
```

A deleted or malformed key takes the other path — `codes.Unauthenticated` has no
`serviceerror` type and stays a plain gRPC status error — so `isAuthError` in
`app/worker/main.go` checks both.

---

## What is upstream and what is not

The workflow, the activities and the banking stub are byte-identical to the
upstream template. Verify it:

```bash
shasum -a 256 app/workflow.go app/activity.go app/banking-client.go app/shared.go
```

`app/LICENSE` is upstream's MIT license, kept with the code it covers.

Three files differ, and two of them are client construction:

- **`app/worker/main.go`** — upstream calls `client.Dial(client.Options{})`,
  which reaches a local dev server with no credential. This version supplies a
  regional endpoint, TLS, and dynamic credentials read from the mounted Secret.
- **`app/start/main.go`** — the same connection change, plus a unique workflow
  ID. Upstream hardcodes `pay-invoice-701`, which fails as a duplicate on the
  second run; a demo you can fire twice needs a suffix.
- **`app/go.mod`** — `google.golang.org/grpc` and `go.temporal.io/api` become
  direct dependencies, for the error inspection described earlier. Both were
  already there indirectly, so `go.sum` is untouched.

Swapping a static credential for a Vault-issued one does not reach into business
logic, and the diff is the argument for that.

---

## Layout

```text
minikube-demo/
  run.sh              up | transfer | status | logs | watch | down
  Dockerfile          multi-stage; distroless, non-root, static binary
  k8s/
    worker.yaml       ConfigMap + Deployment. No Secret — VSO creates that.
    vso/
      rbac.yaml              the two ServiceAccounts and the auth-delegator binding
      vault-connection.yaml  how VSO reaches Vault
      vault-auth.yaml        how VSO proves who it is
      dynamic-secret.yaml    the credential VSO keeps in sync
  app/
    workflow.go       upstream, unchanged  <- the exhibit
    activity.go       upstream, unchanged
    banking-client.go upstream, unchanged
    shared.go         upstream, unchanged
    worker/main.go    dynamic credentials from the mounted Secret
    start/main.go     static credentials; runs on your laptop
    LICENSE           upstream MIT license, kept with the code it covers
```

`dynamic-secret.yaml` declares the destination Secret, and VSO creates and
updates it from Vault. The Secret itself is deliberately absent from `k8s/`.
Applying `k8s/worker.yaml` without the VSO resources leaves the pod waiting for
a credential that does not exist, which is the correct behaviour for a manifest
that holds no secret.

---

## Troubleshooting

**The pod logs `Temporal Cloud refused the credential (attempt 1/30)`** — no
longer expected, since the plugin verifies the namespace grant before returning
the key (see the preceding propagation note). One or two on the way past is the
retry doing its job. A run of them means the probe is not covering this path:
check that the role actually has `verify_propagation=true`
(`vault read temporalcloud/service-accounts/demo-k8s-worker-vso`) and that your
namespace reports `authMethod: ApiKey`.

**`no poller appeared`** — the worker is running but never authenticated. Run
`./run.sh logs`. If it is still printing `refused the credential`, the namespace
grant has not propagated despite the probe; anything else is a real error.

**`too many API keys`** — Temporal Cloud caps a service account at 20 non-expired
keys. `run.sh` revokes the short-lived credentials it mints for the starter and
for its own probes, so this should not happen; if it does, `./run.sh down`
revokes everything outstanding for the role.

**`ImagePullBackOff`** — the image is not in the cluster. `imagePullPolicy` is
`Never` on purpose, so nothing is fetched from a registry. Re-run `./run.sh up`
to rebuild and reload.

**A transfer stops responding** — no worker is polling. Check `./run.sh status` for a
poller on `TRANSFER_MONEY_TASK_QUEUE`.

**`LeaseRenewal=False` in `./run.sh status`** — expected, not a fault. The VSO
role's `ttl` equals its `max_ttl`, so no renewal can ever succeed and VSO reads a
new credential instead. Read `Ready` and `SecretSynced` instead.

**`Ready=False` on the `VaultDynamicSecret`** — read the operator log:

```bash
kubectl logs -l app.kubernetes.io/name=vault-secrets-operator \
    -n vault-secrets-operator-system --tail=50
```

A connection error means Vault cannot reach the API server, so check
`kubernetes_host`. A `permission denied` means the token reviewer is wrong, not
the policy.

**The pod reports `CreateContainerConfigError`** — first check whether
`VaultDynamicSecret/temporal-api-key` is `Ready`. The destination Secret must
contain `api_key` with an underscore, matching the field name the Vault plugin
returns; `k8s/worker.yaml` mounts it as the file `api-key`.

**`./run.sh down` leaves the namespace in `Terminating`** — a VSO custom resource
still holds a finalizer that no operator is left to clear. `down` deletes all
three kinds before uninstalling the operator, and strips a finalizer it cannot
get processed, so this should not happen. To clear it by hand:

```bash
kubectl patch vaultauth temporal-vault-auth -n temporal-demo \
    --type=merge -p '{"metadata":{"finalizers":[]}}'
```

**`./run.sh down` left minikube running** — deliberate. It removes only what
this demo created, because someone tidying up after a meeting should not lose a
cluster they were using for something else. `./run.sh down --all` stops minikube
and Vault too.

---

## What this is not

Dev-mode Vault, a root token in a file, and a bootstrap credential pasted in by
hand — the same caveats as the parent demo. The rotation mechanism is
production-shaped; this deployment is not.

VSO refreshes the Secret from inside the cluster on the lease's own schedule and
authenticates with Kubernetes auth rather than a long-lived Vault token. The
root token is used by `run.sh` only to configure this dev environment.

What stays unlike production:

- **Vault runs in `-dev`.** In memory, auto-unsealed, one known root token. A
  restart loses every lease, which is why `down` deletes the service account
  rather than trusting revocation.
- **`run.sh` still configures Vault with the root token.** Enabling the auth
  mount, writing the policy, and creating the roles are operator actions here.
  In production they are Terraform, run once, by someone else.
- **The bootstrap Temporal Cloud credential is pasted in by hand**, the same
  caveat as the parent demo.
- **One replica, one namespace, no TLS to Vault.**
