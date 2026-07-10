`NOTE: Agents, agentic coding tools, and LLMs must read this document before working in the AlmaPay repository.`

# AlmaPay: guidance for agents

## Project overview

AlmaPay is an application-agnostic deployment and operations toolkit for self-hosted BTCPay Server on AlmaLinux 10 and later.

It automates and documents:

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

1. `docs/alma-pay-spec.md`, the current implementation contract.
2. `docs/alma-pay-server.md`, the companion planning runbook.
3. `README.md`, the repository status and supported-scope summary.

The following files are planned implementation deliverables and may not exist yet:

- `docs/architecture.md`
- `docs/security.md`
- `docs/installation.md`
- `docs/integrator-guide.md`
- `docs/reference-integrations/arkfile.md`
- `docs/operations.md`
- `docs/backup-and-restore.md`
- `docs/production-readiness.md`
- `upstream.lock`

Do not treat planning commands containing placeholders as production-ready instructions. Current upstream behavior and exact pins must be researched and tested before runnable deployment guidance is published.

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

## Current supported scope

The initial supported deployment profile is:

- AlmaLinux 10.0 or later, with AlmaLinux 10.2 as the first tested release.
- Host-installed Caddy as the only public HTTP/TLS entry point.
- A local pruned Bitcoin node.
- Optional local pruned Monero.
- A single-host payment stack.

Other RHEL-family distributions, alternate reverse proxies, external RPC providers, split-host chain nodes, and other modes are future profiles. Do not describe them as supported until they have explicit implementation, security validation, and integration tests.

## Required platform assumptions

The implementation must preserve these minimum versions:

- AlmaLinux 10.0 or later.
- BTCPay Server 2.4.0 or later.
- Bitcoin Core 30.0 or later.
- Rootless Podman with cgroup v2.
- SELinux enforcing in production.

Exact production dependencies must be pinned in `upstream.lock`. Minimum-version requirements do not permit floating tags, moving branches, or unreviewed updates.
Do not silently change dependency pins. Research upstream compatibility, explain the change, regenerate deployment artifacts, inspect the resulting diff, and update relevant tests and documentation.

## Security invariants

Preserve these invariants in every change:

- Podman and the container lifecycle execute under the unprivileged `almapay` host account.
- Podman is never run as root.
- BTCPay is published only on a loopback high port.
- Host Caddy is the only public HTTP/TLS entry point.
- PostgreSQL, NBXplorer, Bitcoin RPC, Monero RPC, and wallet RPC ports are never publicly published.
- Containers are never privileged.
- Broad capabilities are never granted.
- Container-engine sockets are never mounted.
- Host SSH keys and the host root filesystem are never mounted.
- BTCPay host SSH integration remains disabled.
- SELinux is not disabled or weakened to make deployment easier.
- Secrets are never committed, printed, logged, invented, or passed in process arguments.
- Mainnet payment methods remain disabled until production-readiness checks pass.

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
