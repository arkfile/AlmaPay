# Production readiness

This is AlmaPay's only go-live checklist. Mainnet acceptance is a human sign-off bound to one host, configuration, lockfile, stores, and enabled methods. Automation never enables a payment method.

## Current blockers

All items below are open, so production is blocked:

- [ ] Promote `upstream.lock` from `candidate` only after replacing every `PENDING`/`REPLACE` value and validating package sources, generator build, images, and plugins.
- [ ] Exercise install and runtime on a clean AlmaLinux 10.2 x86-64-v3 VM; repeat install, reboot, and verify persistence.
- [ ] Fully implement and test application backup, authenticated manifests, encryption, off-host retention, and restore.
- [ ] Fully implement and test lockfile-driven update with verified pre-update recovery.
- [ ] Implement and pass `verify --production` plugin, backup/restore, privacy, Greenfield-permission, and webhook checks.
- [ ] Implement stable Monero plugin/custody verification and stable Boltz/Stripe installation and runtime verification before calling those methods supported.

The current local suite has 43 top-level passes, optional ShellCheck, and semantic Python subtests. The optional Bitcoin-only regtest does not settle a BTCPay invoice. Neither local fixtures nor regtest substitute for AlmaLinux VM or production acceptance.

## Host and deployment

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

## Recovery and operations

- [ ] Verified encrypted off-host application backup exists with a current authenticated manifest.
- [ ] Matching protected host-recovery bundle records Caddy, subordinate IDs, linger, firewall, SELinux customization, package inventory, and application-backup identity.
- [ ] Decryption and recovery material has independent custody.
- [ ] Clean-host restore from the paired recovery set passes.
- [ ] Update from one validated lock to another passes, including recovery after a post-migration failure.
- [ ] Monitoring covers service health/restarts, certificate expiry, disk/inodes, chain/indexer sync, failed backups, and failed webhooks.

See [operator-guide.md](operator-guide.md) for the required recovery design; the commands are currently disabled.

## Consumer integrations

- [ ] Each consumer and environment has a separate store, least-privilege API key, and webhook secret.
- [ ] Checkout links use only the public HTTPS origin.
- [ ] Invoice creation/read permissions are tested and cross-store access is denied.
- [ ] Exact raw-body webhook signature verification, request bounds, expected-store validation, replay idempotency, retry, and missed-webhook reconciliation pass.
- [ ] Credential rotation affects only the selected integration.
- [ ] Any reference-specific gates, such as [Arkfile's](reference-integrations/arkfile.md), pass.

## Custody and per-method approval

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

## Privacy

- [ ] Deployment-wide logging and retention policy is documented and tested on success and failure paths.
- [ ] Diagnostics redact credentials, wallet material, connection strings, sensitive URLs, and consumer data.
- [ ] Integrators minimize invoice metadata and meet their own legal/retention obligations.
- [ ] Arkfile deployments prove that Caddy, BTCPay, journald, and AlmaPay diagnostics do not retain client IP addresses.

## Sign-off

Production is ready only when every applicable box is checked and a human operator records the evidence. Presence of AlmaPay code, a running container, or a selectable profile is not authorization to accept payments.

For boundaries and rationale, read [design.md](design.md). For normative acceptance requirements, read [alma-pay-spec.md](alma-pay-spec.md).
