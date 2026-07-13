# AlmaPay implementation specification

## Purpose

This document is the implementation contract for a new `AlmaPay` repository. AlmaPay is a reusable, application-agnostic deployment and operations toolkit that builds, deploys, verifies, updates, backs up, and restores a self-hosted BTCPay Server installation on AlmaLinux 10+ using rootless Podman. It may serve multiple independent consumer applications through separate BTCPay stores, credentials, and webhooks.

AlmaPay is not an application billing engine, account ledger, payment gateway abstraction, client SDK, or multi-tenant SaaS service. It operates BTCPay infrastructure and provides integration guidance without embedding consumer-specific business logic. Multiple applications on one deployment are assumed to be under one trusted operator; separate BTCPay stores do not isolate mutually distrustful server administrators or custody domains. Arkfile is the first reference consumer used to prove the deployment and integration contract, but Arkfile is neither embedded in nor required by the AlmaPay runtime.

The first production target is an already-provisioned VPS. Repository implementation and local or disposable-VM testing do not authorize access to that VPS. Agents must not attempt to access or modify the VPS directly. Agents must instead build automation, tooling, scripts, and instructions that a human administrator or developer can use.

The initial supported deployment profile is deliberately narrow: mainnet on one AlmaLinux 10+ x86-64-v3 host, host-installed Caddy, a local pruned Bitcoin node, and local pruned Monero. The first implementation must ship the reviewed Monero, Boltz nodeless Lightning, and Stripe Payments profiles, but every payment method remains disabled until its own production-readiness gate passes. Other architectures, networks, RHEL-family distributions, alternate reverse proxies, external RPC providers, split-host chain nodes, and other deployment modes are future profiles. They must not be described as supported until they have explicit implementation, security validation, and integration tests.

The companion operator runbook is [`alma-pay-server.md`](alma-pay-server.md).

## Required baseline

The implementation must assume:

- AlmaLinux 10.0 or later. AlmaLinux 10.2 is the initial tested reference.
- x86-64-v3 on x86_64. The first reference host is a KVM VPS; architecture and CPU capabilities must be checked on every install and restore.
- BTCPay Server 2.4.0 or later.
- Bitcoin Core 30.0 or later.
- Rootless Podman with cgroup v2.
- An explicitly selected and pinned external Compose provider.
- SELinux enforcing in production.
- Host-installed Caddy for public TLS.
- PostgreSQL and NBXplorer inside the payment stack.
- Mainnet as the only supported production network. Regtest and mocks are test fixtures, not deployment profiles.
- A pruned local Bitcoin node.
- A pruned local Monero node.
- Shipped, independently gated profiles for Boltz nodeless Lightning and Stripe Payments.
- Greenfield API and signed HTTPS webhooks for application integration.

Version floors are not permission to float dependencies. Every production release must pin exact commits, image digests, package versions, and plugin releases in `upstream.lock`.

The July 13, 2026 research baseline uses the [AlmaLinux 10.2 release notes](https://wiki.almalinux.org/release-notes/10.2), [BTCPay Server 2.4.0 release notes](https://github.com/btcpayserver/btcpayserver/releases/tag/v2.4.0), [Bitcoin Core 30.0 release notes](https://bitcoincore.org/en/releases/30.0/), [Podman Compose documentation](https://docs.podman.io/en/latest/markdown/podman-compose.1.html), the [BTCPay Plugin Builder API](https://plugin-builder.btcpayserver.org/docs/), and upstream source at the candidate commits recorded below. Registry and repository observations are candidate pins, not production approval. The implementation agent must revalidate availability and compatibility, inspect source changes, and pass the clean-VM and payment-profile tests before publishing the first release lockfile.

## Mission and success criteria

AlmaPay must turn a clean, supported AlmaLinux host into a reproducible and operable payment service while preserving these invariants:

- Podman and the container lifecycle run under the dedicated unprivileged `almapay` host account; container UIDs map through its rootless user namespace and never become host root.
- No AlmaPay runtime command invokes Podman as root.
- BTCPay is published only on the fixed initial-profile listener `127.0.0.1:8080`.
- Only host Caddy binds public HTTP and HTTPS ports.
- Database, chain RPC, wallet RPC, and NBXplorer ports are never publicly published.
- The selected BTCPay process reports version 2.4.0 or later.
- The selected Bitcoin process reports version 30.0 or later.
- Generated Compose is inspected before use rather than trusted implicitly.
- Updates are lockfile-driven and start with a verified backup.
- Secrets are never committed, printed, placed in process arguments, or exposed by diagnostics.
- AlmaPay automation never enables a mainnet payment method automatically. Each method remains disabled until synchronization, custody, backup, restore, plugin, and operator-run payment checks for that method pass.

Repository implementation is complete only when a clean AlmaLinux 10.2 VM can be installed repeatedly, survive reboot, pass security checks, complete a test payment flow, and restore successfully from backup.

## Scope boundary

AlmaPay owns:

- Host prerequisite inspection.
- Optional idempotent host bootstrap.
- The `almapay` service identity and subordinate UID/GID setup.
- Rootless Podman and Compose-provider execution.
- Acquisition and verification of pinned upstream sources.
- Generation and security inspection of BTCPay Compose.
- BTCPay, PostgreSQL, NBXplorer, Bitcoin, Monero, and supporting containers.
- AlmaPay-owned Caddy source rendering, validation, and root installation guidance.
- User systemd persistence.
- Firewalld validation and safe initial-profile configuration.
- Version, health, synchronization, exposure, and integration diagnostics.
- Lockfile-driven updates.
- Backup and restoration.
- Operator runbooks for stores, wallets, plugins, API keys, and webhooks.
- Generic integration documentation for any consumer application.
- Documentation and testing of Arkfile as the first reference integration.

AlmaPay does not own:

- Consumer applications' user accounts, authentication, credit balances, business records, fulfillment, or ledger entries.
- Consumer-specific metering, rates, free baselines, access gates, negative-balance policy, or recurring subscriptions.
- Arkfile Subscription Bridge deployment.
- Direct Stripe, Boltz, Bitcoin, or Monero integration inside a consumer application.
- Automated wallet seed or spend-key generation or import.
- Custody-policy decisions.
- Automated refunds, disputes, or chargebacks.

The Stripe Payments plugin provides card methods on BTCPay invoice checkout. It is not a generic recurring-subscription system and does not replace Arkfile Subscription Bridge.

## Consumer application responsibilities

AlmaPay hosts and operates the payment processor. Each consumer application remains responsible for its invoice-to-business-record mapping, user or customer state, balances, fulfillment, retries, and webhook idempotency. AlmaPay must not become the source of truth for a consumer application's business state.

Consumer applications may implement payments and fulfillment differently. AlmaPay provides BTCPay hosting, customer-facing checkout, store-scoped Greenfield credentials, webhook delivery, operational verification, and integration guidance. It does not prescribe an application ledger or settlement model.

## Arkfile reference payment model

Arkfile remains the source of truth for invoice ownership, account balances, PAYG metering, and credit-ledger idempotency. Arkfile stores USD using `100,000,000` microcents per USD. A successful one-time top-up credits the local `user_credits` balance and inserts a positive `credit_transactions` entry. Storage usage is metered separately: hourly ticks add microcents to `storage_usage_accumulator`, and the daily sweep subtracts accumulated usage from the user's balance and inserts a negative usage transaction. Upload policy may block a user whose balance has crossed the configured negative limit.

AlmaPay must not reproduce, reinterpret, or modify the Arkfile ledger. It must only provide reliable BTCPay invoice creation, status lookup, checkout, and webhook delivery. Arkfile's PAYG negative-balance USD parser has been corrected to use the canonical `100,000,000` microcents-per-USD conversion and regression-tested, including the end-to-end shell and Playwright suites. AlmaPay must never compensate for an Arkfile conversion bug by changing payment amounts or metadata. Arkfile must consistently use its canonical monetary unit.

## Privacy boundary

AlmaPay must not require, add, infer, or enrich consumer PII. Integrators should minimize invoice metadata and define their own privacy, retention, and legal policies. Some consumer applications may legitimately require customer contact or invoicing data; that decision belongs to the integrator, not AlmaPay.

Access-log and network-identifier policy applies to the shared deployment, not an individual store. Consumer applications with incompatible logging or retention requirements should use separate AlmaPay deployments. The Arkfile production profile must verify that Caddy, BTCPay, and AlmaPay diagnostics do not retain client IP addresses; inability to prove that behavior is a production blocker for Arkfile.

The Arkfile reference profile is stricter. Arkfile may send only:

- Amount.
- Currency.
- An opaque local invoice identifier.
- Checkout redirect information.

Arkfile must not send usernames, email addresses, filenames, object keys, storage usage, account balances, subscription state, or other user PII in BTCPay metadata. AlmaPay logs and diagnostics must not introduce IP-address or user-identity logging on Arkfile's behalf.

## Operator-supplied configuration

Provide a non-secret configuration file based on:

```ini
ALMAPAY_DOMAIN=pay.example.com
ALMAPAY_NETWORK=mainnet
ALMAPAY_LISTEN=127.0.0.1:8080

ALMAPAY_BITCOIN_MODE=local-pruned
ALMAPAY_MONERO_MODE=local-pruned
ALMAPAY_LIGHTNING_MODE=boltz-nodeless
ALMAPAY_CARD_MODE=stripe

ALMAPAY_ACME_EMAIL=operator@example.com
ALMAPAY_ACME_MODE=http-01

ALMAPAY_BACKUP_TARGET=
ALMAPAY_BACKUP_RETENTION_DAYS=30
ALMAPAY_INCLUDE_CHAIN_DATA_IN_BACKUP=false
```

At minimum, validate these values:

- `ALMAPAY_NETWORK`: must be `mainnet` in the initial supported deployment profile. Regtest may be injected only by test harnesses and must never produce a production-ready deployment.
- `ALMAPAY_BITCOIN_MODE`: initially `local-pruned`; other modes require separately tested profiles.
- `ALMAPAY_MONERO_MODE`: `disabled` or `local-pruned`. `local-full` requires a separately tested future profile.
- `ALMAPAY_LIGHTNING_MODE`: `disabled` or `boltz-nodeless`.
- `ALMAPAY_CARD_MODE`: `disabled` or `stripe`.
- `ALMAPAY_LISTEN`: must equal `127.0.0.1:8080` in the initial profile.
- Domain and listen values: syntactically valid and mutually consistent.
- Retention: a positive integer when backups are enabled.

Unknown modes or contradictory settings must fail closed.

The initial data root is fixed at `/var/lib/almapay`. It is the `almapay` account home, Compose project root, and rootless storage home. Relocating it is a future profile because path changes affect user-systemd units, SELinux labels, rootless storage, backup, and restore.

Use a separate `secrets.env`, excluded from Git and created with mode `0600`, for provider tokens and credentials. Scripts must disable shell tracing before reading secrets. Secret values must be passed through protected environment files or standard input where supported, not command-line arguments.

Root-owned host secrets, including DNS-provider credentials used by a custom Caddy build, are outside the AlmaPay application secret file and require separate operator-controlled backup and recovery.

## Repository layout

Implement approximately:

```text
AGENTS.md
README.md
LICENSE
upstream.lock
config/
  almapay.env.example
  secrets.env.example
  profiles/
    mainnet.env.example
bin/
  almapay
lib/
  common.sh
  config.sh
  host.sh
  podman.sh
  upstream.sh
  btcpay.sh
  compose.sh
  caddy.sh
  systemd.sh
  backup.sh
  restore.sh
  verify.sh
templates/
  caddy/Caddyfile
  systemd/almapay.service
  compose/
docs/
  architecture.md
  security.md
  installation.md
  integrator-guide.md
  reference-integrations/
    arkfile.md
  wallets-and-plugins.md
  operations.md
  backup-and-restore.md
  troubleshooting.md
  production-readiness.md
tests/
  unit/
  integration/
  fixtures/
```

The exact organization may improve during implementation, but responsibilities must remain separated and testable.

## Command interface

`bin/almapay` must expose:

```text
almapay doctor
almapay bootstrap-host
almapay install
almapay generate
almapay start
almapay stop
almapay restart
almapay status
almapay logs [service]
almapay verify
almapay backup
almapay restore
almapay update
almapay render-caddy
```

General command requirements:

- `doctor` is read-only and reports every unmet prerequisite.
- `bootstrap-host` performs the narrowly defined root-required setup and is idempotent.
- Runtime commands refuse UID 0.
- Commands use absolute paths and strict shell behavior.
- Commands validate configuration before side effects.
- Repeated execution must converge without destroying state.
- Destructive actions require a specific confirmation flag and identify affected data.
- Errors identify the failed invariant and remediation.
- Diagnostics redact secrets.
- Commands support noninteractive testing without weakening production confirmation gates.
- `verify --production` emits a non-secret readiness report bound to the current configuration and lockfile hashes. It does not enable payment methods; a human operator records the final per-method approval after completing custody and real-payment checks.

`almapay backup` and `almapay restore` are application-domain commands and run as `almapay`. They do not claim to provide a complete bare-host backup. Root-owned host recovery state is handled separately through ordinary host administration tooling.

## Host inspection and bootstrap

`almapay doctor` must verify:

- `/etc/os-release` identifies AlmaLinux with major version at least 10.
- The current release is in the project's tested support matrix.
- Future releases pass capability checks; version comparison alone is insufficient.
- The host reports `x86_64`, glibc reports `x86-64-v3 (supported, searched)`, and all locked images provide the selected linux/amd64 platform.
- cgroup v2 is active.
- SELinux is present and enforcing for production readiness.
- Rootless user namespaces work.
- `newuidmap` and `newgidmap` exist.
- `/etc/subuid` and `/etc/subgid` contain non-overlapping ranges for `almapay`.
- `/run/user/<uid>`, user D-Bus, and user systemd work.
- Podman works rootlessly.
- A supported Compose provider is installed.
- The configured provider is exactly the expected `podman-compose` executable.
- Rootless overlay storage works on the selected filesystem.
- XFS used for `/var/lib/almapay` has `ftype=1`. If a swapfile is selected on a reflink-enabled XFS filesystem, bootstrap must use and verify a reviewed non-copy-on-write procedure rather than a naive sparse or reflinked file.
- The first intended target host has adequate CPU, RAM, explicit swap policy, disk, disk performance, and inodes.
- DNS, time synchronization, firewall state, and required outbound connectivity are suitable.
- Ports 80 and 443 are available to Caddy and port 8080 is not publicly bound.

Privileged host administration is limited to bootstrap and host-level configuration or recovery. It may:

- Install Podman, Git, curl, jq, `shadow-utils`, SELinux container policy, and required systemd/networking tools.
- Install the exact supported `podman-compose` version through a documented package source.
- Create the `almapay` group and `/sbin/nologin` user.
- Create `/var/lib/almapay` owned by `almapay:almapay` with mode `0750`.
- Allocate or validate subordinate UID/GID ranges.
- Enable linger for `almapay`.
- Install and configure Caddy when requested.
- Install and enable firewalld for the initial profile when it is absent or inactive, record the existing SSH listener before changing policy, preserve that exact SSH port, allow HTTP and HTTPS to Caddy, and keep port 8080 and all internal ports closed publicly.

Privileged host operations must never run Podman as root, inspect or copy live rootless Podman storage as a substitute for application backup, disable SELinux, lower the unprivileged-port threshold, expose port 8080, overwrite unrelated firewall policy, or alter SSH configuration without explicit operator approval.

After subordinate-ID changes, all affected containers must be stopped before running `podman system migrate` as `almapay`. This migration must never run implicitly on a live deployment.

## Rootless runtime wrapper

Every runtime command must use a safe equivalent of:

```bash
sudo -u almapay -H env \
  XDG_RUNTIME_DIR=/run/user/$(id -u almapay) \
  PODMAN_COMPOSE_PROVIDER=/usr/bin/podman-compose \
  <command>
```

Never:

- Use `sudo podman`.
- Invoke Docker.
- Mount a Podman or Docker socket.
- Enable privileged containers.
- Add broad capabilities.
- Mount host SSH keys, the host root filesystem, or arbitrary root-owned directories.
- Enable BTCPay's optional host SSH integration.

## Compose provider

Podman 5.8's `podman compose` is a wrapper around an external provider. AlmaPay must not describe it as native Compose.

The implementation must:

- Pin the tested `podman-compose` package and version.
- Set `PODMAN_COMPOSE_PROVIDER=/usr/bin/podman-compose`.
- Fail if the resolved provider is `docker-compose`.
- Record Podman and provider versions in `upstream.lock`.
- Test all generated Compose features with the exact provider.
- Refuse an unsupported provider rather than continuing with warnings.

## Upstream acquisition and lockfile

Use `btcpayserver-docker` as the generator and fragment source. Do not run `btcpay-setup.sh`.

`upstream.lock` must record:

```yaml
platform:
  distribution: almalinux
  minimum_major: 10
  tested_release: "10.2"
  architecture: x86_64
  cpu_level: x86-64-v3
  virtualization: kvm

runtime:
  podman_nevra: "<tested-exact-nevra>"
  compose_provider: podman-compose
  compose_provider_nevra: "podman-compose-1.5.0-1.el10_1"
  caddy_nevra: "caddy-2.10.2-9.el10_2"
  package_repositories:
    - id: "<repository-id>"
      signing_key_fingerprint: "<verified-fingerprint>"
      repomd_sha256: "<verified-repository-metadata-sha256>"
  package_artifacts:
    - nevra: "<exact-nevra>"
      source_url: "<immutable-or-archived-rpm-url>"
      sha256: "<rpm-sha256>"

btcpayserver_docker:
  commit: "a25cd38c1e068bc3412b57a359bc84f063230db1"
  generator:
    image: "localhost/almapay/docker-compose-generator@sha256:<locally-built-image-digest>"
    dockerfile_sha256: "<pinned-source-dockerfile-sha256>"
    builder_base_image: "mcr.microsoft.com/dotnet/sdk:10.0.201-noble@sha256:<digest>"
    runtime_base_image: "mcr.microsoft.com/dotnet/runtime:10.0.5-noble@sha256:<digest>"

images:
  btcpayserver:
    reference: "btcpayserver/btcpayserver:2.4.0"
    manifest_digest: "sha256:8861fc45db4992889950771075a71a82e78e5ca382400a23d7989bd1ef618593"
    linux_amd64_digest: "sha256:d9ae1b5a4bb921636ffae88b2a6f3cf93376f532afe6fb9305d6e3a76ec71edf"
  bitcoin_core:
    reference: "btcpayserver/bitcoin:31.0"
    manifest_digest: "sha256:a753d6fe3d8051ff03015ec77f068d9698b85b9abe8864a783ed22a572c9dcce"
    linux_amd64_digest: "sha256:cc070dffde3073154b508e95ae64b39f433b41874dd8f2cd49c0d1b4d16a15ff"
  nbxplorer:
    reference: "nicolasdorier/nbxplorer:2.6.8"
    manifest_digest: "sha256:1ae5e23a330659baa9ea8731b93ae0b675aaf9e7add17283c910aa13e8cbaf60"
    linux_amd64_digest: "sha256:a96d59772471628a00d2ee779c69414591e04d202923a008a405a02dd7893569"
  postgres:
    reference: "btcpayserver/postgres:18.4"
    manifest_digest: "sha256:ee11b4d9b3473a93cf608b37c2090749e55a5354f911b8d18772f962fcfb0bb5"
    linux_amd64_digest: "sha256:fea63bcc6230c468b4ab8d8f89b853918ac0eb7844bd966323639c4602314d6c"
  monero:
    reference: "btcpayserver/monero:0.18.4.3"
    manifest_digest: "sha256:210af42cff4311e7fc6040116363ea3dc0d0d3d64c938969679a5a00fc752936"
    linux_amd64_digest: "sha256:3f8925d3f8fb81c37b2537a3099e40c29653b80b88a5ab45f8c6dfa2f9997740"

minimum_versions:
  btcpayserver: "2.4.0"
  bitcoin_core: "30.0"

plugins:
  monero:
    version: "1.3.0.0"
    source: "https://github.com/btcpay-monero/btcpayserver-monero-plugin"
    commit: "f71b1a5a2d8bfedd901f84b7805d13021b6ceedd"
    builder_build_id: 11
    builder_build_hash: "5dff2bd1adc2f0eeb11857e289cdf335f53af3fbf7701ec50658ce2673b660c0"
    minimum_btcpayserver: "2.3.7"
  boltz:
    version: "2.4.2"
    source: "https://github.com/BoltzExchange/boltz-btcpay-plugin"
    commit: "fce1dfb29830f9dcbc9d51a909d04b294287179d"
    artifact_sha256: "05a0e8e91ab0a398a02cccb4f1415a28648e1280825b9a868539e1efb3974f84"
    signing_fingerprint: "8918FFBFFB49E93EF256D930542A7F22A3BD9CB0"
    minimum_btcpayserver: "2.3.7"
  stripe:
    version: "1.0.12.0"
    source: "https://github.com/Kukks/BTCPayServerPlugins"
    commit: "969a295a5f410e08f49168ccee2f97bd068d6eb5"
    builder_build_id: 12
    builder_build_hash: "233aa5c0d97cbc316e566a2172a7715d9ce94761d33d1e2e655a801dd124d3c7"
    minimum_btcpayserver: "2.3.7"
```

These values are the corroborated initial candidates observed on July 13, 2026. They must be copied into a release lockfile only after revalidation and testing; later is not automatically better. Tags provide readability, while digests provide immutable image identity. Multi-architecture tags require both the manifest-list digest and selected linux/amd64 platform digest. Package NEVRAs alone are insufficient because ordinary repositories can move or retire artifacts; retain an immutable or archived source URL, RPM checksum, repository metadata checksum, and signing-key fingerprint for every installed package.

The published `btcpayserver/docker-compose-generator:latest` image observed during this research predates the candidate source commit and cannot establish source correspondence. AlmaPay must build the generator with rootless Podman from the pinned commit, replace both Dockerfile base-image tags with reviewed digests, record the resulting image digest, and use only that locally built image for generation. Production commands must never silently consume `latest`, a moving branch, an unavailable package version, tag-only runtime images, or an unverified plugin manifest.

## Compose generation

The initial generator profile is:

```ini
BTCPAY_HOST=pay.example.com
BTCPAY_PROTOCOL=https
BTCPAYGEN_CRYPTO1=btc
BTCPAYGEN_CRYPTO2=xmr
BTCPAYGEN_REVERSEPROXY=none
BTCPAYGEN_LIGHTNING=none
BTCPAYGEN_EXCLUDE_FRAGMENTS=bitcoin;opt-add-tor
BTCPAYGEN_ADDITIONAL_FRAGMENTS=bitcoincore;opt-save-storage-s
BTCPAY_IMAGE=btcpayserver/btcpayserver:2.4.0
NBITCOIN_NETWORK=mainnet
NOREVERSEPROXY_HTTP_PORT=127.0.0.1:8080
```

Both exclusions and the additional fragments are mandatory. The upstream `btc` crypto definition currently maps to `bitcoin.yml`, whose image is below Bitcoin Core 30, while the separate `bitcoincore.yml` fragment uses Core 31.0. The base BTCPay fragment also recommends `opt-add-tor`; that fragment adds `tor-gen` with a `/var/run/docker.sock` mount and is incompatible with AlmaPay's container-engine socket prohibition. Tor is not part of the initial supported profile. A future Tor profile requires a Podman-native design with no engine socket and its own security review and tests.

At the candidate upstream commit, `BTCPAYGEN_REVERSEPROXY=none` selects the upstream `btcpayserver-noreverseproxy.yml` fragment, which publishes `${NOREVERSEPROXY_HTTP_PORT:-80}:49392`. The fixed value above therefore renders the required `127.0.0.1:8080:49392` mapping without an AlmaPay-owned port overlay. AlmaPay must assert that exact rendered mapping and add an overlay only if a future pinned upstream commit no longer supplies equivalent behavior.

Generation must:

- Run as `almapay`.
- Use the pinned upstream commit and generator digest.
- Fetch and check out the pinned upstream commit explicitly; a clone of the current default branch is not a pin.
- Produce deterministic output from committed configuration and lockfile inputs.
- Canonicalize and hash the rendered semantic Compose model; byte ordering emitted by upstream collections is not a sufficient determinism guarantee.
- Preserve the previous generated output before replacement.
- Produce a human-readable diff.
- Never edit the upstream checkout in place to conceal required overrides.
- Store AlmaPay-owned overlays or post-generation validation rules in the AlmaPay repository.
- Materialize every production service image as the exact locked digest. A digest recorded only in `upstream.lock` while the runnable Compose file still uses a tag is not a pin.
- Discard the upstream-generated `pull-images.sh` and `save-images.sh`, which invoke Docker and include Docker Compose helper images. If equivalent helpers are needed, generate Podman-native scripts directly from the locked image set.
- Work with SELinux enforcing. Bind mounts used by the generator must have reviewed read/write access and appropriate private relabeling such as `:Z`; weakening SELinux is not an alternative.

## Rendered Compose security validation

Installation and update must inspect the fully rendered Compose model and fail if:

- BTCPay is below 2.4.0.
- Bitcoin Core is below 30.0.
- The default Bitcoin 29.x image remains.
- Any service image is tag-only, differs from its lockfile digest, or is not present in the lockfile.
- BTCPay is published on `0.0.0.0`, `[::]`, or any non-loopback address.
- BTCPay's host mapping is not exactly `127.0.0.1:8080:49392`.
- PostgreSQL, NBXplorer, Bitcoin RPC, Monero RPC, or wallet RPC is host-published.
- An unexpected host port exists.
- A container is privileged.
- Dangerous host bind mounts exist.
- A container gains unnecessary capabilities.
- The Podman socket or host SSH material is mounted.
- A usable BTCPay host-SSH credential, key path, authorized-key mount, or other host SSH integration remains configured.
- `BITCOIN_EXTRA_ARGS` lost required RPC, peer, memory, or pruning settings.
- The selected Monero mode does not match the rendered daemon arguments.
- The Compose file depends on Docker-only behavior unsupported by the pinned provider.

Fragment merging can alter the multiline `BITCOIN_EXTRA_ARGS` value. At the candidate commit, `bitcoincore.yml` recommends `opt-mempoolfullrbf`, while `opt-save-storage-s.yml` adds `prune=50000`; the generator concatenates colliding scalar values. Tests must prove that the final configuration contains the required base RPC, peer, and memory settings, `prune=50000`, and `mempoolfullrbf=1`, with no malformed delimiters or duplicate contradictory setting. Do not assume that listing multiple fragments merges scalar environment values correctly.

## Bitcoin Core 30+ requirements

The deployment must use descriptor-based workflows:

- Set `CREATE_WALLET=false` in the Core container.
- Let BTCPay and NBXplorer track descriptors or xpubs.
- Do not create or load legacy BDB wallets.
- Do not use removed RPCs such as `importprivkey`, `importaddress`, `importmulti`, `importwallet`, `dumpprivkey`, or `dumpwallet`.
- Treat migration of a pre-existing BDB wallet with `migratewallet` as a separate manual procedure outside fresh installation.
- Do not rely on deprecated static fee configuration.
- Keep Bitcoin RPC authentication and cookie sharing internal.
- Never publish Bitcoin RPC.
- Do not publish Bitcoin P2P by default unless an explicit, reviewed inbound-peer profile is added.

Runtime verification must query the daemon. Bitcoin Core's numeric reported version must be at least `300000`. The image tag alone is insufficient.

If all secondary indexes must be rebuilt, operations must use and plan for a full `-reindex`. `-reindex-chainstate` alone does not rebuild indexes such as `txindex`.

## NBXplorer and PostgreSQL

NBXplorer must use a release tested with the pinned BTCPay and Bitcoin Core versions. The initial upstream candidate is 2.6.8.

The candidate upstream PostgreSQL fragment sets `POSTGRES_HOST_AUTH_METHOD=trust` and uses passwordless BTCPay and NBXplorer connection strings. AlmaPay must not silently inherit that choice. The initial production implementation must supply and test an AlmaPay-owned authenticated PostgreSQL configuration, prefer SCRAM authentication, keep password placeholders rather than secret values in generated artifacts, and load the actual credential only from protected secret configuration. If authenticated operation cannot be made compatible with the pinned stack, that is a documented production blocker requiring an explicit specification decision; falling back to `trust` is not an implementation shortcut.

Verification must confirm:

- PostgreSQL accepts internal connections.
- BTCPay database migrations completed.
- NBXplorer can authenticate to Bitcoin Core.
- NBXplorer reports the expected network.
- NBXplorer is synchronized before Bitcoin payment methods are enabled.
- No PostgreSQL or NBXplorer host port is published.

## Monero

The first implementation must ship the mainnet Monero profile. The current upstream fragment uses `--prune-blockchain`, so the supported mode is `local-pruned`, not full. `NBITCOIN_NETWORK` does not select the Monero network; the stock fragment is mainnet-specific. AlmaPay must not claim Monero testnet or stagenet support without a separate fragment and test profile.

Requirements:

- `disabled` omits Monero services and plugin setup.
- `local-pruned` uses the reviewed upstream pruning behavior.
- `local-full`, testnet, and stagenet require separately tested future overrides.
- Daemon and wallet RPC remain internal.
- Unauthenticated RPC is never public.
- Spend keys are never requested, uploaded, stored, logged, or backed up by AlmaPay.
- View keys and wallet files are treated as confidential.

Monero wallet configuration is server-wide. Stores may use separate account indexes for bookkeeping, but they share wallet custody and view material. Test and production stores requiring true treasury separation need separate deployments.

## BTCPay Server 2.4+

Pin an exact supported 2.4.x release, beginning with 2.4.0. Do not float on `2.4` or `latest`.

Version-specific requirements:

- BTCPay 2.4 runs on .NET 10 internally.
- LNBank, LNDHub, and Lightning Charge are unsupported and must not be configured.
- The deprecated Shopify Scripts integration must not be used.
- Plugins must be refreshed and tested against the selected BTCPay release.
- More granular wallet permissions should be used for operator and integration roles.
- The Greenfield invoice and webhook contract used by Arkfile must be regression-tested.

Runtime verification must query BTCPay and require semantic version 2.4.0 or later.

## Plugins

Supported optional plugins are:

- Monero, when XMR is selected.
- Boltz in nodeless mode for Lightning.
- Stripe Payments for card methods.

All three profiles are first-pass deliverables even though operators may leave any method disabled. Shipping a profile means pinning and testing its exact release, configuration, restart behavior, custody material, backup and restore, diagnostics, and representative payment flow. Presence in the repository never authorizes automatic enablement.

Before installation:

- Query the live authenticated plugin manifest or reviewed upstream source.
- Confirm the exact plugin release declares compatibility with the pinned BTCPay version.
- Record the release, source commit, artifact or builder hash, Builder build ID where applicable, declared BTCPay range, and signing fingerprint where available in `upstream.lock`.
- Verify package integrity where the ecosystem provides signatures or hashes.
- Prefer the independently signed Boltz GitHub release artifact over a separately rebuilt unsigned directory artifact, and verify its checksum manifest against the locked Boltz signing fingerprint.
- Treat the unsigned Monero and Stripe Builder artifacts as a provenance gap: pin their source commits and Builder metadata, review the source diff, retain the exact artifact hash, and require integration tests before enablement.
- Test installation, restart, enablement, and a representative payment.

Plugin installation may be automated only through a stable and tested interface. Otherwise provide precise UI instructions and verify the resulting version and enabled state afterward.

Boltz requirements:

- Use nodeless mode unless a separately designed local Lightning profile is added.
- Document the Liquid wallet, fee, swap, and maximum-balance decisions.
- Do not claim support for zero-amount invoices.

Stripe requirements:

- Keep test and live credentials separate.
- Configure credentials per store.
- Do not expose credentials to Arkfile or any other app that uses AlmaPay to accept payments.
- Do not describe Stripe checkout as recurring Subscription Bridge billing.

## Caddy and networking

Caddy runs on the host outside the Compose project and proxies:

```caddy
pay.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

Requirements:

- `BTCPAYGEN_REVERSEPROXY=none`.
- `BTCPAY_PROTOCOL=https`.
- `NOREVERSEPROXY_HTTP_PORT=127.0.0.1:8080`.
- Public ports 80 and 443 terminate at Caddy.
- Ordinary HTTP-01 ACME is the default.
- DNS-01 is an explicit profile requiring a provider-specific Caddy build and protected token.
- Caddy configuration is validated before reload.
- Firewall changes preserve the real SSH port and do not risk lockout.
- Port 8080 and all internal service ports remain unavailable externally.
- The Arkfile profile omits Caddy's `log` directive so HTTP access logging remains disabled by default, and verifies that neither Caddy, BTCPay, journald, nor AlmaPay diagnostics retain client IP addresses.
- Because Caddy adds `X-Forwarded-For`, `X-Forwarded-Proto`, and `X-Forwarded-Host` by default, implementation must test the exact pinned Caddy and BTCPay behavior before changing headers. Do not strip forwarding headers reflexively if BTCPay needs them for correct origin handling or security controls; apply a reviewed header policy only when the retention tests require it.
- Privacy tests cover successful requests, rejected requests, upstream failures, Caddy system logs, BTCPay container logs, journald, and generated AlmaPay diagnostics. Assumed privacy or checking only ordinary successful requests is insufficient.

Consumer applications must use the public BTCPay origin for customer-facing checkout links. The loopback origin `127.0.0.1:8080` is an internal Caddy upstream and must never appear in checkout links or integrator configuration. Arkfile additionally requires the public origin for its Content Security Policy.

## systemd

Install one user service owned by `almapay` that:

- Depends on `network-online.target`.
- Uses absolute, pinned Compose and environment paths.
- Sets `XDG_RUNTIME_DIR`.
- Sets `PODMAN_COMPOSE_PROVIDER=/usr/bin/podman-compose`.
- Starts with `podman compose up -d --remove-orphans`.
- Stops with `podman compose down`.
- Has an adequate startup timeout.
- Is enabled under the lingering user.
- Is managed only with `systemctl --user`.

RHEL 10 recommends Quadlet, but Quadlet does not directly consume the authoritative upstream Compose project. The initial implementation therefore uses a compose-level user service intentionally. Do not use deprecated `podman generate systemd`. A future Quadlet backend must be separately implemented and prove equivalent handling of volumes, dependencies, health checks, networking, environment interpolation, restart behavior, and updates.

## Generic consumer integration contract

AlmaPay must support zero, one, or many consumer applications without a global application URL or shared application credential. Integration configuration is scoped to a BTCPay store and consumer environment.

The generic integrator guide must explain how to:

- Create or select a dedicated BTCPay store for each consumer application and environment.
- Issue a least-privilege, store-scoped Greenfield API key.
- Register one or more HTTPS webhook endpoints chosen by the consumer.
- Store API keys and webhook secrets outside the AlmaPay and consumer source repositories.
- Create invoices, direct customers to the public checkout origin, retrieve status, and verify signed webhooks.
- Design application-level idempotency, retries, reconciliation, and missed-webhook recovery.
- Rotate or revoke one consumer's credentials without affecting another.
- Test an integration without enabling mainnet payment methods.

AlmaPay must not define a universal invoice metadata schema, payable status policy, fulfillment rule, or webhook route for all consumers. Those are integration-profile decisions built on BTCPay's Greenfield and webhook APIs.

Each application and environment should use a separate BTCPay store, API key, and webhook secret. Credentials for one store must not read or mutate another store. Multiple applications may share the AlmaPay deployment, but they do not share application databases, ledgers, authentication, or business state. This is credential and business-state separation under one trusted server operator, not a security boundary against that operator or other BTCPay administrators. Server-wide plugins, logging policy, and some custody material remain shared. Monero is a documented custody exception because stores on one BTCPay instance still share server-level wallet view material. Applications requiring independent administration, custody, or conflicting host policies need separate deployments.

## Reference integration: Arkfile

Arkfile creates a BTCPay invoice with:

```text
POST /api/v1/stores/{storeID}/invoices
Authorization: token <restricted Greenfield API key>
```

Request semantics:

- Currency is `USD`.
- Amount has two decimal places.
- `metadata.invoice_id` contains Arkfile's opaque local invoice ID and no PII.
- `checkout.speedPolicy` is `LowMediumSpeed`, requiring two confirmations for on-chain settlement. `HighSpeed` is prohibited for Arkfile production top-ups.
- `checkout.expirationMinutes` is `60`.
- Redirect URL points back to Arkfile.

The expected successful response is HTTP `201` containing provider `id` and `checkoutLink`.

Arkfile polls:

```text
GET /api/v1/stores/{storeID}/invoices/{invoiceID}
```

A remote `Settled` status is payable. Polling and administrative synchronization provide recovery when a webhook is missed.

BTCPay sends webhooks to:

```text
https://app.example.com/api/webhooks/btcpay
```

The signature header is:

```text
BTCPay-Sig: sha256=<hex HMAC-SHA256>
```

Arkfile treats the Greenfield `InvoiceSettled` event as the authoritative settlement event. It must not depend on the legacy BitPay-style `InvoiceCompleted` event. It matches `metadata.invoice_id`, with provider `invoiceId` as fallback, and validates that both identifiers bind to the same local record when both are present. Arkfile performs the final local invoice transition and credit-ledger insertion transactionally. Replayed deliveries must not add credit again.

The Arkfile runtime key should have only invoice creation and invoice-read permissions. Provisioning operations that manage webhooks must use a separate operator or short-lived key.

Before the reference integration may pass production acceptance, Arkfile itself must:

- Use the canonical `100,000,000` microcents-per-USD conversion for PAYG limits, invoice records, and ledger entries.
- Reject top-up precision beyond two decimal places and construct the BTCPay amount without floating-point rounding or truncation.
- Require a normalized public HTTPS BTCPay origin in production and reject loopback, credential-bearing, query-bearing, fragment-bearing, or unexpected-path URLs.
- Persist a recoverable local invoice association around remote invoice creation so a database failure or early webhook cannot create an unrecoverable paid invoice.
- Bound webhook request bodies, verify the exact raw-body signature, validate the configured store, and reject conflicting local and provider invoice identifiers.
- Reconcile remotely settled pending invoices rather than only repairing local invoices already marked paid.
- Keep usernames, balances, checkout URLs, credentials, and raw webhook payloads out of operational logs.
- Prove concurrent and replayed webhooks, polling, and reconciliation can insert at most one payment credit.

The integration runbook must produce:

```ini
ARKFILE_PAYMENTS_ENABLED=true
ARKFILE_BTCPAY_SERVER_URL=https://pay.example.com
ARKFILE_BTCPAY_STORE_ID=<store-id>
ARKFILE_BTCPAY_API_KEY=<restricted-api-key>
ARKFILE_BTCPAY_WEBHOOK_SECRET=<webhook-secret>
ARKFILE_MIN_TOP_UP_USD=0.50
ARKFILE_MAX_TOP_UP_USD=1000.00
```

AlmaPay must never write these values into the Arkfile repository or alter Arkfile automatically. It provides the values securely to the operator.

## Store and custody runbook

Document manual operator decisions for:

- Initial BTCPay administrator registration.
- Passkeys, MFA, and recovery.
- Separate stores for each consumer application and environment.
- Separate API keys and webhook secrets per store, with no cross-store access.
- Bitcoin hot-wallet versus watch-only/xpub policy.
- Descriptor backup and recovery.
- Monero view-only wallet import without spend keys.
- Monero account-index allocation.
- Boltz Liquid custody, limits, fees, and swaps.
- Stripe test and live credentials.
- Enabling methods only after synchronization.
- Sending and verifying a test webhook.

Do not pretend these custody choices are safely automatable.

## Update workflow

`almapay update` must:

1. Validate the requested new lockfile.
2. Run current-state verification.
3. Create and verify a pre-update backup.
4. Fetch the requested pinned upstream revision.
5. Pull requested image digests.
6. Regenerate Compose.
7. Display meaningful source, image, fragment, port, mount, and environment changes.
8. Run all rendered-Compose security checks.
9. Stop and request confirmation for material or breaking changes.
10. Restart through user systemd.
11. Run database, runtime-version, exposure, synchronization, plugin, TLS, and API verification.
12. Retain the previous lockfile, generated configuration, and backup manifest.

Do not promise binary rollback after a BTCPay database migration. The safe rollback path is restoration of the complete pre-update deployment and database backup.

## Backup

Backup is divided into two recovery domains.

### AlmaPay application backup

`almapay backup` runs as `almapay` and must include:

- A consistent PostgreSQL backup.
- BTCPay data and plugin state.
- Bitcoin descriptor or wallet material where applicable.
- Monero wallet and view-only material.
- Boltz Liquid wallet material where applicable.
- Runtime configuration and protected secrets.
- Generated Compose.
- `upstream.lock`.
- User systemd unit.
- The non-secret AlmaPay-owned Caddy source template.
- A signed or authenticated manifest containing versions, checksums, timestamps, and included components.

Application backup must use logical database exports and service-aware or Podman-aware data exports. It must not require root to copy live rootless Podman storage, overlay storage, or inconsistent live volume contents.

Chain data is reconstructible and may be excluded by default. Inclusion must be configurable and capacity-checked.

Backups must produce a verified encrypted artifact suitable for an off-host destination. Local-only retention is not sufficient for production readiness. The initial documented off-host procedure may be an interactive upload through `arkfile-client` to a separate Arkfile host and storage failure domain, but Arkfile must not be the only retained copy. AlmaPay must not automate Arkfile credentials until the client provides reviewed noninteractive secret input that avoids process arguments, environment variables, logs, and shell tracing. Backup logs must not disclose secret material.

`almapay backup` succeeds locally only after:

- The database dump passes an integrity check.
- All manifest entries are checksummed.
- The encrypted archive can be opened with the configured recovery method.

Production backup readiness additionally requires an operator-confirmed durable off-host copy, a recorded artifact checksum and destination reference, independent custody of AlmaPay decryption material and Arkfile recovery material, and a successful clean-host restore exercise. A manual transfer is an explicit operator gate, not a claim of automated off-host delivery.

### Root-owned host recovery backup

Ordinary root-owned host backup tooling, outside `almapay backup`, must preserve the minimal host state needed to reconstruct the deployment:

- The active Caddy configuration and relevant systemd overrides.
- Root-owned Caddy or ACME DNS-provider credentials, when applicable.
- The `almapay` UID and its specific `/etc/subuid` and `/etc/subgid` allocations.
- Linger state.
- Relevant firewall configuration.
- AlmaPay-specific SELinux policy or file-context customization.
- Installed package and version inventory.
- A host manifest that references the matching AlmaPay application-backup identifier and checksums.

The host recovery bundle must not indiscriminately include SSH host or operator keys, unrelated `/etc` state, live Podman storage, or reconstructible ACME certificates. Existing organization-wide host backup policy may be broader, but AlmaPay must document its own minimum recovery set.

A root-owned scheduler may coordinate the two domains by invoking `almapay backup` through `sudo -u almapay`, waiting for its verified encrypted artifact, and then creating the host recovery bundle. Coordination does not authorize rootful Podman. The two artifacts may use separate access controls and encryption keys, but their manifests must identify the matching recovery set.

## Restore

Host recovery proceeds in this order:

1. Rebuild or restore the supported host.
2. Recreate the `almapay` identity and the recorded non-overlapping subordinate-ID ranges.
3. Install pinned host packages and restore the required root-owned host configuration without yet reopening production traffic.
4. Run `almapay restore` as `almapay`.
5. Verify the restored application on loopback, validate or reinstall the active root-owned Caddy configuration from the reviewed AlmaPay source template or host recovery bundle, and then reopen public traffic.
6. Run the complete public and internal verification suite.

`almapay restore` must:

- Target an empty deployment unless explicit destructive approval is given.
- Validate the backup manifest and checksums.
- Confirm required decryption material is available.
- Confirm platform and version compatibility.
- Restore database and application/plugin data in a documented order.
- Restore protected configuration with correct ownership and mode.
- Regenerate deployment artifacts from the recorded lockfile where safer than trusting obsolete generated output.
- Start through user systemd.
- Run the complete verification suite.
- Require a non-production restore exercise before production sign-off.
- Refuse UID 0 and never invoke Podman through a privileged host context.

## Verification

`almapay verify` must check:

- AlmaLinux support and runtime capabilities.
- SELinux state.
- Rootless Podman identity and storage.
- Compose provider identity and version.
- User systemd and linger.
- DNS resolution.
- Public TLS validity and hostname.
- Caddy-to-BTCPay routing.
- Loopback-only port 8080.
- Absence of public internal ports.
- Required containers and restart policies.
- PostgreSQL readiness.
- BTCPay version at least 2.4.0.
- Bitcoin Core numeric version at least 300000.
- NBXplorer connectivity and synchronization.
- Bitcoin and Monero synchronization status.
- Disk-space and inode thresholds.
- Plugin versions and enabled state.
- Store existence.
- Restricted Greenfield key invoice creation and read access.
- Webhook HTTPS reachability.
- Application-backup recency and last verification result.
- Matching host-recovery manifest recency and its reference to the application backup.

Checks must distinguish not-ready synchronization from failure. Secret values must be redacted.

## Logging and diagnostics

Diagnostics may include component names, versions, health, sync progress, port bindings, storage capacity, and sanitized errors. They must redact:

- API keys.
- Webhook secrets.
- Stripe credentials.
- ACME DNS tokens.
- Wallet seeds, spend keys, view keys, descriptors, and connection strings.
- Database passwords.
- Signed checkout or administrative URLs containing sensitive tokens.

Do not enable verbose shell tracing in production operations.

## Testing

Repository tests must include:

- Shell formatting and static analysis.
- Unit tests with mocked system commands.
- Configuration validation for every supported and rejected mode.
- Idempotency tests.
- Tests proving runtime commands refuse root.
- Tests proving no command invokes Docker.
- Tests proving the selected Compose provider is pinned.
- Tests proving package artifacts and repository metadata match the lockfile.
- Tests for subordinate-ID and user-systemd validation.
- Rendered-Compose security tests.
- Tests proving every runtime image resolves to the locked manifest and linux/amd64 digest and no tag-only image remains.
- Tests proving BTCPay binds only to loopback.
- Tests proving the no-reverse-proxy fragment renders exactly `127.0.0.1:8080:49392`.
- Tests proving no internal service port is published.
- Tests proving the default Bitcoin fragment is excluded.
- Tests proving the incompatible `opt-add-tor` fragment, `tor-gen`, and every container-engine socket mount are absent.
- Tests proving Bitcoin Core is version 30+.
- Tests proving required `BITCOIN_EXTRA_ARGS` survive fragment composition.
- Tests proving PostgreSQL rejects unauthenticated network connections and BTCPay and NBXplorer use the protected authenticated configuration.
- Tests proving BTCPay host SSH integration has no usable credential or mount.
- Tests proving Docker-based upstream pull/save helpers are not shipped or executed.
- Caddy configuration validation.
- Caddy, BTCPay, journald, failure-path, and diagnostics tests proving the Arkfile profile does not retain client IP addresses.
- systemd unit validation.
- Application and host manifest-pairing tests.
- Paired application and host restore tests.
- AlmaLinux 10.2 VM integration testing.
- Mock-based integration tests and a BTC-only regtest fixture. Regtest is not a supported deployment profile and does not validate mainnet Monero, Boltz, or Stripe.
- Generic consumer integration tests using an application-neutral fixture.
- Arkfile reference-integration tests kept outside core AlmaPay runtime modules.

The VM integration test must install on a clean system, repeat installation without corruption, reboot, verify automatic recovery, update between two test lockfiles, and restore onto a clean VM.

## Generic integration acceptance test

Before a consumer is considered supported:

1. Create an invoice with a store-scoped Greenfield key.
2. Confirm the checkout link uses the public AlmaPay origin.
3. Settle the invoice with an enabled test payment method.
4. Verify the consumer's webhook signature handling and idempotency.
5. Replay the webhook and confirm fulfillment is not duplicated.
6. Suppress a webhook and confirm reconciliation repairs the consumer state.
7. Confirm credentials cannot access another consumer's store.
8. Confirm credential rotation affects only the selected integration.

## Reference integration acceptance test: Arkfile

Before Arkfile production use:

1. Create a small USD invoice through the same Greenfield request Arkfile uses.
2. Confirm the returned checkout URL uses the public AlmaPay hostname.
3. Pay it through an enabled test payment method.
4. Confirm BTCPay sends a correctly signed settlement webhook.
5. Confirm Arkfile marks the local invoice paid.
6. Confirm Arkfile inserts exactly one positive credit transaction.
7. Replay the webhook and confirm neither balance nor ledger changes again.
8. Exercise invoice polling or administrative synchronization.
9. Suppress one webhook and confirm operational synchronization queries the remotely settled pending invoice and repairs the local state.
10. Confirm BTCPay metadata contains only the opaque local invoice ID.

A separate Bitcoin fixture must create and settle an on-chain invoice using the running Bitcoin Core 30+ node. Before production enablement, a human operator must then perform low-value mainnet payments with their own funds for BTC, XMR, and Boltz, plus a Stripe test-mode payment followed by an explicitly authorized low-value live-mode payment. Automated agents must prepare and verify the procedure but must never initiate, custody, or refund real funds.

## Production readiness

Mainnet acceptance requires operator sign-off that:

- DNS and TLS are correct.
- Host updates and time synchronization are configured.
- SSH and firewall policy have been reviewed without lockout risk.
- SELinux remains enforcing.
- Rootless runtime and reboot persistence pass.
- BTCPay and Bitcoin version floors pass through runtime queries.
- Required chains are synchronized.
- Wallet backups and recovery instructions are secured.
- An off-host encrypted AlmaPay application backup and matching protected host recovery bundle pass.
- A clean-host restore from the paired recovery set passes.
- Separate, store-scoped production keys and webhook secrets exist for every consumer and environment.
- Plugin versions are pinned and tested.
- Test payments and webhook replay tests pass.
- The per-method readiness report is bound to the deployed configuration and lockfile, and the operator has explicitly approved each enabled mainnet method after its own custody, backup, restore, and real-payment checks.
- Monitoring covers service health, certificate expiry, disk, inodes, synchronization, failed backups, and failed webhook delivery.
- Remaining custody and provider decisions are explicitly documented.

## Documentation requirements

`AGENTS.md` in the AlmaPay repository must require future agents to:

- Use Podman only and never Docker.
- Never run Podman as root.
- Never commit, print, log, or invent secrets.
- Never connect to production without explicit authorization.
- Preserve loopback-only BTCPay publication and external Caddy.
- Validate current upstream behavior instead of copying stale commands.
- Keep AlmaPay separate from all consumer business logic, including Arkfile billing and Subscription Bridge.
- Avoid unattended wallet and mainnet custody actions.
- Avoid Git commits unless the operator explicitly requests one.
- Avoid emojis.

During planning and initial implementation, README must clearly state that the repository is not production-ready, identify the current authoritative documents, and summarize the narrow supported profile. Once clean-VM installation is implemented and tested, README must provide a short route from a clean AlmaLinux 10 host to a reachable BTCPay UI while clearly separating automated installation from manual wallet, plugin, synchronization, backup, host recovery, and mainnet-readiness work.

## Agent execution instructions

Implement the new repository in one cohesive pass. Do not leave placeholders for work that can be implemented and tested. Represent unavoidable wallet, plugin, credential, synchronization, and production-authorization decisions as explicit operator gates.

Research current upstream commits, package availability, image digests, Bitcoin Core version, NBXplorer compatibility, and plugin manifests before selecting initial pins. If Podman behavior differs from Docker Compose behavior, implement and test the Podman-compatible path.

Do not modify any consumer application from the AlmaPay repository. Arkfile reference fixtures and documentation must remain isolated from core runtime modules. Do not compensate for Arkfile ledger or currency-conversion defects in AlmaPay.

Do not apply any commands to the AlmaPay host. Instruct the admin or developer on any required deployment or configuration changes or commands that should be run as they come up.
