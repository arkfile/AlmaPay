#!/usr/bin/env python3
from __future__ import annotations

import unittest
from pathlib import Path
from urllib.parse import urlsplit

import yaml


ROOT = Path(__file__).resolve().parents[1]
GENERIC = ROOT / "tests" / "fixtures" / "integration" / "generic-consumer.yaml"


class GenericContractFixtureTests(unittest.TestCase):
    def test_generic_fixture_is_public_origin_and_pii_minimal(self):
        data = yaml.safe_load(GENERIC.read_text(encoding="utf-8"))
        self.assertEqual(data["currency"], "USD")
        self.assertRegex(data["amount"], r"^\d+\.\d{2}$")
        self.assertEqual(set(data["metadata"]), {"invoice_id"})
        self.assertEqual(data["checkout"]["speedPolicy"], "LowMediumSpeed")
        self.assertEqual(data["checkout"]["expirationMinutes"], 60)
        checkout = urlsplit(data["expectations"]["checkout_origin"])
        self.assertEqual(checkout.scheme, "https")
        self.assertNotIn(checkout.hostname, {"127.0.0.1", "localhost"})
        self.assertEqual(data["expectations"]["settlement_event"], "InvoiceSettled")
        self.assertTrue(data["expectations"]["no_cross_store_access"])
        self.assertTrue(data["expectations"]["idempotent_webhook_replay"])


if __name__ == "__main__":
    unittest.main()
