# Design and security model

AlmaPay is application-agnostic payment infrastructure, not a billing engine, ledger, SDK, recurring-subscription system, or multi-tenant SaaS. This document explains the intended architecture and trust boundaries. The normative contract is [alma-pay-spec.md](alma-pay-spec.md).

## Current posture

The architecture is implemented only in part and is not production-proven. `upstream.lock` remains a candidate with unresolved placeholders, so deployment and runtime commands that require a release lock intentionally block. No AlmaLinux VM integration has run.

## Initial topology

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

## Security invariants

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

## Privilege and trust boundaries

Only `bootstrap-host` uses root. It installs exact locked host packages, creates the service identity and data root, allocates subordinate IDs, enables linger, and configures the narrow host firewall boundary. Runtime commands require the `almapay` account.

The application and root-owned host state are separate recovery domains. Future `almapay backup` and `restore` operations must run as `almapay` and use logical or service-aware exports; root must not copy live rootless Podman storage. Active Caddy configuration, firewall state, subordinate-ID allocations, SELinux customization, and package inventory belong to ordinary root-owned host recovery.

Consumer applications own users, invoices-to-business-record mappings, balances, fulfillment, retries, reconciliation, and webhook idempotency. Separate BTCPay stores provide credential and business-state separation under one trusted operator, not isolation from the host operator or other BTCPay administrators. Monero wallet view material is server-wide; independent custody requires separate deployments.

## Configuration and secrets

Operator config and `secrets.env` are parsed as strict allow-listed `KEY=VALUE` data and are never sourced as shell. Expansion and command substitution are not evaluated. The secrets file must be a regular non-symlink file, owned by `almapay`, mode `0600`. The generated user-systemd unit loads it through `EnvironmentFile`.

Root-owned secrets, such as future DNS-01 provider credentials, are outside the AlmaPay application secrets file and need separate operator-controlled recovery.

## Supply chain and Compose model

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

## Runtime and persistence

One user service owned by `almapay` manages the Compose project using the pinned external `podman-compose` provider and linger. Host Caddy remains separately root-owned. Quadlet is a possible future backend only after equivalence testing.

Non-production `verify` fails closed on required runtime checks such as exact container digests, systemd state, loopback/public health, listener exposure, PostgreSQL readiness, BTCPay and Bitcoin version floors, and synchronization when credentials are configured. `verify --production` is deliberately blocked pending the additional readiness checks listed in [production-readiness.md](production-readiness.md).

## Privacy and capacity

AlmaPay does not require or enrich consumer PII. Logging and network-identifier retention are deployment-wide properties; consumers with incompatible policies need separate hosts. Arkfile has a stricter no-client-IP-retention gate described in its [reference profile](reference-integrations/arkfile.md).

Capacity must be measured against the locked profiles, chain growth, database, plugins, backups, logs, and update headroom. Rough planning figures such as 4 vCPU, 8 GB RAM, and 500 GB SSD are estimates, not acceptance criteria.
