# Reference integration: Arkfile

Arkfile is the first reference consumer used to prove AlmaPay. It is not embedded in or required by the runtime. Read the generic [integrator guide](../integrator-guide.md) first; this document contains only Arkfile-specific policy and acceptance requirements.

Arkfile remains the source of truth for invoice ownership, account balances, PAYG metering, and credit-ledger idempotency. AlmaPay only provides reliable invoice creation, status lookup, checkout, and webhook delivery.

Arkfile stores USD using `100,000,000` microcents per USD. AlmaPay must never compensate for an Arkfile conversion bug by changing payment amounts or metadata.

## Privacy profile

Arkfile may send only:

- Amount
- Currency
- An opaque local invoice identifier
- Checkout redirect information

Arkfile must not send usernames, email addresses, filenames, object keys, storage usage, account balances, subscription state, or other user PII in BTCPay metadata.

The Arkfile production profile must verify that Caddy, BTCPay, journald, and AlmaPay diagnostics do not retain client IP addresses. Inability to prove that is a production blocker for Arkfile. Prefer omitting Caddy's `log` directive so HTTP access logging stays disabled by default, and apply any header policy only after testing pinned Caddy and BTCPay behavior.

## Invoice creation

```http
POST /api/v1/stores/{storeID}/invoices
Authorization: token <restricted Greenfield API key>
```

Request semantics:

- Currency: `USD`
- Amount: two decimal places
- `metadata.invoice_id`: opaque local invoice ID, no PII
- `checkout.speedPolicy`: `LowMediumSpeed` (two confirmations). `HighSpeed` is prohibited for Arkfile production top-ups
- `checkout.expirationMinutes`: `60`
- Redirect URL points back to Arkfile

Expected success: HTTP `201` with provider `id` and `checkoutLink` on the public origin (never loopback).

## Status and settlement

Arkfile polls:

```http
GET /api/v1/stores/{storeID}/invoices/{invoiceID}
```

Remote `Settled` is payable. Polling and administrative synchronization recover missed webhooks.

Webhook endpoint shape (example only):

```text
https://app.example.com/api/webhooks/btcpay
```

Authoritative settlement event: Greenfield `InvoiceSettled`. Do not depend on legacy BitPay-style `InvoiceCompleted`. Match `metadata.invoice_id`, with provider `invoiceId` as fallback; when both are present they must bind to the same local record. Final local invoice transition and credit-ledger insertion are transactional. Replays must not add credit again.

Use a runtime key with only invoice create and invoice read permissions. Webhook provisioning uses a separate operator or short-lived key.

## Operator-supplied Arkfile env (placeholders)

AlmaPay produces these values for the operator. It never writes them into the Arkfile repository.

```ini
ARKFILE_PAYMENTS_ENABLED=true
ARKFILE_BTCPAY_SERVER_URL=https://pay.example.com
ARKFILE_BTCPAY_STORE_ID=<store-id>
ARKFILE_BTCPAY_API_KEY=<restricted-api-key>
ARKFILE_BTCPAY_WEBHOOK_SECRET=<webhook-secret>
ARKFILE_MIN_TOP_UP_USD=0.50
ARKFILE_MAX_TOP_UP_USD=1000.00
```

Require a normalized public HTTPS BTCPay origin in production. Reject loopback, credential-bearing, query-bearing, fragment-bearing, or unexpected-path URLs.

## Arkfile-side acceptance gates

Before production use, Arkfile itself must:

- Use canonical microcents conversion for PAYG limits, invoices, and ledger entries
- Reject top-up precision beyond two decimal places; construct amounts without float rounding
- Persist a recoverable local invoice association around remote creation
- Bound webhook bodies, verify exact raw-body signature, validate store, reject conflicting IDs
- Reconcile remotely settled pending invoices, not only locally paid ones
- Keep usernames, balances, checkout URLs, credentials, and raw webhook payloads out of logs
- Prove concurrent and replayed webhooks, polling, and reconciliation insert at most one credit

## Reference acceptance test

1. Create a small USD invoice through the same Greenfield request Arkfile uses.
2. Confirm checkout URL uses the public AlmaPay hostname.
3. Pay through an enabled test payment method.
4. Confirm a correctly signed settlement webhook.
5. Confirm Arkfile marks the local invoice paid.
6. Confirm exactly one positive credit transaction.
7. Replay the webhook; balance and ledger must not change again.
8. Exercise polling or administrative synchronization.
9. Suppress one webhook; confirm reconciliation repairs local state from the remote settled invoice.
10. Confirm BTCPay metadata contains only the opaque local invoice ID.

These Arkfile gates supplement, rather than repeat, the deployment and per-method checklist in [Production readiness](../production-readiness.md).

## Related documents

- [Integrator guide](../integrator-guide.md)
- [Design and security model](../design.md)
- [Production readiness](../production-readiness.md)
