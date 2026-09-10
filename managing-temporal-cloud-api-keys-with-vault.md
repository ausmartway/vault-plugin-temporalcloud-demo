# Managing Temporal Cloud API keys with HashiCorp Vault's dynamic secrets

Issue short-lived, least-privilege Temporal Cloud API keys and rotate them
without restarting long-running workers.

A Temporal Cloud API key often starts in one place and quietly spreads: into a
CI secret, a developer's `.env`, and a chat thread where a colleague is
reproducing a bug. Although the key has a configured expiry, it remains valid
until that date or until somebody finds and revokes it.

Months later, two questions become difficult to answer: *Which workload was
issued this credential?* and *How quickly can we revoke its access?*

This post shows how to put Temporal Cloud API keys behind Vault's dynamic
secrets model. Vault creates a new key when a workload needs one, records the
requesting identity and lease, and deletes the key in Temporal Cloud when the
lease ends. It also solves a Temporal-specific concern: rotating credentials
underneath a worker that may run for weeks, without restarting it.

> **Note:** This tutorial uses the community-maintained
> [`vault-plugin-secrets-temporalcloud`](https://github.com/ausmartway/vault-plugin-secrets-temporalcloud),
> which is not officially supported by HashiCorp or Temporal. Review and approve
> third-party plugin code before using it in production.

## Challenge: manually managed API keys don't scale

Long-lived API keys create problems that compound as more teams and workloads
adopt Temporal Cloud:

- **Security risk:** A leaked key works until its configured expiry or until
  someone notices and revokes it. A broadly privileged key increases the blast
  radius.
- **Operational overhead:** Rotation means finding every copy, updating each
  consumer in the right order, and verifying that nothing was missed.
- **Limited attribution:** When one key is shared by several people and
  pipelines, its use cannot be tied cleanly to the workload for which it was
  originally issued.
- **Development friction:** Because creating a key is a privileged, manual
  operation, developers often reuse an existing credential rather than request
  a narrowly scoped one.

Shortening a key's expiry helps, but it does not connect that key's lifecycle to
the workload using it. If the workload disappears, the credential remains
active until somebody removes it or its Cloud-side expiry arrives.

## Solution: make the lease the leash

Vault changes the model from credentials that applications keep to credentials
that applications borrow:

1. A workload authenticates to Vault using its existing identity.
2. Vault creates a new API key on a dedicated Temporal Cloud service account.
3. Vault returns the key with a lease and records which authenticated identity
   requested it.
4. When the lease expires or is revoked, Vault deletes the key in Temporal
   Cloud.

The fourth step is what makes the lease meaningful. Vault does not merely
forget the secret: it removes the credential from the system that accepts it.
The lease is the leash.

| | Manually managed API key | Vault-issued API key |
|---|---|---|
| Issuance visibility | Often shared after creation | Requesting Vault identity is audited |
| Lifetime | Configured on each key | Controlled through the Vault lease |
| Revocation | Find and delete the key | Revoke the lease; Vault deletes the key |
| Scope | Chosen manually | Defined consistently by a Vault-managed role |
| Exposure after a leak | Until revocation or expiry | One role, for the remaining lease time |

### What you will see

The walkthrough demonstrates that:

- A Vault role creates a scoped Temporal Cloud service account.
- Every credential request produces a unique API key and Vault lease.
- Revoking that lease deletes the key from Temporal Cloud.
- Vault can rotate the administrative bootstrap key supplied during setup.
- A running Temporal worker can adopt replacement credentials without a
  restart.

Want to see the lifecycle before reading the details? Run the companion demo
against a non-production Temporal Cloud account:

```bash
git clone https://github.com/ausmartway/vault-plugin-temporalcloud-demo.git
cd vault-plugin-temporalcloud-demo
cp .env.example .env
$EDITOR .env
make demo
```

The repository README lists the local prerequisites and setup-identity
requirements. For each run, the script creates a disposable bootstrap key and
leaves the key in `.env` untouched. The demo uses Vault dev mode, which is
appropriate for evaluation but not production.

## How the credential lifecycle works

### 1. Give Vault a bootstrap identity

After installing and mounting the plugin, configure it with an API key owned by
a dedicated Temporal Cloud **service account** with the Global Admin account
role:

```bash
vault write temporalcloud/config api_key="$TEMPORAL_CLOUD_API_KEY"
```

The plugin derives the key ID and owner from the key itself. It rejects a
user-owned key or an insufficiently privileged service account during
configuration, and it never returns the key on a subsequent config read.

This is the only credential an operator needs to provide manually. Later in the
walkthrough, Vault replaces and deletes it.

For plugin installation, checksum verification, and multi-node Vault guidance,
follow the plugin's
[installation documentation](https://github.com/ausmartway/vault-plugin-secrets-temporalcloud#install).

### 2. Define access once

A service-account entry is a template for the credentials Vault will issue.
Creating the entry also creates the corresponding service account in Temporal
Cloud, but it does not create an API key yet:

```bash
# Account-wide read plus write access to one namespace.
vault write temporalcloud/service-accounts/demo-app-worker \
    account_role=read \
    namespace_access="$TEMPORAL_NAMESPACE=write" \
    ttl=5m max_ttl=1h
```

The account role and namespace grants are independent. A worker can receive
write access to the one namespace where it runs without receiving that access
elsewhere. A metrics scraper could instead use `account_role=metrics-read` and
have no namespace access at all.

Vault policy provides the other half of the boundary: each workload should be
able to read only its own `temporalcloud/creds/<role>` path.

### 3. Request a unique credential

The workload—or an operator testing the flow—reads the credential path:

```bash
vault read temporalcloud/creds/demo-app-worker
```

A successful response looks like this, with sensitive values shortened:

```text
Key                    Value
---                    -----
lease_id               temporalcloud/creds/demo-app-worker/abc123...
lease_duration         5m
lease_renewable        true
api_key                eyJhbGciOiJFUzI1NiIs...
api_key_id             A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6
expires_at             <timestamp>
service_account_id     <service-account-id>
service_account_name   demo-app-worker
```

The token appears only in this response. Read the path three times and Vault
creates three distinct keys under three independent leases; nothing is cached
or shared between consumers.

The plugin also accounts for a Temporal Cloud behavior that can otherwise cause
intermittent startup failures. New API keys propagate asynchronously, so a key
reported as created by the Cloud Ops API may not yet be accepted by every
namespace frontend. Before returning a credential, the plugin verifies it
against each namespace in the role's `namespace_access`.

### 4. Revoke the lease and prove the key is gone

```bash
vault lease revoke -prefix temporalcloud/creds/demo-app-worker
```

Now use the issued key directly against Temporal Cloud:

```text
$ temporal cloud namespace list --api-key "$API_KEY"
>>> rejected — the key no longer exists in Temporal Cloud
```

You can independently confirm the result with `temporal cloud apikey list`.
The key has not merely disappeared from Vault's lease list; it has been deleted
from the Temporal Cloud account.

### 5. Rotate away the bootstrap key

The manually supplied bootstrap credential does not have to remain in the
system:

```bash
vault write -f temporalcloud/config/rotate-root
```

Vault creates a replacement on the same administrative service account,
verifies it, stores it, and deletes the key it replaced. The value initially
pasted into Vault stops working, while the secrets engine continues with a root
credential no person has seen.

## Why use Vault for this?

If your platform already uses Vault for Kubernetes service accounts, cloud IAM,
or CI/CD identities, Temporal Cloud becomes one more credential lifecycle
managed through the same authentication methods, policies, audit logs, and
revocation workflows.

That provides consistent controls without building a Temporal-specific key
broker. Vault records which authenticated identity requested each lease, while
Temporal Cloud continues to enforce the permissions assigned to the dedicated
service account.

If you do not already operate Vault, the companion demo provides a disposable
environment for evaluating the pattern before deciding whether that operational
investment makes sense for your organization.

## Rotate credentials without restarting workers

A Temporal worker may run for weeks, which appears incompatible with a
five-minute credential. Restarting every pod on each rotation would replace a
credential problem with an availability problem.

Temporal's Go SDK can resolve the API key through a callback instead of holding
a fixed string:

```go
credentials := client.NewAPIKeyDynamicCredentials(
    func(context.Context) (string, error) { return readAPIKey() },
)
```

Point that callback at a file, mount a Kubernetes Secret at the same path, and
use the [Vault Secrets Operator](https://developer.hashicorp.com/vault/docs/platform/k8s/vso)
(VSO) to populate the Secret from `temporalcloud/creds/...`:

```text
Vault dynamic secret
        │ leased API key
        ▼
VaultDynamicSecret ──VSO──► Kubernetes Secret
                                    │ mounted file
                                    ▼
                          Temporal worker callback
```

Mount the Secret as a **volume**, not an environment variable. Environment
variables remain fixed for the life of a process, but kubelet refreshes a
mounted Secret and the worker callback can read the replacement key without a
restart.

## Give it a try

Start with one non-production namespace and one narrowly scoped workload. Run
the demo, watch Vault issue a real key, and then confirm for yourself that
revoking its lease removes it from Temporal Cloud:

[Run the Temporal Cloud dynamic-secrets demo](https://github.com/ausmartway/vault-plugin-temporalcloud-demo)

Before moving beyond evaluation, review the community plugin, test rotation and
failure behavior under your workload, restrict each consumer to its own Vault
credential path, and automate root-key rotation.
