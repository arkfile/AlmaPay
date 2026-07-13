# AlmaPay implementation TODO

This is a working backlog, not active installation guidance or a statement of supported functionality. The normative contract remains [`../alma-pay-spec.md`](../alma-pay-spec.md).

## 1. Complete the release lock

- Replace every `PENDING` and `REPLACE` value in `upstream.lock`.
- Record the exact RPM dependency closure with immutable artifact URLs, checksums, repository metadata checksums, and signing-key fingerprints.
- Run `almapay research-generator` and record the reviewed generator Dockerfile hash, builder and runtime base-image digests, and deterministic generator image digest.
- Revalidate all runtime image manifest and linux/amd64 platform digests.
- Revalidate plugin releases, source commits, artifact hashes, compatibility, signatures, and known provenance gaps.
- Promote the lock only after review and the required integration tests pass.

## 2. Exercise real upstream generation

- Build the generator from the pinned upstream commit and digest-pinned bases.
- Generate Compose using the actual pinned generator rather than only fixtures.
- Save and review the generated semantic model and diff.
- Confirm the actual generated document passes every AlmaPay security invariant.
- Test the exact locked `podman-compose` provider against the generated model.
- Retain representative pinned generator output as a golden integration fixture.

## 3. Add an AlmaLinux container harness

- Run compatibility checks in an AlmaLinux 10.2 container without downloading blockchain data.
- Verify Bash, Python, PyYAML, RPM, package, Caddy, and generator compatibility.
- Verify locked package artifacts and dependency-closure installation.
- Validate Caddy and generated Compose inside the fixture where practical.
- Keep the limitations explicit: a container cannot prove host systemd, firewalld, nested rootless Podman, SELinux enforcement, subordinate-ID migration, reboot persistence, or production networking.

## 4. Expand automated coverage

- Add mocked `doctor` tests for platform, network, package, listener, capacity, SELinux, firewalld, and rootless-runtime outcomes.
- Add mocked non-production and production `verify` tests, including expected fail-closed behavior.
- Exercise generated user-systemd units, protected environment files, and `systemd-analyze verify`.
- Add semantic Compose cases for long-form and IPv6 ports, malformed YAML, aliases, null environments, namespace modes, capabilities, SSH integration, engine sockets, absolute mounts, and unexpected services.
- Add a golden test based on output from the exact pinned upstream generator.
- Run ShellCheck as a required CI job instead of skipping it when unavailable.
- Add Python linting and formatting checks appropriate for the small helper surface.
- Run the Bitcoin-only regtest smoke test in a rootless-Podman CI job while preserving its status as a fixture rather than a deployment profile.
- Add Arkfile contract compatibility checks without coupling AlmaPay runtime code to Arkfile.

## 5. Improve Python maintainability

- Add concise contract-focused docstrings to:
  - `locked_images`
  - `render`
  - `environment_dict`
  - `short_port`
  - `validate`
- Add module/class documentation for the Compose tests and document the `run_model` and `mutate` helpers.
- Avoid repetitive per-test docstrings when the test name already states the behavior.
- Consider structured validation issues with stable codes such as `PORT_PUBLIC`, `IMAGE_UNLOCKED`, and `POSTGRES_NO_SCRAM`, so tests do not depend on matching human-readable error prose.
- Consider separating lock validation, Compose transformation, and security validation if the current module grows substantially; avoid splitting it solely for file-size reasons.

## 6. Implement production blockers

- Implement service-aware application backup with logical PostgreSQL export, application/plugin/custody state, encryption, authenticated manifests, and off-host retention.
- Implement traversal-safe, empty-target restore and prove it on a clean host.
- Implement lock-driven update only after verified backup and restore work.
- Implement stable Monero, Boltz, and Stripe plugin installation and runtime version verification.
- Complete production verification for plugins, backup recency, privacy, Greenfield permissions, webhook delivery, synchronization, and capacity.
- Add production-verification evidence and non-secret configuration/lock hashes.

## 7. Complete platform acceptance

- Run clean installation on AlmaLinux 10.2 x86_64 with x86-64-v3.
- Verify SELinux remains enforcing through install and runtime.
- Verify rootless Podman, subordinate IDs, linger, user systemd, firewalld, Caddy, and reboot persistence.
- Test repeated installation and recovery from partial failure.
- Test update and complete clean-host restore.
- Verify no internal service port is public and BTCPay remains available only through host Caddy.
- Run operator-authorized payment acceptance separately for each enabled method; automated agents must never initiate real-money tests.
