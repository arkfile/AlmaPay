# AlmaPay

AlmaPay is a deployment and operations toolkit for self-hosted [BTCPay Server](https://btcpayserver.org/) on AlmaLinux 10 and later. Its initial deployment profile is mainnet on x86-64-v3 using rootless Podman, an explicitly pinned external Compose provider, and host-installed Caddy. Integrators communicate with BTCPay through the Greenfield API and signed HTTPS webhooks rather than direct access to chain daemons or payment providers.

## Repository status

This repository is in the planning and initial implementation phase. It does not yet provide a production-ready clean-host quick start. Commands in the companion planning runbook contain placeholders and must not be applied to a production host. A runnable quick start will be published only after exact dependency pins, generated Compose output, SELinux behavior, backup and restore, and clean-VM installation have been tested.

The current documents are:

- [`docs/alma-pay-spec.md`](docs/alma-pay-spec.md): implementation contract and acceptance criteria.
- [`docs/alma-pay-server.md`](docs/alma-pay-server.md): non-production planning runbook.
- [`AGENTS.md`](AGENTS.md): mandatory repository guidance for coding agents.

## Initial supported profile

The first supported and tested profile is deliberately narrow:

- AlmaLinux 10.2 on x86_64 with x86-64-v3 CPU support, with AlmaLinux 10.0 or later as the version floor.
- A single host running one rootless Podman Compose project.
- BTCPay Server, PostgreSQL, NBXplorer, and a local pruned Bitcoin node.
- A shipped local-pruned mainnet Monero profile.
- Shipped, independently gated Boltz nodeless Lightning and Stripe Payments profiles.
- Host-installed Caddy as the only public HTTP/TLS entry point.
- BTCPay published only on the fixed listener `127.0.0.1:8080`.
- User-systemd persistence under a dedicated unprivileged `almapay` host account.

Mainnet is the only supported deployment network in the first release; regtest and mocks are test fixtures. Other architectures, networks, RHEL-family distributions, alternate reverse proxies, external RPC providers, split-host chain nodes, and other deployment modes are future profiles rather than currently supported configurations.

The stack is composed of dedicated containers rather than one monolithic container. Caddy remains outside the Compose project. Monero wallet configuration is server-wide in BTCPay; stores that must not share Monero treasury or view-key access require separate BTCPay deployments. AlmaPay automation never enables a payment method automatically; each method requires its own synchronization, custody, backup, restore, and operator-run payment approval.

Plan generously for the complete local profile: approximately 4 vCPU, 8 GB RAM, and 400 GB SSD as an initial planning estimate. Actual requirements must be measured against the selected pinned Bitcoin and Monero pruning profiles, database growth, backups, logs, and update headroom.

## Privilege and recovery model

Podman and application backup or restore operations run as `almapay`, never as root. Root-owned host state—such as the active Caddy configuration, firewall policy, subordinate-ID allocation, and SELinux customization—is backed up separately through ordinary host administration tooling. AlmaPay retains a non-secret Caddy source template so the active root-owned configuration can be regenerated during recovery. Production readiness requires a verified encrypted off-host application backup and a tested matching host-recovery bundle; an interactive Arkfile upload may be used initially, but Arkfile must not be the only retained copy.
