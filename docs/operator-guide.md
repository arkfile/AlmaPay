# Operator guide

This is the active operator reference for installation, routine operation, wallets/plugins, troubleshooting, and recovery planning. The normative requirements remain in [alma-pay-spec.md](alma-pay-spec.md).

## Current blocking status

AlmaPay cannot be installed or started from the repository lock today:

- `upstream.lock` is `candidate` and contains unresolved `PENDING`/`REPLACE` package, repository, and generator values.
- `bootstrap-host`, `install`, `generate`, `start`, and `verify` require a `validated` or `production` lock and intentionally stop.
- `backup`, `restore`, and `update` are deliberate fail-closed stubs. Do not document or treat them as working.
- `verify --production` deliberately stops pending plugin, backup/restore, privacy, Greenfield-permission, and webhook checks.
- No clean AlmaLinux VM install, reboot, update, or restore test has run.

Do not deploy to a production VPS until the blockers in [production-readiness.md](production-readiness.md) are closed. Agents have no production VPS access; an authorized human operator runs host commands.

## Identity and command boundary

Only `bootstrap-host` runs as root. Installation and every runtime operation require the dedicated `almapay` account. Never use Docker or `sudo podman`.

```text
almapay doctor
almapay bootstrap-host                  # root only; currently lock-blocked
almapay install                         # almapay; currently lock-blocked
almapay generate [--build-generator]    # almapay; currently lock-blocked
almapay research-generator              # almapay; candidate-lock evidence only
almapay start | stop | restart          # almapay
almapay status | logs [service]         # almapay
almapay verify [--production]           # almapay
almapay render-caddy                    # almapay
almapay backup | restore | update       # deliberately disabled
```

## Configuration

Start from `config/almapay.env.example` and `config/secrets.env.example`. Configuration and secrets are strict allow-listed `KEY=VALUE` data. AlmaPay never sources either file, so shell expansion and command substitution are not evaluated.

The production paths are:

```text
/var/lib/almapay/almapay.env
/var/lib/almapay/secrets.env
```

`secrets.env` must be a regular file owned by `almapay` with mode `0600`. It must contain a non-example `POSTGRES_PASSWORD` of at least 24 characters. Keep all real credentials out of repositories, shell arguments, history, and logs.

The initial configuration accepts mainnet, `127.0.0.1:8080`, local-pruned Bitcoin, disabled or local-pruned Monero, disabled or `boltz-nodeless` Lightning, disabled or `stripe` cards, and HTTP-01 ACME. Selection does not mean the optional method is installed or ready.

## Installation workflow after lock validation

These steps describe implemented behavior but are intentionally unavailable with the current candidate lock.

`almapay research-generator` is the one candidate-lock exception. It fetches the
pinned generator source, prints the Dockerfile hash and upstream base references,
and—after both base-image digests and that hash have been recorded—builds the
deterministic candidate and prints its image digest. It never edits or promotes
`upstream.lock`; the operator must independently verify every reported value.

1. Run `almapay doctor` to inspect AlmaLinux version, x86-64-v3, cgroup v2, SELinux, rootless namespaces, subordinate IDs, provider identity, filesystem, linger, time, capacity, and listeners.
2. As root, run `almapay bootstrap-host`. It installs exact locked packages, including Python 3 and PyYAML, creates the `almapay` identity and `/var/lib/almapay`, allocates subordinate IDs, enables linger, and configures firewalld while preserving the detected SSH port. It never runs Podman.
3. Install the two configuration files with the required ownership and modes.
4. As `almapay`, run `almapay install`.
5. Review the generated Compose diff and `/var/lib/almapay/caddy/Caddyfile.almapay`.
6. As root, install the reviewed Caddy source as active host configuration and reload Caddy only after validation.
7. As `almapay`, run `almapay start`, `status`, and non-production `verify`.

`install` performs the complete implemented pipeline: fetches the pinned upstream source, ensures or builds the pinned local generator, runs it with mandatory variables, semantically renders and validates Compose, pulls exact digest images, installs/enables the user-systemd service with `secrets.env` as `EnvironmentFile`, and renders and validates Caddy.

Compose validation checks exact lock digests, the sole `127.0.0.1:8080:49392` mapping, absence of every other published port, privilege/capability/host-namespace and dangerous-mount restrictions, disabled SSH integration, SCRAM placeholders and authenticated database strings, complete Bitcoin arguments, and Monero pruning. Do not weaken a failed check to make installation proceed.

## First-start operator gates

The operator, not AlmaPay automation, must:

1. Complete BTCPay administrator registration, passkeys/MFA, and recovery.
2. Create a separate store, API key, and webhook secret for each consumer and environment.
3. Wait for chain and NBXplorer synchronization.
4. Choose wallet and custody policy and secure recovery material.
5. Install and verify plugins only through a stable tested process.
6. Complete the applicable [production-readiness](production-readiness.md) gates before enabling a mainnet method.

### Bitcoin

Use descriptor or xpub workflows. `CREATE_WALLET=false`; do not create legacy BDB wallets or use removed import/dump RPCs. Bitcoin RPC remains internal. Runtime verification must query a numeric version of at least `300000` and confirm NBXplorer synchronization.

### Monero

The generator can include pruned Monero services and internal RPC. This is not production support: plugin installation, view-only custody, account-index policy, backup/restore, privacy, and payment proof remain unresolved gates. AlmaPay never accepts or backs up spend keys. Stores share server-wide wallet view material; use separate deployments for true treasury separation.

### Boltz and Stripe

Configuration choices and candidate pins exist, but stable plugin installation and runtime verification are not implemented. Do not call either profile ready. Boltz requires an explicit Liquid custody, fee, swap, and maximum-balance policy. Stripe requires separate test/live credentials per store and is not recurring billing.

Automated agents never initiate real-money BTC, XMR, Boltz, or Stripe live-mode payments.

## Routine inspection

After a validated deployment exists:

```bash
almapay status
almapay verify
almapay logs [service]
```

Non-production verification fails closed for implemented runtime checks but may warn and skip authenticated synchronization when no verification key is configured. Monitor service restarts, TLS, chain/indexer sync, disk and inodes. Backup and webhook monitoring cannot be considered complete while those checks are unimplemented.

Diagnostics must redact credentials, wallet material, descriptors, connection strings, and sensitive URLs. If a secret appears in output, rotate it, treat retained logs as exposed, and fix the redaction gap before production use.

## Backup, restore, and update

The commands are disabled. Current implementation creates no archive, extracts no archive, and performs no update. Production is therefore blocked.

The required future recovery design has two paired domains:

- Application backup as `almapay`: verified PostgreSQL logical export; BTCPay, plugin, and custody state; protected config/secrets; generated artifacts; lockfile; user service; non-secret Caddy source; authenticated manifest; encrypted off-host retention.
- Root-owned host recovery: active Caddy and relevant service overrides, subordinate-ID allocation, linger, firewall, SELinux customization, exact package inventory, and a manifest referencing the matching application backup.

The future restore order is host rebuild, exact identity/subordinate-ID restoration, pinned host setup without public traffic, application restore as `almapay`, loopback verification, Caddy restoration, then public verification. Never copy live rootless Podman storage as root. A database migration has no promised binary rollback; future updates must restore a complete verified pre-update recovery set.

## Troubleshooting

Start with the failing command's invariant; do not bypass it.

- Candidate-lock or placeholder error: finish pin research and validation. Do not change status merely to pass the gate.
- Wrong user: run runtime commands as the actual `almapay` account; do not substitute root.
- Secrets ownership/mode error: install the file as `almapay`, mode `0600`; do not loosen validation.
- Missing PyYAML: install the exact locked Python 3/PyYAML packages once a validated lock exists.
- Rootless failure: check subordinate IDs, linger, `/run/user/<uid>`, user D-Bus, and `XDG_RUNTIME_DIR`. Stop affected containers before an operator-approved `podman system migrate` as `almapay`.
- Compose validation failure: inspect the rendered model for off-lock images, ports, privilege, host namespaces, capabilities, socket/SSH/root mounts, database auth, Bitcoin arguments, or Monero pruning.
- Loopback works but public HTTPS fails: validate DNS, Caddy, TLS, and firewall without changing the private listener.
- Port 8080 is externally reachable: stop and correct the bind/firewall boundary.
- Sync is incomplete: wait and investigate health; do not enable a method to test connectivity.
- SELinux denial: fix labels or policy. Never switch to permissive/disabled as a workaround.
- Webhook replay causes duplicate fulfillment: fix the consumer application's idempotency; AlmaPay does not own its ledger.

Regtest is a Bitcoin-only fixture and does not prove installation, BTCPay settlement, optional plugins, or mainnet support.
