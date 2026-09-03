# Vault as the issuer of Temporal Cloud API keys

A local, self-contained demo of [`vault-plugin-secrets-temporalcloud`](https://github.com/ausmartway/vault-plugin-secrets-temporalcloud).
HashiCorp Vault mints Temporal Cloud service accounts and API keys on demand and
binds each key to a lease. When the lease ends, Vault *deletes the key in
Temporal Cloud*.

Everything runs against a real Temporal Cloud account. Nothing is simulated —
the API keys you see in the demo appear and disappear for real.

```bash
make demo     # interactive walkthrough, advances on ENTER
make reset    # back to a clean state
```

---

## The problem this solves

Temporal Cloud API keys are static. In practice that means a key gets created
once, pasted into CI, a `.env`, a teammate's shell history, and a secret
manager nobody rotates. Nobody can answer two questions that auditors always
ask: *who holds a working credential right now*, and *how fast can you take it
away*.

The usual mitigations don't really fix it. Short expiry times move the
outage risk around. Rotation runbooks depend on someone running them. Scoping
helps, but only if someone remembers to scope.

The dynamic-secrets model changes the shape of the problem:

| Dimension | Static API key | Vault-issued |
|---|---|---|
| Who has it | Unknowable | Whoever holds an unexpired lease |
| Lifetime | Until someone rotates it | The lease TTL (minutes) |
| Revocation | Find it, delete it, hope | `vault lease revoke` — deleted in Temporal Cloud |
| Scope | Whatever it was created with | Per-role, defined in Vault |
| Blast radius on leak | Everything, indefinitely | One role, for the rest of one TTL |

The key insight for the demo: *the lease is the leash*. Vault doesn't merely
forget the credential on revoke — it calls Temporal Cloud and deletes it.

---

## What the demo does

`demo.sh` walks seven steps, each a real command:

1. **Register and mount the plugin.** Registration is by the binary's SHA256 —
   Vault refuses to load a plugin whose hash doesn't match. This is the
   supply-chain check, and it's why the release ships `_SHA256SUMS`.
2. **Configure the mount.** Supply the last static bootstrap key — just the key,
   one field — and set the mount-wide propagation probe to ten successes at
   50 ms intervals. Reading `config` back shows the key never comes out again,
   and shows the key ID and owning service account that plugin 0.3.1 derived
   from it. The same lookup rejects a user-owned key here rather than at first
   use, and requires the owner to hold the Global Admin role.
3. **Define three roles** — one with account-wide read, one scoped to a single
   namespace, one `metrics-read` for a scraper that should never see a
   workflow. Each creates a real service account in Temporal Cloud. These are
   templates; no API key exists yet.
4. **Read a credential.** Vault mints a key and returns it under a lease. Plugin
   0.3.1 verifies propagation by default: ten independent namespace-frontend
   connections over at least 450 milliseconds before returning. Only the
   namespace-granted role has a namespace to check, so that is the one where the
   wait is visible. The demo then uses the key against Temporal Cloud. The same
   read runs three times — three distinct keys under three independent leases,
   because nothing is cached or shared between consumers.
5. **Show the lease.** Renewal extends it without ever calling Temporal Cloud.
6. **Revoke.** The same key is rejected seconds later — because it no longer
   exists.
7. **Retire the bootstrap key.** `rotate-root` mints a replacement on the same
   service account, verifies it, stores it, and deletes the key it replaced —
   so the one long-lived credential in the demo is gone by the end, and the
   engine runs on a root key no human has seen.

> **The demo consumes your bootstrap key.** Step 7 deletes the
> `TEMPORAL_CLOUD_API_KEY` in your `.env` from Temporal Cloud. That is the
> point — provision a throwaway admin service-account key per demo — but it
> means every run needs a fresh one, and `make reset` cannot sweep orphaned
> accounts afterwards until you supply it.

---

## Prerequisites

| Tool | Why |
|---|---|
| `docker` | Runs Vault. No `vault` binary needed on the host — the demo drives the CLI inside the container. |
| [`temporal`](https://docs.temporal.io/cli) | The CLI, ≥1.8. Its `temporal cloud` commands verify what actually happened in Temporal Cloud at each step. Replaces `tcld`. |
| `jq` | Parsing `temporal cloud … -o json` output. |
| `pv` | demo-magic simulates typing with it. Interactive runs only — `make auto` doesn't need it. Not preinstalled on macOS: `brew install pv`. |
| `curl`, `unzip`, `shasum` | Fetching and verifying the plugin release. |

You also need a Temporal Cloud account with:

- A *service-account-owned* API key with the `Admin` account role. This
  matters: Temporal Cloud's `CreateApiKey` only accepts a service-account
  owner, so a *user*-owned key configures fine and then fails on the first
  `vault read creds/...`. Verify with:
  ```bash
  temporal cloud apikey list --api-key "$TEMPORAL_CLOUD_API_KEY"
  ```
  You want `SERVICE_ACCOUNT` in the `OwnerType` column. Use the plain table
  rather than `-o json` — the JSON leaves owner type as an integer enum, while
  the table renders it.
- *At least one namespace*, for the namespace-scoped role in step 3.

---

## Setup

```bash
cp .env.example .env
$EDITOR .env          # see the comments in the file for where each value comes from
make check-ports      # confirm VAULT_PORT is free before anything starts
make demo
```

`.env` is gitignored. Nothing in this repo commits a credential.

### Make targets

| Target | What it does |
|---|---|
| `make demo` | Start Vault if needed, run the interactive walkthrough |
| `make auto` | Same walkthrough, no keypresses — smoke test or screen recording |
| `make performance-test` | Sample API-key issuance and immediate validity for 12 hours |
| `make status` | What exists right now, in Vault *and* in Temporal Cloud |
| `make reset` | Revoke leases, delete the demo service accounts, tear Vault down |
| `make up` / `make down` | Start / stop Vault only |
| `make plugin` | Checksum-verify the plugin binary, downloading it only if it isn't already there |

### 12-hour propagation performance test

```bash
make performance-test
```

The test takes one sample per minute for 12 hours. Each sample measures the
wall-clock time for `vault read` to return a newly issued key, then immediately
uses that key for `DescribeNamespace` against the namespace frontend—the same
RPC plugin 0.3.1 uses for propagation verification. There are no validation
retries: `valid=true` means the first independent call after Vault returned
succeeded. If that call returns `valid=false`, the test immediately increases
the mount's `consecutive_successes` setting by one for subsequent credentials,
up to the plugin maximum of 20. Each result records the setting it used and any
adjustment it triggered.

Every lease is revoked after validation to stay below Temporal Cloud's 20-key
limit. Results are streamed as JSON Lines to `performance-results/`, without
API-key tokens, and a JSON summary is written when the run exits. Interrupting
the script also revokes outstanding leases and removes its dedicated service
account.

Defaults can be overridden for a shorter smoke test or a different sampling
interval:

```bash
DURATION_SECONDS=300 INTERVAL_SECONDS=10 make performance-test
```

Keep the machine awake and the terminal open for the full run, or launch it
under your preferred process supervisor.

---

## How it's wired

`make up` fetches and verifies the plugin binary, then starts Vault with that
binary available. `demo.sh` drives the Vault CLI inside the container, and `temporal cloud`
verifies each effect against Temporal Cloud independently.

```text
  make up
    │
    ├─ scripts/fetch-plugin.sh
    │    downloads the release zip unless it is already cached, verifies
    │    it against _SHA256SUMS, extracts the binary to ./plugins/
    │
    └─ docker compose up
         hashicorp/vault -dev, ./plugins mounted at /vault/plugins
         │
  demo.sh ──┤  vault plugin register -sha256=…    (supply-chain check)
            │  vault secrets enable -path=temporalcloud
            │  vault write  temporalcloud/config             ──► Temporal Cloud
            │  vault write  temporalcloud/service-accounts/… ──► creates service accounts
            │  vault read   temporalcloud/creds/…            ──► mints an API key
            │  vault lease revoke                            ──► deletes the API key
            │
            └─ temporal cloud … (read-only, verifies each effect independently)
```

Vault runs in *dev mode*: in-memory storage, auto-unsealed, a single known
root token. Correct for a demo, never for anything real.

`./plugins` holds the plugin binary and nothing else, on purpose. Vault's
`-dev-plugin-dir` tries to execute every file it finds there, so a stray README
or checksum file stops the server from booting.

---

## Questions this demo tends to provoke

**"What happens when Vault is down?"** Existing keys keep working until their
lease expires — they're real Temporal Cloud keys, not proxied. You lose the
ability to issue new ones, not the ability to use issued ones.

**"What if Vault crashes without revoking?"** Vault mints every key with a
Temporal Cloud expiry past the lease's `max_ttl`, so an orphan expires on its
own instead of lingering. Step 5 shows the Cloud-side expiry next to the
5-minute lease. That expiry also caps renewal: Vault refuses to extend a lease
past the life of the key behind it, so a lease never outlives its credential.

**"How many credentials can one role hand out at once?"** Temporal Cloud caps a
service account at *20 non-expired keys*, so 20 concurrent leases per role.
More consumers means more roles, which you want anyway for scoping.

**"Isn't the bootstrap key still a static key?"** Yes — for exactly as long as
it takes to run:

```bash
vault write -f temporalcloud/config/rotate-root
```

Vault mints a replacement, verifies it, stores it, and deletes its predecessor.
After that, the only working root credential is one no human has ever seen.
This is the real answer to "you've just moved the problem."

Deleting the predecessor is guaranteed rather than conditional. Plugin 0.1.0
reads `api_key_id` out of the bootstrap key's own JWT instead of asking an
operator to supply it, so the ID that `rotate-root` deletes always names the
key actually in use.

> **Caution:** `demo.sh` leaves `rotate-root` out on purpose. It deletes the key
> in your `.env` and replaces it with one Vault never reveals, so the value in
> `.env` stops working and you can't re-bootstrap this demo from it. Run it live
> only if you're ready to mint a fresh bootstrap key afterwards. You also have to
> re-run `rotate-root` before `root_key_ttl` (90 days by default) expires, or the
> mount stops issuing credentials.

---

## Troubleshooting

**`port 8200 is already in use`** — `make check-ports` prints what's holding
it. Change `VAULT_PORT` in `.env`; `VAULT_ADDR` follows automatically.

**`rpc error: code = Unauthenticated`** right after minting a key, or a revoked
key that still works — this is auth-layer lag, not the plugin. The plugin
confirms every mutating Cloud Ops call: it reads the resource back and blocks
until that resource reaches the requested state, confirming a deletion via
`RESOURCE_STATE_DELETED` rather than via `NotFound`. So *nothing in this demo
waits on the Cloud Ops API*. But authenticating *with* a key exercises a
different plane, and that one lags independently. On back-to-back runs of
`demo.sh`, one run passed instantly; the next rejected a fresh key and accepted
a revoked one, while `apikey list` already reported zero keys. That is why
`wait_for_key_valid` and `wait_for_key_revoked` wrap only the two
`temporal cloud … --api-key "$API_KEY"` calls, and require several consecutive identical
results before moving on.

**`failed to load plugin` at container start** — something other than the
plugin binary is in `./plugins/`. `make reset && make up`.

**`api_key is required`** on `vault write config` — `.env` wasn't loaded, or
`TEMPORAL_CLOUD_API_KEY` is empty.

**Credentials fail with a permission error** — the bootstrap key is probably
user-owned rather than service-account-owned. See Prerequisites.

**A demo died halfway and left things behind** — `make reset` is idempotent and
sweeps orphaned `demo-app-*` service accounts out of Temporal Cloud.

---

## What this is not

Dev-mode Vault, a root token in a file, and a single bootstrap credential
pasted in by hand. The *pattern* is production-shaped; this deployment is not.
A production deployment has:

- Real storage and a real seal
- An auth method instead of a root token
- Vault policies limiting who can read which `creds/` path
- `rotate-root` run as soon as the engine is configured
