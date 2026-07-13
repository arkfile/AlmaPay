# HISTORICAL PLANNING DOCUMENT — DO NOT USE FOR INSTALLATION

> **This file is historical-only. Its commands are illustrative, contain obsolete assumptions and placeholders, and are not a supported clean-host procedure. Do not apply them to any production host. Use [the active operator guide](../operator-guide.md) instead.**

This archive preserves the unique planning material formerly published as `docs/alma-pay-server.md`. It described a proposed BTCPay Server 2.4+ deployment on AlmaLinux 10+ using rootless Podman, a non-login `almapay` account, fixed `127.0.0.1:8080`, and host-installed Caddy. It predated the current hardened fail-closed implementation.

## Historical threat model

The proposed payment VPS was a single-purpose host. Day-to-day containers belonged to the unprivileged `almapay` user; a separate operator account performed SSH administration. Rootless container UID 0 mapped through the service user's namespace and was not host root.

The plan rejected `btcpay-setup.sh` because that path assumed Debian-oriented package management, a privileged engine service, and often an integrated reverse proxy on public ports. It retained the upstream fragment generator and OCI images while moving public TLS to host Caddy.

The planned topology was:

```text
public https://pay.example.com
        |
host Caddy
        |
127.0.0.1:8080
        |
BTCPay, PostgreSQL, NBXplorer, pruned Bitcoin, pruned Monero
```

Boltz nodeless mode was intended to accept Lightning through Liquid without a local Lightning daemon. Stripe Payments was intended to add card methods on BTCPay checkout. Consumer applications would use Greenfield and webhooks, never direct provider or chain access.

## Historical host observations

The plan estimated roughly 4 vCPU, 8 GB RAM, and 500 GB SSD for the full local profile, while noting that estimates were not substitutes for clean-host and disk-performance tests. One contemplated host had 6 KVM vCPUs, 17 GiB RAM, and about 1 TB of non-rotational XFS storage. Pruned Bitcoin with `opt-save-storage-s` was expected to use on the order of 50 GB; Monero, PostgreSQL, plugins, backups, logs, and update headroom required additional capacity.

It required:

- AlmaLinux 10.2 as the first x86_64/x86-64-v3 target;
- KVM rather than OpenVZ-style constraints;
- cgroup v2 and SELinux enforcing;
- XFS `ftype=1` under `/var/lib/almapay`;
- a reviewed non-copy-on-write swapfile procedure on reflink XFS;
- DNS, time synchronization, and public ports 80/443 for Caddy;
- port 8080 and all internal ports closed publicly.

## Historical bootstrap sketch

The old document included this explicitly unpinned identity sketch:

```bash
sudo groupadd -r almapay 2>/dev/null || true
sudo useradd -r -g almapay -d /var/lib/almapay -s /sbin/nologin \
  -c "BTCPay Podman runtime" almapay
sudo install -d -o almapay -g almapay -m 0750 /var/lib/almapay
sudo loginctl enable-linger almapay
```

It also showed `dnf install podman git curl jq shadow-utils` only as pseudocode. The current implementation requires exact locked packages and intentionally blocks while the lock remains unresolved.

The plan required non-overlapping `/etc/subuid` and `/etc/subgid` allocations. After changing allocations on an existing runtime, every affected container had to stop before an explicit `podman system migrate` as `almapay`. Firewalld changes had to detect and preserve the active SSH port before allowing HTTP/HTTPS.

## Historical generator sketch

The old runbook proposed a detached checkout of `btcpayserver-docker` at a placeholder commit:

```bash
sudo -u almapay -H git clone \
  https://github.com/btcpayserver/btcpayserver-docker.git \
  /var/lib/almapay/btcpayserver-docker
sudo -u almapay -H bash -lc '
  cd /var/lib/almapay/btcpayserver-docker
  git fetch origin "<PINNED_UPSTREAM_COMMIT>"
  git checkout --detach "<PINNED_UPSTREAM_COMMIT>"
'
```

It proposed mandatory generator intent:

```ini
BTCPAY_HOST=pay.example.com
BTCPAY_PROTOCOL=https
BTCPAYGEN_CRYPTO1=btc
BTCPAYGEN_CRYPTO2=xmr
BTCPAYGEN_REVERSEPROXY=none
BTCPAYGEN_LIGHTNING=none
BTCPAYGEN_EXCLUDE_FRAGMENTS=bitcoin
BTCPAYGEN_ADDITIONAL_FRAGMENTS=bitcoincore;opt-save-storage-s
NOREVERSEPROXY_HTTP_PORT=127.0.0.1:8080
PODMAN_COMPOSE_PROVIDER=/usr/bin/podman-compose
```

The historical container invocation referenced a placeholder published generator digest. That approach is obsolete: the hardened implementation builds or verifies a pinned local generator from pinned source and digest-pinned base images, excludes both the old Bitcoin and Tor/socket fragments, and validates the rendered YAML semantically.

The plan already identified an important upstream issue: the `btc` crypto definition selected an older `bitcoin.yml`, so the Core 30+ fragment had to replace it. It also warned that fragment composition could alter `BITCOIN_EXTRA_ARGS`, requiring inspection of final RPC and pruning arguments.

## Historical systemd and Caddy sketches

The proposed user unit was a compose-level oneshot service with:

```ini
[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/var/lib/almapay
Environment=XDG_RUNTIME_DIR=/run/user/ALMAPAY_UID
Environment=PODMAN_COMPOSE_PROVIDER=/usr/bin/podman-compose
ExecStart=/usr/bin/podman compose -f ... --env-file .env up -d --remove-orphans
ExecStop=/usr/bin/podman compose -f ... --env-file .env down
```

The current unit additionally loads the protected secrets file. Quadlet was deferred because it did not directly consume the authoritative Compose model; any future conversion had to prove equivalence for volumes, dependencies, networking, health checks, restart behavior, and updates.

The proposed Caddy shape was:

```caddy
pay.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

The plan separated the non-secret AlmaPay source from active root-owned Caddy configuration. It expected the Caddy service account to bind 80/443 through host service configuration rather than running Caddy as root.

## Historical wallet and plugin notes

Bitcoin planning required descriptor-based wallets, `CREATE_WALLET=false`, internal RPC, and no removed BDB-era RPCs (`importprivkey`, `importaddress`, `importmulti`, `importwallet`, `dumpprivkey`, or `dumpwallet`). Existing BDB migration via `migratewallet` was a separate manual procedure.

Monero was planned as one server-wide view-only wallet configuration. Separate account indexes could provide bookkeeping separation, but all accounts still shared wallet custody and view material. BTCPay would generate fresh subaddresses within the selected account. Independent test/production treasury or view-key access required separate deployments. The plan noted that older plugin builds had edge cases outside account `0`.

Boltz planning required nodeless mode, a Liquid wallet decision, fee and swap review, and a maximum accepted Liquid balance. It warned that zero-amount invoices were unsupported.

Stripe planning required per-store credentials, strict separation of test and live keys, and explicit authorization before live mode. It was not a replacement for recurring subscription billing.

The plan rejected LNBank, LNDHub, Lightning Charge, and deprecated Shopify Scripts for BTCPay 2.4. Plugin changes required restart through user systemd and explicit version/status verification.

## Historical operations and recovery plan

Updates were intended to be lockfile-driven, beginning with a verified backup, regenerating Compose, inspecting source/image/fragment changes, restarting through user systemd, and retaining prior artifacts. The plan explicitly did not promise binary rollback after database migration.

It divided recovery into two domains:

1. Application state exported as `almapay`: PostgreSQL logical data, BTCPay/plugin/wallet state, protected config, generated Compose, lockfile, user unit, Caddy source, checksums, encryption, and off-host retention.
2. Root-owned host state: active Caddy, subordinate-ID allocations, linger, firewall, SELinux customization, exact package inventory, and a manifest paired to the application artifact.

It prohibited root from copying live Podman storage and proposed host rebuild, identity/sub-ID recreation, pinned package restoration, application restore as `almapay`, loopback verification, Caddy installation, then reopening traffic.

The current `backup`, `restore`, and `update` commands deliberately fail closed because this plan has not been implemented or tested.

## Historical privacy and limitations

The Arkfile profile was intended to omit Caddy access logging and prove that Caddy, BTCPay, journald, and diagnostics did not retain client IP addresses. It warned that Caddy forwarding headers required testing rather than reflexive removal.

The document acknowledged that rootless Podman, an external Compose provider, host Caddy, and skipping the upstream setup script were not upstream's standard tested deployment shape. It required separate-store and webhook testing before accepting funds and reserved all low-value mainnet/live payments for a human operator.

These historical observations remain context only. Current status, commands, and gates are authoritative in the [operator guide](../operator-guide.md), [production-readiness checklist](../production-readiness.md), and [implementation specification](../alma-pay-spec.md).
