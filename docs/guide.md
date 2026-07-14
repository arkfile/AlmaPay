# AlmaPay guide

This is the active operator and integrator reference for AlmaPay. Normative requirements remain in [alma-pay-spec.md](alma-pay-spec.md).

## Table of contents

1. [Install](#1-install)
2. [Commands](#2-commands)
3. [Architecture and security](#3-architecture-and-security)
4. [Running the stack](#4-running-the-stack)
5. [Integrating your application](#5-integrating-your-application)
6. [Production readiness](#6-production-readiness)
7. [Troubleshooting](#7-troubleshooting)
8. [Recovery (planned)](#8-recovery-planned)

---

## 1. Install

AlmaPay is **not production-ready today.** The repository `upstream.lock` remains a candidate lock with unresolved placeholders. Backup, restore, update, and `verify --production` deliberately fail closed. No AlmaLinux VM integration has run.

The path below is for trying AlmaPay on your own AlmaLinux 10+ VPS **before** the repository lock is promoted. It uses a **host-specific staging lock** at `/var/lib/almapay/upstream.lock`, repository-based bootstrap, and fixed chaindata directories so Bitcoin and Monero data survive script and Compose iteration.

Clone the repository on the VPS (example: `/opt/almapay`). All commands below use `./bin/almapay` from that directory unless noted.

### Chaindata preservation

Blockchain and application data live under fixed host paths:

```text
/var/lib/almapay/chaindata/bitcoin
/var/lib/almapay/chaindata/bitcoin-wallet
/var/lib/almapay/chaindata/monero
/var/lib/almapay/chaindata/postgres
/var/lib/almapay/chaindata/btcpay
```

Compose bind-mounts these paths directly. Re-running `install`, pulling updated AlmaPay scripts, or regenerating Compose **does not** move or delete them.

**Do not** run `podman compose down -v`, `podman volume rm`, or wipe `/var/lib/almapay/chaindata` unless you intend to re-sync chains.

### One-time VPS setup

#### 1. Inspect the host

```bash
sudo ./bin/almapay doctor
```

#### 2. Write the host staging lock

```bash
sudo ./bin/almapay lock-research --install-packages --write /var/lib/almapay/upstream.lock
```

The CLI auto-uses this file when present. You do **not** need to commit it to git.

#### 3. Bootstrap the host

```bash
sudo ./bin/almapay bootstrap-host --from-repos
```

#### 4. Configure (interactive — one prompt)

```bash
sudo ./bin/almapay configure
```

You are prompted only for the **public BTCPay domain** (example: `pay.example.com`). AlmaPay writes `/var/lib/almapay/almapay.env` and `/var/lib/almapay/secrets.env`, auto-generates the PostgreSQL password (never printed), enables **Monero local-pruned by default**, and sets correct ownership and modes.

Non-interactive equivalent:

```bash
sudo ./bin/almapay configure --noninteractive --domain pay.example.com --force
```

Use `--no-monero` only if you intentionally want Bitcoin without a local Monero node. Use `--set-postgres-password` to type a password with hidden terminal entry instead of auto-generation.

Legacy manual copies from `config/*.example` remain valid if you prefer them.

The production paths are:

```text
/var/lib/almapay/almapay.env
/var/lib/almapay/secrets.env
```

`secrets.env` must be a regular file owned by `almapay` with mode `0600`. It must contain a non-example `POSTGRES_PASSWORD` of at least 24 characters. Keep all real credentials out of repositories, shell arguments, history, and logs.

The initial configuration accepts mainnet, `127.0.0.1:8080`, local-pruned Bitcoin, disabled or local-pruned Monero, disabled or `boltz-nodeless` Lightning, disabled or `stripe` cards, and HTTP-01 ACME. Selection does not mean the optional method is installed or ready.

#### 5. Build the generator and finalize the host lock

```bash
sudo -u almapay -H ./bin/almapay lock-research --build-generator --write /var/lib/almapay/upstream.lock
```

#### 6. Install, enable Caddy, start

```bash
sudo -u almapay -H ./bin/almapay install
sudo ./bin/almapay configure --install-caddy
sudo -u almapay -H ./bin/almapay start
sudo -u almapay -H ./bin/almapay verify
```

Point DNS for your domain at the VPS before `verify` checks public HTTPS. Do not use `verify --production` for staging; it remains intentionally blocked.

`install` performs the complete implemented pipeline: fetches the pinned upstream source, ensures or builds the pinned local generator, runs it with mandatory variables, semantically renders and validates Compose, pulls exact digest images, installs/enables the user-systemd service with `secrets.env` as `EnvironmentFile`, and renders and validates Caddy.

Compose validation checks exact lock digests, the sole `127.0.0.1:8080:49392` mapping, absence of every other published port, privilege/capability/host-namespace and dangerous-mount restrictions, disabled SSH integration, SCRAM placeholders and authenticated database strings, complete Bitcoin arguments, and Monero pruning. Do not weaken a failed check to make installation proceed.

`almapay research-generator` is the one candidate-lock exception. It fetches the pinned generator source, prints the Dockerfile hash and upstream base references, and—after both base-image digests and that hash have been recorded—builds the deterministic candidate and prints its image digest. It never edits or promotes `upstream.lock`; the operator must independently verify every reported value.

### Iterating on AlmaPay scripts

```bash
sudo -u almapay -H ./bin/almapay stop
sudo -u almapay -H ./bin/almapay install
sudo ./bin/almapay configure --install-caddy
sudo -u almapay -H ./bin/almapay start
```

### What remains manual

- BTCPay administrator registration, store/API key/webhook setup
- Monero plugin installation and payment enablement in BTCPay
- Encrypted backup and restore
- Human mainnet payment acceptance

Do not deploy to a production VPS until the blockers in [section 6](#6-production-readiness) are closed. Agents have no production VPS access; an authorized human operator runs host commands.

---

## 2. Commands

Only `bootstrap-host` runs as root. Installation and every runtime operation require the dedicated `almapay` account. Never use Docker or `sudo podman`.

```text
almapay doctor
almapay bootstrap-host                  # root only; --from-repos for staging
almapay lock-research                   # write host staging lock
almapay configure                       # root; interactive or --domain
almapay install                         # almapay
almapay generate [--build-generator]    # almapay; currently lock-blocked
almapay research-generator              # almapay; candidate-lock evidence only
almapay start | stop | restart          # almapay
almapay status | logs [service]         # almapay
almapay verify [--production]           # almapay
almapay render-caddy                    # almapay
almapay backup | restore | update       # deliberately disabled
```

---

## 3. Architecture and security

AlmaPay is application-agnostic payment infrastructure, not a billing engine, ledger, SDK, recurring-subscription system, or multi-tenant SaaS. The architecture is implemented only in part and is not production-proven.

### Topology

```text
Internet
   |
Host Caddy: public 80/443 and TLS
   |
127.0.0.1:8080
   |
BTCPay Server --- PostgreSQL
      |
      +--- NBXplorer --- local pruned Bitcoin Core
      |
      +--- optional local pruned Monero services
      |
      +--- optional plugins after independent approval
```

The intended first profile is one AlmaLinux 10+ x86-64-v3 host, `/var/lib/almapay` as the fixed data root, rootless Podman under `almapay`, mainnet, host Caddy, and user-systemd persistence. Regtest and mocks are fixtures, not deployment profiles.

Monero runtime services can be generated, but plugin, custody, backup/restore, privacy, and payment proof remain operator gates. Boltz nodeless and Stripe are selectable and have candidate pins/documentation, but stable installation and runtime verification are not implemented.

### Security invariants

1. Podman and the container lifecycle run only under the unprivileged `almapay` host account.
2. Podman is never run as root; Docker and Docker Compose are never used.
3. BTCPay is published only on `127.0.0.1:8080`.
4. Host-installed Caddy is the only public HTTP/TLS entry point.
5. The initial data root is fixed at `/var/lib/almapay`.
6. PostgreSQL, NBXplorer, Bitcoin RPC, Monero RPC, and wallet RPC are never publicly published.
7. Containers are never privileged and receive no broad capabilities.
8. Container-engine sockets are never mounted.
9. Host SSH keys and the host root filesystem are never mounted.
10. BTCPay host SSH integration remains disabled.
11. SELinux remains enforcing in production and is never weakened as a workaround.
12. Secrets are never committed, printed, logged, invented, or passed in process arguments.
13. Automation never enables a mainnet payment method; a human approves each method only after its synchronization, custody, backup, restore, plugin, and real-payment gates pass.

A container process may report UID 0 inside its namespace. The invariant is that its UID maps through the unprivileged `almapay` user namespace and never becomes host root.

### Privilege and trust boundaries

Only `bootstrap-host` uses root. It installs exact locked host packages, creates the service identity and data root, allocates subordinate IDs, enables linger, and configures the narrow host firewall boundary. Runtime commands require the `almapay` account.

The application and root-owned host state are separate recovery domains. Future `almapay backup` and `restore` operations must run as `almapay` and use logical or service-aware exports; root must not copy live rootless Podman storage. Active Caddy configuration, firewall state, subordinate-ID allocations, SELinux customization, and package inventory belong to ordinary root-owned host recovery.

Consumer applications own users, invoices-to-business-record mappings, balances, fulfillment, retries, reconciliation, and webhook idempotency. Separate BTCPay stores provide credential and business-state separation under one trusted operator, not isolation from the host operator or other BTCPay administrators. Monero wallet view material is server-wide; independent custody requires separate deployments.

### Configuration and secrets

Operator config and `secrets.env` are parsed as strict allow-listed `KEY=VALUE` data and are never sourced as shell. Expansion and command substitution are not evaluated. The secrets file must be a regular non-symlink file, owned by `almapay`, mode `0600`. The generated user-systemd unit loads it through `EnvironmentFile`.

Root-owned secrets, such as future DNS-01 provider credentials, are outside the AlmaPay application secrets file and need separate operator-controlled recovery.

### Supply chain and Compose model

`upstream.lock` is the source of exact package, source, image, generator, and plugin identity. A candidate lock or any `PENDING`/`REPLACE` value blocks release operations. Python 3 and PyYAML are locked host dependencies because Compose is rendered and validated as a YAML data model, not with text matching.

Installation is designed to fetch the pinned `btcpayserver-docker` commit, build or verify the pinned local generator, pass mandatory generator variables explicitly, render the semantic Compose model, pull exact linux/amd64 image digests, install a user-systemd unit with protected secrets, and render and validate the Caddy source.

Semantic Compose validation requires:

- every service image to equal its lockfile digest;
- exactly one published mapping, `127.0.0.1:8080:49392`, and no other host ports;
- no privileged mode, added capabilities, host network/PID/IPC namespaces, engine sockets, host root/SSH mounts, or BTCPay host SSH configuration;
- SCRAM PostgreSQL placeholders and authenticated BTCPay/NBXplorer connection strings;
- the complete Bitcoin RPC, peer, memory, full-RBF, and pruning arguments with `CREATE_WALLET=false`;
- Monero `--prune-blockchain` when Monero is present.

The generator excludes the old Bitcoin and Tor/socket fragments, uses the Core 30+ path, removes upstream Docker helper scripts, and must work with SELinux enforcing.

### Runtime and persistence

One user service owned by `almapay` manages the Compose project using the pinned external `podman-compose` provider and linger. Host Caddy remains separately root-owned. Quadlet is a possible future backend only after equivalence testing.

Non-production `verify` fails closed on required runtime checks such as exact container digests, systemd state, loopback/public health, listener exposure, PostgreSQL readiness, BTCPay and Bitcoin version floors, and synchronization when credentials are configured. `verify --production` is deliberately blocked pending the additional readiness checks in [section 6](#6-production-readiness).

### Privacy and capacity

AlmaPay does not require or enrich consumer PII. Logging and network-identifier retention are deployment-wide properties; consumers with incompatible policies need separate hosts. Arkfile has a stricter no-client-IP-retention gate described in its [reference profile](reference-integrations/arkfile.md).

Capacity must be measured against the locked profiles, chain growth, database, plugins, backups, logs, and update headroom. Rough planning figures such as 4 vCPU, 8 GB RAM, and 500 GB SSD are estimates, not acceptance criteria.

---

## 4. Running the stack

### First-start operator gates

The operator, not AlmaPay automation, must:

1. Complete BTCPay administrator registration, passkeys/MFA, and recovery.
2. Create a separate store, API key, and webhook secret for each consumer and environment.
3. Wait for chain and NBXplorer synchronization.
4. Choose wallet and custody policy and secure recovery material.
5. Install and verify plugins only through a stable tested process.
6. Complete the applicable [production readiness](#6-production-readiness) gates before enabling a mainnet method.

#### Bitcoin

Use descriptor or xpub workflows. `CREATE_WALLET=false`; do not create legacy BDB wallets or use removed import/dump RPCs. Bitcoin RPC remains internal. Runtime verification must query a numeric version of at least `300000` and confirm NBXplorer synchronization.

#### Monero

The generator can include pruned Monero services and internal RPC. This is not production support: plugin installation, view-only custody, account-index policy, backup/restore, privacy, and payment proof remain unresolved gates. AlmaPay never accepts or backs up spend keys. Stores share server-wide wallet view material; use separate deployments for true treasury separation.

#### Boltz and Stripe

Configuration choices and candidate pins exist, but stable plugin installation and runtime verification are not implemented. Do not call either profile ready. Boltz requires an explicit Liquid custody, fee, swap, and maximum-balance policy. Stripe requires separate test/live credentials per store and is not recurring billing.

Automated agents never initiate real-money BTC, XMR, Boltz, or Stripe live-mode payments.

### Routine inspection

After a validated deployment exists:

```bash
almapay status
almapay verify
almapay logs [service]
```

Non-production verification fails closed for implemented runtime checks but may warn and skip authenticated synchronization when no verification key is configured. Monitor service restarts, TLS, chain/indexer sync, disk and inodes. Backup and webhook monitoring cannot be considered complete while those checks are unimplemented.

Diagnostics must redact credentials, wallet material, descriptors, connection strings, and sensitive URLs. If a secret appears in output, rotate it, treat retained logs as exposed, and fix the redaction gap before production use.

---

## 5. Integrating your application

AlmaPay hosts BTCPay. Your application owns users, business records, invoice mapping, balances, fulfillment, retries, reconciliation, and webhook idempotency.

AlmaPay is not a billing engine, account system, credit ledger, payment gateway abstraction, client SDK, recurring-subscription system, or multi-tenant SaaS.

### What you get

- Customer-facing checkout on the public HTTPS origin (for example `https://pay.example.com`)
- Store-scoped Greenfield API access
- Signed HTTPS webhook delivery
- Operational verification of the payment stack

What you do not get:

- A universal invoice metadata schema
- A shared application credential or global app URL
- Direct access to Bitcoin, Monero, Boltz, or Stripe from your app
- Isolation against the shared host operator (separate stores are credential separation under one trusted operator)

### Store and credential model

For each consumer application and environment:

1. Create or select a dedicated BTCPay store.
2. Issue a least-privilege, store-scoped Greenfield API key.
3. Register one or more HTTPS webhook endpoints you control.
4. Store API keys and webhook secrets outside AlmaPay and application source repositories.
5. Rotate or revoke one consumer's credentials without touching another.

Credentials for one store must not read or mutate another store. Server-wide plugins, logging policy, and some custody material remain shared. Monero wallet view material is server-wide; apps that need independent treasury or conflicting host policies need separate AlmaPay deployments.

### Public origin only

Always configure and return the public BTCPay hostname for checkout. Never put `127.0.0.1:8080` in integrator config or customer links. That address is Caddy's private upstream only.

### Typical Greenfield flow

Create an invoice (shape only; not Arkfile-specific):

```http
POST /api/v1/stores/{storeID}/invoices
Authorization: token <store-scoped-api-key>
Content-Type: application/json
```

Direct the customer to the returned `checkoutLink` on the public origin. Poll invoice status when needed:

```http
GET /api/v1/stores/{storeID}/invoices/{invoiceID}
Authorization: token <store-scoped-api-key>
```

Webhook delivery uses an HMAC signature header of the form:

```text
BTCPay-Sig: sha256=<hex HMAC-SHA256 of raw body>
```

Verify the signature over the exact raw body, bound request size, validate the expected store, and apply your own payable-status and fulfillment rules.

### Application responsibilities

Design and implement:

- Idempotent webhook handling (replays must not double-fulfill)
- Retries and missed-webhook recovery (poll or reconcile remotely settled invoices)
- Mapping between BTCPay invoice IDs and your local business records
- Privacy and retention for any metadata you choose to send
- Credential rotation without downtime assumptions across unrelated stores

Minimize invoice metadata. AlmaPay does not require consumer PII and must not invent it on your behalf.

### Testing without enabling mainnet methods

- Use AlmaPay's static contract, Compose, and lock fixtures in CI where applicable.
- Exercise create-invoice, checkout URL shape, webhook signature verification, replay, and reconciliation against fixtures.
- The optional Bitcoin-only regtest does not settle a BTCPay invoice and is not a supported deployment profile.
- Do not enable mainnet payment methods until the operator completes per-method gates in [section 6](#6-production-readiness).

The canonical integration acceptance checklist is in [section 6](#6-production-readiness). It covers least privilege, cross-store isolation, public checkout origin, signed-webhook replay, missed-webhook reconciliation, and credential rotation.

### Example consumer environment (placeholders)

```ini
YOUR_APP_BTCPAY_SERVER_URL=https://pay.example.com
YOUR_APP_BTCPAY_STORE_ID=<store-id>
YOUR_APP_BTCPAY_API_KEY=<restricted-api-key>
YOUR_APP_BTCPAY_WEBHOOK_SECRET=<webhook-secret>
```

AlmaPay never writes these into your application repository. The operator supplies them securely.

For a reference integration profile, see [Arkfile](reference-integrations/arkfile.md).

---

## 6. Production readiness

This is AlmaPay's only go-live checklist. Mainnet acceptance is a human sign-off bound to one host, configuration, lockfile, stores, and enabled methods. Automation never enables a payment method.

### Current blockers

All items below are open, so production is blocked:

- [ ] Promote `upstream.lock` from `candidate` only after replacing every `PENDING`/`REPLACE` value and validating package sources, generator build, images, and plugins.
- [ ] Exercise install and runtime on a clean AlmaLinux 10.2 x86-64-v3 VM; repeat install, reboot, and verify persistence.
- [ ] Fully implement and test application backup, authenticated manifests, encryption, off-host retention, and restore.
- [ ] Fully implement and test lockfile-driven update with verified pre-update recovery.
- [ ] Implement and pass `verify --production` plugin, backup/restore, privacy, Greenfield-permission, and webhook checks.
- [ ] Implement stable Monero plugin/custody verification and stable Boltz/Stripe installation and runtime verification before calling those methods supported.

The current local suite has 53 top-level passes, optional ShellCheck, and semantic Python subtests. The optional Bitcoin-only regtest does not settle a BTCPay invoice. Neither local fixtures nor regtest substitute for AlmaLinux VM or production acceptance.

### Host and deployment

- [ ] Supported AlmaLinux version and x86-64-v3 capability confirmed.
- [ ] Exact locked Python 3, PyYAML, Podman, `podman-compose`, Caddy, and other packages installed from verified sources.
- [ ] DNS, public TLS, time synchronization, updates, SSH, and firewall reviewed without lockout risk.
- [ ] SELinux enforcing throughout install and runtime.
- [ ] Rootless Podman runs only under `almapay`; linger and user systemd survive reboot.
- [ ] Data root is `/var/lib/almapay`.
- [ ] Host Caddy is the sole public HTTP/TLS endpoint.
- [ ] BTCPay has exactly `127.0.0.1:8080:49392`; no internal or unexpected host port is published.
- [ ] Rendered Compose passes exact-digest, privilege, capability, namespace, mount, SSH, database-auth, Bitcoin-argument, and Monero-pruning checks.
- [ ] Runtime queries prove BTCPay >= 2.4.0 and Bitcoin Core numeric version >= 300000.
- [ ] `verify --production` passes and records non-secret config and lockfile hashes.

### Recovery and operations

- [ ] Verified encrypted off-host application backup exists with a current authenticated manifest.
- [ ] Matching protected host-recovery bundle records Caddy, subordinate IDs, linger, firewall, SELinux customization, package inventory, and application-backup identity.
- [ ] Decryption and recovery material has independent custody.
- [ ] Clean-host restore from the paired recovery set passes.
- [ ] Update from one validated lock to another passes, including recovery after a post-migration failure.
- [ ] Monitoring covers service health/restarts, certificate expiry, disk/inodes, chain/indexer sync, failed backups, and failed webhooks.

See [section 8](#8-recovery-planned) for the required recovery design; the commands are currently disabled.

### Consumer integrations

- [ ] Each consumer and environment has a separate store, least-privilege API key, and webhook secret.
- [ ] Checkout links use only the public HTTPS origin.
- [ ] Invoice creation/read permissions are tested and cross-store access is denied.
- [ ] Exact raw-body webhook signature verification, request bounds, expected-store validation, replay idempotency, retry, and missed-webhook reconciliation pass.
- [ ] Credential rotation affects only the selected integration.
- [ ] Any reference-specific gates, such as [Arkfile's](reference-integrations/arkfile.md), pass.

### Custody and per-method approval

For every method intended for enablement:

- [ ] Chain or provider readiness is verified.
- [ ] Custody policy and offline recovery material are documented.
- [ ] Relevant wallet/plugin data is included in a successful restore drill.
- [ ] Exact plugin release, compatibility, provenance, installation, restart, and enabled state are verified.
- [ ] Representative fixture or provider test-mode flow passes.
- [ ] Human operator performs an explicitly authorized low-value mainnet or live-mode payment using their own credentials and funds.
- [ ] Approval is recorded against the current production-verification report and lockfile hashes.

Additional method gates:

- [ ] Bitcoin descriptor/watch-only policy and NBXplorer synchronization are proven.
- [ ] Monero uses view-only material without spend keys; server-wide custody is accepted or a separate deployment is used.
- [ ] Boltz Liquid custody, fees, swaps, and maximum balance are accepted.
- [ ] Stripe test/live credentials are separated per store and live mode is explicitly approved.

Automated agents may prepare and verify procedures but never initiate, custody, refund, or dispute real funds.

### Privacy

- [ ] Deployment-wide logging and retention policy is documented and tested on success and failure paths.
- [ ] Diagnostics redact credentials, wallet material, connection strings, sensitive URLs, and consumer data.
- [ ] Integrators minimize invoice metadata and meet their own legal/retention obligations.
- [ ] Arkfile deployments prove that Caddy, BTCPay, journald, and AlmaPay diagnostics do not retain client IP addresses.

### Sign-off

Production is ready only when every applicable box is checked and a human operator records the evidence. Presence of AlmaPay code, a running container, or a selectable profile is not authorization to accept payments.

For normative acceptance requirements, read [alma-pay-spec.md](alma-pay-spec.md).

---

## 7. Troubleshooting

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

---

## 8. Recovery (planned)

The `backup`, `restore`, and `update` commands are disabled. Current implementation creates no archive, extracts no archive, and performs no update. Production is therefore blocked.

The required future recovery design has two paired domains:

- Application backup as `almapay`: verified PostgreSQL logical export; BTCPay, plugin, and custody state; protected config/secrets; generated artifacts; lockfile; user service; non-secret Caddy source; authenticated manifest; encrypted off-host retention.
- Root-owned host recovery: active Caddy and relevant service overrides, subordinate-ID allocation, linger, firewall, SELinux customization, exact package inventory, and a manifest referencing the matching application backup.

The future restore order is host rebuild, exact identity/subordinate-ID restoration, pinned host setup without public traffic, application restore as `almapay`, loopback verification, Caddy restoration, then public verification. Never copy live rootless Podman storage as root. A database migration has no promised binary rollback; future updates must restore a complete verified pre-update recovery set.
