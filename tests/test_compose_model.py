#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "compose_model.py"
LOCK = ROOT / "tests" / "fixtures" / "lock" / "upstream.validated.yml"
RAW = ROOT / "tests" / "fixtures" / "compose" / "docker-compose.generated.yml"
GOOD = ROOT / "tests" / "fixtures" / "compose" / "docker-compose.almapay-good.yml"
BAD = ROOT / "tests" / "fixtures" / "compose" / "docker-compose.bad.yml"


class ComposeModelTests(unittest.TestCase):
    def run_model(self, action: str, source: Path, output: Path | None = None):
        command = [
            "python3",
            str(SCRIPT),
            action,
            "--input",
            str(source),
            "--lock",
            str(LOCK),
        ]
        if output is not None:
            command += ["--output", str(output)]
        return subprocess.run(command, text=True, capture_output=True)

    def mutate(self, callback) -> Path:
        model = yaml.safe_load(GOOD.read_text(encoding="utf-8"))
        callback(model)
        handle = tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False)
        with handle:
            yaml.safe_dump(model, handle, sort_keys=False)
        return Path(handle.name)

    def test_good_semantic_model_passes(self):
        result = self.run_model("validate", GOOD)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_bad_model_fails(self):
        result = self.run_model("validate", BAD)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("privileged", result.stderr)
        self.assertIn("unexpected host-published port", result.stderr)

    def test_render_replaces_trust_and_all_tags(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "rendered.yml"
            result = self.run_model("render", RAW, output)
            self.assertEqual(result.returncode, 0, result.stderr)
            rendered = yaml.safe_load(output.read_text(encoding="utf-8"))
            services = rendered["services"]
            self.assertTrue(services)
            for service in services.values():
                self.assertRegex(service["image"], r"@sha256:[0-9a-f]{64}$")
            self.assertEqual(
                services["postgres"]["environment"]["POSTGRES_HOST_AUTH_METHOD"],
                "scram-sha-256",
            )
            self.assertEqual(
                services["postgres"]["environment"]["POSTGRES_PASSWORD"],
                "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}",
            )
            self.assertIn(
                "Password=${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}",
                services["btcpayserver"]["environment"]["BTCPAY_POSTGRES"],
            )
            self.assertIn(
                "Database=nbxplorer${NBITCOIN_NETWORK:-regtest}",
                services["btcpayserver"]["environment"][
                    "BTCPAY_EXPLORERPOSTGRES"
                ],
            )
            self.assertNotIn(
                "BTCPAY_SSHCONNECTION", services["btcpayserver"]["environment"]
            )
            self.assertNotIn(
                "BTCPAY_SSHKEYFILE", services["btcpayserver"]["environment"]
            )
            self.assertEqual(
                services["btcpayserver"]["environment"]["BTCPAY_DOCKERDEPLOYMENT"],
                "false",
            )
            self.assertFalse(
                any(
                    "SSH" in str(volume).upper()
                    for volume in services["btcpayserver"]["volumes"]
                )
            )
            bitcoind_volumes = services["bitcoind"]["volumes"]
            self.assertIn(
                "/var/lib/almapay/chaindata/bitcoin:/data:Z", bitcoind_volumes
            )
            self.assertIn(
                "/var/lib/almapay/chaindata/bitcoin-wallet:/walletdata:Z",
                bitcoind_volumes,
            )
            self.assertNotIn("volumes", rendered)

    def test_dual_public_and_loopback_bind_fails(self):
        path = self.mutate(
            lambda model: model["services"]["btcpayserver"]["ports"].append(
                "0.0.0.0:8080:49392"
            )
        )
        self.addCleanup(path.unlink)
        result = self.run_model("validate", path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected host-published port", result.stderr)

    def test_missing_bitcoin_argument_fails(self):
        def remove_argument(model):
            args = model["services"]["bitcoind"]["environment"]["BITCOIN_EXTRA_ARGS"]
            model["services"]["bitcoind"]["environment"]["BITCOIN_EXTRA_ARGS"] = (
                args.replace("mempoolfullrbf=1", "")
            )

        path = self.mutate(remove_argument)
        self.addCleanup(path.unlink)
        result = self.run_model("validate", path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mempoolfullrbf=1", result.stderr)

    def test_digest_mismatch_fails(self):
        path = self.mutate(
            lambda model: model["services"]["postgres"].__setitem__(
                "image",
                "btcpayserver/postgres@sha256:"
                + "0" * 64,
            )
        )
        self.addCleanup(path.unlink)
        result = self.run_model("validate", path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exact locked", result.stderr)

    def test_absolute_host_bind_fails(self):
        path = self.mutate(
            lambda model: model["services"]["btcpayserver"]
            .setdefault("volumes", [])
            .append("/etc:/host-etc:ro")
        )
        self.addCleanup(path.unlink)
        result = self.run_model("validate", path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dangerous host mount", result.stderr)

    def test_passwordless_connection_fails(self):
        path = self.mutate(
            lambda model: model["services"]["nbxplorer"]["environment"].__setitem__(
                "NBXPLORER_POSTGRES",
                "User ID=btcpay;Host=postgres;Database=btcpaydb",
            )
        )
        self.addCleanup(path.unlink)
        result = self.run_model("validate", path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("authenticated PostgreSQL", result.stderr)

    def test_focused_security_invariants_fail(self):
        cases = (
            (
                "capability",
                lambda model: model["services"]["bitcoind"].__setitem__(
                    "cap_add", ["SYS_ADMIN"]
                ),
                "added capabilities",
            ),
            (
                "host-network",
                lambda model: model["services"]["postgres"].__setitem__(
                    "network_mode", "host"
                ),
                "host network_mode",
            ),
            (
                "wallet",
                lambda model: model["services"]["bitcoind"]["environment"].__setitem__(
                    "CREATE_WALLET", "true"
                ),
                "CREATE_WALLET",
            ),
            (
                "legacy-links",
                lambda model: model["services"]["btcpayserver"].__setitem__(
                    "links", ["postgres"]
                ),
                "legacy Compose links",
            ),
            (
                "runtime-build",
                lambda model: model["services"]["postgres"].__setitem__(
                    "build", "."
                ),
                "runtime image builds",
            ),
            (
                "monero-pruning",
                lambda model: model["services"]["monerod"].__setitem__(
                    "command", ["monerod"]
                ),
                "--prune-blockchain",
            ),
        )
        for name, mutate, expected in cases:
            with self.subTest(name=name):
                path = self.mutate(mutate)
                try:
                    result = self.run_model("validate", path)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(expected, result.stderr)
                finally:
                    path.unlink()

    def test_disabled_monero_rejects_generated_monero_services(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "rendered.yml"
            command = [
                "python3",
                str(SCRIPT),
                "render",
                "--input",
                str(RAW),
                "--lock",
                str(LOCK),
                "--monero-mode",
                "disabled",
                "--output",
                str(output),
            ]
            result = subprocess.run(command, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Monero services are present", result.stderr)

    def test_unknown_image_fails_render(self):
        raw = yaml.safe_load(RAW.read_text(encoding="utf-8"))
        raw["services"]["unknown"] = {"image": "example.invalid/unknown:latest"}
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.yml"
            output = Path(directory) / "output.yml"
            source.write_text(yaml.safe_dump(raw), encoding="utf-8")
            result = self.run_model("render", source, output)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not in upstream.lock", result.stderr)

    def test_lock_image_version_below_floor_fails(self):
        lock = yaml.safe_load(LOCK.read_text(encoding="utf-8"))
        lock["images"]["bitcoin_core"]["reference"] = "btcpayserver/bitcoin:29.1"
        with tempfile.TemporaryDirectory() as directory:
            bad_lock = Path(directory) / "lock.yml"
            bad_lock.write_text(yaml.safe_dump(lock), encoding="utf-8")
            result = subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "validate",
                    "--input",
                    str(GOOD),
                    "--lock",
                    str(bad_lock),
                ],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("below minimum", result.stderr)


if __name__ == "__main__":
    unittest.main()
