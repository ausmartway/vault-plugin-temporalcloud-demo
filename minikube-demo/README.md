# A Temporal worker in Kubernetes, on a credential that expires

The [money-transfer sample](https://github.com/temporalio/money-transfer-project-template-go)
running as a Kubernetes Deployment, connected to Temporal Cloud with an API key
that HashiCorp Vault issued minutes ago and will delete when its lease ends.

```bash
./run.sh up          # Vault, minikube, the image, the worker
./run.sh up --vso    # the same, with the Vault Secrets Operator syncing the key
./run.sh transfer    # start one money transfer
./run.sh rotate      # replace the worker's key without restarting it
./run.sh watch       # watch VSO replace the credential, live
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

| | API key in a Secret | `./run.sh up` | `./run.sh up --vso` |
|---|---|---|---|
| Key lifetime | Until someone rotates it | The Vault lease (10 minutes) | The Vault lease (2 minutes) |
| Rotation | Edit the Secret, restart the pods | `./run.sh rotate`, no restart | Automatic, no restart |
| Who rotates it | A person, if they remember | You, on demand | The operator, on schedule |
| Who can use it | Anyone with Secret read access, forever | Whoever holds an unexpired lease | Whoever holds an unexpired lease |
| On leak | Valid until noticed and revoked | Dead at the end of the current TTL | Dead at the end of the current TTL |
| Worker downtime to rotate | One rollout | None | None |
| Credential held on your laptop | The one you pasted in | A Vault root token | None |

---

## Two credential paths

The demo runs the same worker two ways, and the difference is only in who puts
the credential into Kubernetes.

**Push mode**, `./run.sh up`, is the proof. The script reads a key from Vault and
writes the Secret itself, which means you can revoke a specific lease by hand and
watch what happens next. `./run.sh rotate` does exactly that: it deletes the key
the worker booted with, confirms Temporal Cloud genuinely rejects it, and only
then reports that the same pod is still polling. A person has to drive it, and
that is the point — the claim is falsifiable.

**Pull mode**, `./run.sh up --vso`, is the production shape. The
[Vault Secrets Operator](https://developer.hashicorp.com/vault/docs/platform/k8s/vso)
runs in the cluster, authenticates to Vault with its own ServiceAccount token,
and keeps the Secret filled on the lease's schedule. Nothing on your laptop holds
a credential. There is no command to run: the rotation happens on its own, and
`./run.sh watch` shows it.

Both modes write the same Secret, so `k8s/worker.yaml`, the image, and every line
of Go are identical either way. The worker cannot tell which mode it runs under.
That is the claim worth making: application code does not participate in the
credential lifecycle at all.

To see which mode is live, run `./run.sh status` and read the `credential owner`
line. Switching modes hands the Secret over explicitly, because the operator and
`kubectl apply` otherwise contend for ownership of it.

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
2. **Creates a Vault role** — `demo-k8s-worker`, with account-level read and
   *write* on your namespace. Write is what lets a worker poll a task queue and
   complete tasks. Its own role, not one `demo.sh` created, so `make reset` in
   the parent directory cannot delete the worker's credential mid-demo.
3. **Starts minikube** and creates the `temporal-demo` namespace.
4. **Builds the worker image** with the host Docker daemon, then side-loads it
   with `minikube image load`. No registry involved.
5. **Mints an API key** and writes it to `secret/temporal-api-key`. The key
   exists only in Vault and in the cluster — never in this repo.
6. **Applies the Deployment** and waits for the rollout.
7. **Confirms the worker authenticated** by asking Temporal Cloud which pollers
   are attached to the task queue. The evidence comes from Temporal Cloud, not
   from the worker's own logs.

Then `./run.sh transfer` starts a transfer from your laptop, and the worker in
the cluster executes it.

---

## The rotation, and why it proves something

`./run.sh rotate` is the part worth watching:

1. Records the worker's pod name and restart count, and reads back the key the
   worker is holding.
2. Mints a **new** key from Vault and writes it over the Secret.
3. **Revokes the lease on the old key**, which deletes that key in Temporal
   Cloud.
4. **Confirms the old key is genuinely rejected**, by trying to use it until it
   fails three times in a row.
5. Waits for Temporal Cloud to report the *same pod* polling, with a timestamp
   later than step 4.
6. Prints the pod name and restart count a second time.

Step 4 is not ceremony. Deleting a key reaches Temporal Cloud's auth layer a few
seconds after Vault returns, so for a moment the deleted key still works — and a
poll observed in that window would prove nothing. Without step 4 the whole
demonstration passes in three seconds and means nothing, which is exactly what
it did before the check was added.

Step 5 is specific for the same reason. Temporal Cloud keeps reporting pollers
for minutes after the process behind them is gone, so the check matches the
identity of the pod running *now* and ignores any poll recorded before step 4
finished.

What is left is a chain with no other explanation: the key the worker booted with
is provably dead, the pod that is provably still the same process polled
successfully after that, and its restart count never moved.

The script claims this only when both values match. If the pod did restart it
reports that instead and exits non-zero — a rotation that needed a restart is a
weaker claim, and worth making honestly.

**This takes up to about a minute.** kubelet refreshes a mounted Secret on its
sync interval rather than immediately, so there is a window where the worker's
requests fail with `Unauthenticated` and the SDK's retry carries it across. That
window is a property of Kubernetes, not of Vault or Temporal.

### The 10-minute clock

This applies to push mode only. Nothing there renews the worker's lease, so read
this before running it in front of anyone. In `--vso` mode the operator keeps the
credential current and there is no clock to run out.

The lease TTL is 10 minutes. When it expires, Vault deletes that key in Temporal
Cloud exactly as `rotate` does deliberately — but no replacement arrives, so the
worker's requests start failing and stay that way. Run `./run.sh rotate` (or
`up`) to hand it a fresh key.

That is the honest shape of a demo that rotates by hand. To close the loop, run
`./run.sh up --vso` and let the Vault Secrets Operator reissue on the lease's own
schedule; for more information, see [Two credential
paths](#two-credential-paths). The worker code needs no change for either,
because it already re-reads its credential on every request.

The lease is renewable, so keeping the same key alive is also an option — up to
`max_ttl`, and never past the key's own Temporal Cloud expiry, which plugin
0.1.1 clamps renewal to.

Ten minutes is deliberate. A TTL long enough to outlast a meeting would let the
demo finish without ever proving the mechanism.

---

## Prerequisites

Everything the parent demo needs, plus:

| Tool | Why |
|---|---|
| `minikube` | Runs the cluster. Any driver works; `docker` is the default. |
| `kubectl` | Applies the manifest and reads pod state. |
| `go` | Builds the starter, which runs on your laptop rather than in the cluster. |
| `temporal` | Reads the task-queue pollers — the independent evidence. |
| `helm` | Installs the Vault Secrets Operator for `up --vso`. |

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
comes back `Request unauthorized`. Retrying is the only fix, and it has to wrap
the *first poll*, not just the dial. Protecting only the dial produces a worker
that exits, gets restarted by Kubernetes, and comes up whenever the grant happens
to land — a crash loop wearing a startup delay as a disguise.

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
  run.sh              up [--vso] | transfer | rotate | status | logs | watch | down
  Dockerfile          multi-stage; distroless, non-root, static binary
  k8s/
    worker.yaml       ConfigMap + Deployment. No Secret — run.sh or VSO makes that.
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

`run.sh` creates the Secret from `vault read`, and it is deliberately absent
from `k8s/`. Applying `k8s/worker.yaml` on its own leaves the pod waiting for a
credential that does not exist, which is the correct behaviour for a manifest
that holds no secret.

---

## Troubleshooting

**The pod logs `Temporal Cloud refused the credential (attempt 1/30)`** —
expected for the first few seconds after a role is created, and the worker
retries out of it without restarting. See the preceding propagation note. If it runs
past ~90s the key is genuinely being rejected: check that your namespace reports
`authMethod: ApiKey`.

**`no poller appeared`** — the worker is running but never authenticated. Run
`./run.sh logs`. If it is still printing `refused the credential`, the namespace
grant has not propagated; anything else is a real error.

**`the old key still authenticates`** during `rotate` — the deletion has not
reached the auth layer within two minutes, which is longer than expected. The
rotation itself is fine; the script refuses to claim a result it cannot yet
prove. Run `rotate` again.

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

**The pod reports `CreateContainerConfigError` in VSO mode** — the Secret's data
key is not `api_key`. Both modes write `api_key` with an underscore, matching the
field name the Vault plugin returns, and `k8s/worker.yaml` mounts it as the file
`api-key`.

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

`./run.sh up --vso` closes two of those gaps. VSO refreshes the Secret from
inside the cluster on the lease's own schedule, and it authenticates with
Kubernetes auth rather than a root token, so no credential of yours is involved
in the rotation.

What stays unlike production in either mode:

- **Vault runs in `-dev`.** In memory, auto-unsealed, one known root token. A
  restart loses every lease, which is why `down` deletes the service account
  rather than trusting revocation.
- **`run.sh` still configures Vault with the root token.** Enabling the auth
  mount, writing the policy, and creating the roles are operator actions here.
  In production they are Terraform, run once, by someone else.
- **The bootstrap Temporal Cloud credential is pasted in by hand**, the same
  caveat as the parent demo.
- **One replica, one namespace, no TLS to Vault.**

The [Vault Agent Injector](https://developer.hashicorp.com/vault/docs/platform/k8s/injector)
is the other way to do what VSO does here, and it needs no worker change either.
The worker already reads its credential from a file on every request, which is
all any of these approaches requires.
