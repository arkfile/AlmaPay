`NOTE: Agents, agentic coding tools, and LLMs must read this document before working in the AlmaPay repository.`

# AlmaPay: guidance for agents

## Project overview

AlmaPay is an application-agnostic deployment and operations toolkit under development for self-hosted BTCPay Server on AlmaLinux 10 and later.

Its contract covers:

- Rootless Podman host preparation.
- BTCPay Compose generation.
- BTCPay Server 2.4 or later.
- Bitcoin Core 30 or later.
- PostgreSQL and NBXplorer.
- Optional Monero, Boltz, and Stripe support.
- Host-installed Caddy.
- User systemd persistence.
- Verification, updates, backup, and restoration.
- Greenfield API and webhook integration guidance.

AlmaPay may serve multiple consumer applications through separate BTCPay stores, API keys, and webhook secrets. Arkfile is the first reference integration used to prove AlmaPay, but Arkfile is not embedded in or required by the AlmaPay runtime.

## Documentation authority

Before making changes, read:

1. `docs/alma-pay-spec.md`: normative implementation contract; requirements are not claims that implementation is complete.
2. `README.md`: concise current status and persona routing.
3. `docs/design.md`: active architecture, trust boundaries, and security-invariant explanation.
4. `docs/operator-guide.md`: active command and operational guidance.
5. `docs/production-readiness.md`: the only go-live checklist.
6. `docs/integrator-guide.md`: generic consumer integration guidance.
7. `docs/reference-integrations/arkfile.md`: Arkfile-only reference material.

Material under `docs/archive/` is historical only. It must not be linked as active installation guidance. Current upstream behavior and exact pins must be researched and tested before runnable deployment guidance is published.

## Current implementation status

- `upstream.lock` is `candidate` and contains unresolved `PENDING` and `REPLACE` values. Bootstrap, install, generation, start, and verification require a `validated` or `production` lock and intentionally block today.
- Configuration and secrets files are strict `KEY=VALUE` data; they are never sourced. `secrets.env` must be owned by `almapay` with mode `0600`.
- Only `bootstrap-host` runs as root. Runtime commands require the `almapay` account.
- Backup, restore, and update deliberately fail closed. `verify --production` deliberately blocks on unfinished production checks.
- Boltz and Stripe are selectable but do not have stable installation or runtime verification. Monero services can be generated, but plugin, custody, and readiness gates are not production-proven.
- Local fixtures pass; no AlmaLinux VM integration has run. Agents have no production VPS access.

## Product boundary

AlmaPay operates payment infrastructure. It is not:

- An application billing engine.
- A customer account system.
- A credit or transaction ledger.
- A payment gateway abstraction.
- A client SDK.
- A recurring-subscription system.
- A multi-tenant SaaS service.

Consumer applications remain responsible for their users, business records, invoice mapping, balances, fulfillment, retries, reconciliation, and webhook idempotency.
Do not add Arkfile-specific business logic to AlmaPay core modules. Arkfile-specific documentation and test fixtures must remain isolated under clearly named reference-integration locations.
Do not modify Arkfile or another consumer application from this repository.

## Initial target scope

The intended initial deployment profile is below. It is not currently a production-supported profile:

- Mainnet on AlmaLinux 10.0 or later, with AlmaLinux 10.2 on x86_64 and x86-64-v3 as the first tested platform.
- Host-installed Caddy as the only public HTTP/TLS entry point.
- A local pruned Bitcoin node.
- A local-pruned Monero service profile, still gated on plugin, custody, restore, and payment proof.
- Candidate Boltz nodeless Lightning and Stripe Payments selections, still lacking stable installation and runtime verification.
- A single-host payment stack.

Regtest and mocks are test fixtures, not supported deployment profiles. Other architectures, networks, RHEL-family distributions, alternate reverse proxies, external RPC providers, split-host chain nodes, and other modes are future profiles. Do not describe any profile as supported until it has explicit implementation, security validation, and integration tests.

## Required platform assumptions

The implementation must preserve these minimum versions:

- AlmaLinux 10.0 or later.
- x86_64 with x86-64-v3 CPU support for the initial profile.
- BTCPay Server 2.4.0 or later.
- Bitcoin Core 30.0 or later.
- Rootless Podman with cgroup v2.
- SELinux enforcing in production.

Exact production dependencies must be pinned in `upstream.lock`. Minimum-version requirements do not permit floating tags, moving branches, or unreviewed updates.
Do not silently change dependency pins. Research upstream compatibility, explain the change, regenerate deployment artifacts, inspect the resulting diff, and update relevant tests and documentation.

## Security invariants

The concise canonical invariant list and rationale are in `docs/design.md`. The mandatory rules below remain binding for every change.

Preserve these invariants in every change:

- Podman and the container lifecycle execute under the unprivileged `almapay` host account.
- Podman is never run as root.
- BTCPay is published only on a loopback high port.
- The initial data root and listener are fixed at `/var/lib/almapay` and `127.0.0.1:8080`.
- Host Caddy is the only public HTTP/TLS entry point.
- PostgreSQL, NBXplorer, Bitcoin RPC, Monero RPC, and wallet RPC ports are never publicly published.
- Containers are never privileged.
- Broad capabilities are never granted.
- Container-engine sockets are never mounted.
- Host SSH keys and the host root filesystem are never mounted.
- BTCPay host SSH integration remains disabled.
- SELinux is not disabled or weakened to make deployment easier.
- Secrets are never committed, printed, logged, invented, or passed in process arguments.
- AlmaPay automation never enables mainnet payment methods. Each method remains disabled until its own synchronization, custody, backup, restore, plugin, and operator-run real-payment checks pass.

Rootless Podman does not guarantee that every process has a nonzero UID inside its container namespace. The invariant is that container UIDs are mapped through the unprivileged `almapay` user namespace and do not become host root.

If a proposed change weakens one of these invariants, stop and raise it with the developer.

## Privilege boundary

AlmaPay application backup and restore operations run as `almapay`. They use logical database exports and Podman-aware application-data exports; they do not copy live rootless Podman storage as root.

Root-owned host configuration is a separate recovery domain handled by ordinary host backup tooling. It includes active Caddy configuration, relevant systemd overrides, subordinate-ID allocation, firewall state, SELinux customization, and package inventory. AlmaPay retains a non-secret Caddy source template from which the active root-owned configuration can be reinstalled.

A root-owned scheduler may coordinate both domains and invoke `almapay backup` with `sudo -u almapay`, but it must never invoke Podman as root.

## Rootless Podman only

Do not use Docker or invoke Docker commands.

Do not run:

```text
docker
docker compose
sudo podman
sudo podman compose
```

Never connect to or modify a production host without explicit authorization. Avoid unattended wallet or mainnet custody actions. Do not create Git commits unless the operator explicitly requests one. Do not use emojis in repository content.

Automated agents must never initiate real-money BTC, XMR, Boltz, or Stripe live-mode payments. They may implement and verify the operator procedure, but the human operator supplies authorization, credentials, custody decisions, and funds.
