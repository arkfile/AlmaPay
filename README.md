# AlmaPay

AlmaPay is an application-agnostic toolkit for operating self-hosted [BTCPay Server](https://btcpayserver.org/) on AlmaLinux 10+ with rootless Podman and host-installed Caddy.

## Status

**AlmaPay is not production-ready today.** The repository `upstream.lock` remains a candidate lock with unresolved placeholders. Backup, restore, update, and `verify --production` deliberately fail closed. No AlmaLinux VM integration has run.

For a first VPS install attempt, use a host staging lock at `/var/lib/almapay/upstream.lock` with repository bootstrap. Full steps are in the [guide](docs/guide.md#1-install).

## Quick install (staging)

Clone on the VPS, then from the repository directory:

```bash
sudo ./bin/almapay doctor
sudo ./bin/almapay lock-research --install-packages --write /var/lib/almapay/upstream.lock
sudo ./bin/almapay bootstrap-host --from-repos
sudo ./bin/almapay configure
sudo -u almapay -H ./bin/almapay lock-research --build-generator --write /var/lib/almapay/upstream.lock
sudo -u almapay -H ./bin/almapay install
sudo ./bin/almapay configure --install-caddy
sudo -u almapay -H ./bin/almapay start
sudo -u almapay -H ./bin/almapay verify
```

Point DNS at the host before public HTTPS verification. See the [guide](docs/guide.md) for configure flags, chaindata preservation, iteration, operations, integration, and the production checklist.

## Documentation

- [Guide](docs/guide.md) — install, commands, architecture, operations, integration, production readiness, troubleshooting
- [Implementation specification](docs/alma-pay-spec.md) — normative contract
- [AGENTS.md](AGENTS.md) — guidance for agents and developers
- [Arkfile reference profile](docs/reference-integrations/arkfile.md) — first reference consumer

Historical planning material is archived under `docs/archive/` and is not active installation guidance.

## Local tests

```bash
./tests/run.sh
```

The current suite reports 53 top-level passes, skips ShellCheck when it is unavailable, and runs additional semantic Python subtests. `ALMAPAY_RUN_REGTEST=1 ./tests/run.sh` additionally runs a Bitcoin-only regtest fixture without a chain download; it does not settle a BTCPay invoice and is not a supported deployment profile.

## License

See [LICENSE](LICENSE).
