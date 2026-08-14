# Design: local Vault + Temporal Cloud dynamic secrets demo

Date: 2026-08-14
Status: implemented

## Goal

A customer-facing demo showing HashiCorp Vault issuing Temporal Cloud API keys
as dynamic secrets, using `ausmartway/vault-plugin-secrets-temporalcloud`.
Success is a live-demoable walkthrough where a Temporal Cloud API key visibly
appears and disappears under Vault's control, and a reset that returns both
Vault and the Temporal Cloud account to a clean state.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Temporal Cloud | Real account (`rgumq`) | The plugin drives Cloud Ops APIs; a local dev server cannot mint service accounts or API keys, so the usual "always use the local dev server" rule does not apply here. |
| Vault runtime | `hashicorp/vault:1.20` in Docker, dev mode | No host `vault` install; reproducible for other SEs. Host port from `.env` so conflicts are avoidable. |
| Plugin delivery | Download release v0.0.1, verify `_SHA256SUMS` | Mirrors the production install path, and makes the SHA256 registration step part of the story rather than a detail. |
| Demo driver | `demo-magic.sh`, vendored at repo root | House convention. `AUTO_PLAY_MODE=1` sources it with `-n -d` for unattended runs. |
| Scope | Vault CLI lifecycle, plus read-only `tcld` verification | The `tcld` calls are what make the effect visible; no worker or Vault Agent, which would add failure modes without adding to the argument. |
| Roles | Two: account-wide read, and namespace-scoped | Contrasting privilege levels is the point customers care about. Required creating namespace `vault-test.rgumq`. |
| `rotate-root` | Documented, not scripted | It deletes the bootstrap key in `.env`, which would make the demo non-repeatable from that file. |

## Components

- `scripts/common.sh` — loads `.env`, derives `VAULT_ADDR` from `VAULT_PORT`
  (one source of truth for the port), and defines the `vault()` wrapper that
  execs the CLI inside the container.
- `scripts/fetch-plugin.sh` — download, checksum-verify, extract *only* the
  binary into `plugins/`.
- `docker-compose.yml` — Vault dev mode with `-dev-plugin-dir=/vault/plugins`.
- `demo.sh` — the six-step walkthrough.
- `reset.sh` — revoke leases → delete service accounts → disable mount → stop
  Vault → sweep orphaned `demo-app-*` accounts in Temporal Cloud.
- `scripts/status.sh` — current state on both sides.

## Constraints discovered during implementation

These were not obvious up front and each one shaped the code:

1. **Plugin dir must contain only the binary.** `-dev-plugin-dir` tries to
   execute every file it finds; a checksum sidecar prevented Vault from
   booting. The sidecar moved to `.plugin-cache/`.
2. **demo-magic runs commands via `eval $@`, unquoted.** Backslash
   continuations inside `pe` get mangled, so multi-argument `vault write`
   commands are written on one line.
3. **demo-magic's `wait` always blocks** regardless of `-n`, and returns
   nonzero at EOF, which killed unattended runs under `set -e`. Replaced with a
   local `pause` that honours `AUTO_PLAY_MODE`.
4. **demo-magic calls `stty` around every command**, which fails when stdout is
   a pipe. Shimmed to a no-op in auto-play only.
5. **Temporal Cloud propagation is not instant, and not uniform.** A newly
   minted key takes ~10s to authenticate. Worse, the transition is uneven
   across auth nodes: a revoked key produced one rejection and was then
   accepted again a second later, which broke the demo's punchline. The polling
   helpers require several *consecutive* identical results before proceeding.
6. **`sub` in a Temporal Cloud API key JWT is the creator, not the owner.**
   Determining whether the bootstrap key is service-account-owned requires
   `tcld apikey list` and reading `owner.ownerType`.

## Verification

- `AUTO_PLAY_MODE=1 ./demo.sh` exits 0 from a clean state; the only
  authentication failure in the output is the intended post-revocation one.
- `reset.sh` leaves the Temporal Cloud account with only its pre-existing
  service accounts and keys, and stops the container.
- Both are repeatable back to back.
