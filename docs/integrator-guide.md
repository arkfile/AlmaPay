# Integrator guide

AlmaPay hosts BTCPay. Your application owns users, business records, invoice mapping, balances, fulfillment, retries, reconciliation, and webhook idempotency.

AlmaPay is not a billing engine, account system, credit ledger, payment gateway abstraction, client SDK, recurring-subscription system, or multi-tenant SaaS.

## What you get

- Customer-facing checkout on the public HTTPS origin (for example `https://pay.example.com`)
- Store-scoped Greenfield API access
- Signed HTTPS webhook delivery
- Operational verification of the payment stack

What you do not get:

- A universal invoice metadata schema
- A shared application credential or global app URL
- Direct access to Bitcoin, Monero, Boltz, or Stripe from your app
- Isolation against the shared host operator (separate stores are credential separation under one trusted operator)

## Store and credential model

For each consumer application and environment:

1. Create or select a dedicated BTCPay store.
2. Issue a least-privilege, store-scoped Greenfield API key.
3. Register one or more HTTPS webhook endpoints you control.
4. Store API keys and webhook secrets outside AlmaPay and application source repositories.
5. Rotate or revoke one consumer's credentials without touching another.

Credentials for one store must not read or mutate another store. Server-wide plugins, logging policy, and some custody material remain shared. Monero wallet view material is server-wide; apps that need independent treasury or conflicting host policies need separate AlmaPay deployments.

## Public origin only

Always configure and return the public BTCPay hostname for checkout. Never put `127.0.0.1:8080` in integrator config or customer links. That address is Caddy's private upstream only.

## Typical Greenfield flow

Create an invoice (shape only; not Arkfile-specific):

```http
POST /api/v1/stores/{storeID}/invoices
Authorization: token <store-scoped-api-key>
Content-Type: application/json
```

Direct the customer to the returned `checkoutLink` on the public origin. Poll invoice status when needed:

```http
GET /api/v1/stores/{storeID}/invoices/{invoiceID}
Authorization: token <store-scoped-api-key>
```

Webhook delivery uses an HMAC signature header of the form:

```text
BTCPay-Sig: sha256=<hex HMAC-SHA256 of raw body>
```

Verify the signature over the exact raw body, bound request size, validate the expected store, and apply your own payable-status and fulfillment rules.

## Application responsibilities

Design and implement:

- Idempotent webhook handling (replays must not double-fulfill)
- Retries and missed-webhook recovery (poll or reconcile remotely settled invoices)
- Mapping between BTCPay invoice IDs and your local business records
- Privacy and retention for any metadata you choose to send
- Credential rotation without downtime assumptions across unrelated stores

Minimize invoice metadata. AlmaPay does not require consumer PII and must not invent it on your behalf.

## Testing without enabling mainnet methods

- Use AlmaPay's static contract, Compose, and lock fixtures in CI where applicable.
- Exercise create-invoice, checkout URL shape, webhook signature verification, replay, and reconciliation against fixtures.
- The optional Bitcoin-only regtest does not settle a BTCPay invoice and is not a supported deployment profile.
- Do not enable mainnet payment methods until the operator completes per-method gates in [Production readiness](production-readiness.md).

The canonical integration acceptance checklist is in [Production readiness](production-readiness.md). It covers least privilege, cross-store isolation, public checkout origin, signed-webhook replay, missed-webhook reconciliation, and credential rotation.

## Example consumer environment (placeholders)

```ini
YOUR_APP_BTCPAY_SERVER_URL=https://pay.example.com
YOUR_APP_BTCPAY_STORE_ID=<store-id>
YOUR_APP_BTCPAY_API_KEY=<restricted-api-key>
YOUR_APP_BTCPAY_WEBHOOK_SECRET=<webhook-secret>
```

AlmaPay never writes these into your application repository. The operator supplies them securely.

## Related documents

- [Reference integration: Arkfile](reference-integrations/arkfile.md)
- [Design and security model](design.md)
- [Operator guide](operator-guide.md)
- [Production readiness](production-readiness.md)
