# AlmaPay

AlmaPay is an application-agnostic toolkit for operating self-hosted [BTCPay Server](https://btcpayserver.org/) on AlmaLinux 10+ with rootless Podman and host-installed Caddy.

## Status

**AlmaPay is not installable or production-ready today.** `upstream.lock` is a candidate lock containing unresolved `PENDING` and `REPLACE` values. The CLI intentionally blocks bootstrap, install, generation, start, and runtime verification until the lock is promoted to `validated` or `production`.

Backup, restore, and update deliberately fail closed. `verify --production` is also blocked until plugin, backup/restore, privacy, Greenfield-permission, and webhook checks exist and have been exercised. No AlmaLinux VM integration has run, and agents have no production VPS access.

The intended initial profile is one AlmaLinux 10+ x86-64-v3 host, rootless Podman under `almapay`, BTCPay on `127.0.0.1:8080` behind host Caddy, PostgreSQL with SCRAM, NBXplorer, and local pruned Bitcoin Core 30+. Monero services can be generated, but Monero plugin/custody readiness is not production-proven. Boltz and Stripe can be selected in configuration and have candidate pins, but stable installation and runtime verification are not implemented.

## Start here

- Developer or agent: read [AGENTS.md](AGENTS.md), then the normative [implementation specification](docs/alma-pay-spec.md).
- Operator: use the [operator guide](docs/operator-guide.md) and [production-readiness checklist](docs/production-readiness.md).
- Integrator: use the generic [integrator guide](docs/integrator-guide.md); Arkfile users may also read the [Arkfile reference profile](docs/reference-integrations/arkfile.md).
- Reviewer: read the [design and security model](docs/design.md) with the [implementation specification](docs/alma-pay-spec.md).

Historical planning material is archived and is not active installation guidance.

## Local tests

```bash
./tests/run.sh
```

The current suite reports 43 top-level passes, skips ShellCheck when it is unavailable, and runs additional semantic Python subtests. `ALMAPAY_RUN_REGTEST=1 ./tests/run.sh` additionally runs a Bitcoin-only regtest fixture without a chain download; it does not settle a BTCPay invoice and is not a supported deployment profile.

## License

See [LICENSE](LICENSE).
