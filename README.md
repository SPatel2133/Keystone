# Crash-safe event consumer

This Ruby CLI consumes one local event stream. It reads one JSON request through EOF and uses `ledger.sqlite3` in the caller’s working directory. Run it from a scratch directory when exploring the contract.

## Setup and demo

Tested on macOS arm64 with Ruby 2.6.10, Bundler 1.17.2, sqlite3 gem 1.3.13, SQLite 3.51.0, and Minitest 5.11.3. The sqlite3 gem needs a compiler and SQLite development headers when installed from source.

Run these commands from the project directory.

```sh
bundle check || bundle install --path vendor/bundle
bin/check
bin/demo
bin/demo --evidence > evidence.jsonl
```

The demo creates and removes its own scratch databases. It shows the sequence order 1, 3, 2, two real process kills, the SQLite rows before each retry, and a rejected conflict. The checked-in [evidence](evidence.jsonl) records expected and observed results, versions, and a digest of the source, test, and dependency files. See [verification](VERIFICATION.md) for the release commands and results.

Try the production entry from an unrelated directory.

```sh
project="$PWD"
scratch="$(mktemp -d)"
(
  cd "$scratch" || exit 1
  printf '%s\n' '{"op":"deliver","seq":3,"delta":2}' | "$project/bin/ledger"
  printf '%s\n' '{"op":"state"}' | "$project/bin/ledger"
)
```

The first response is `{"status":"accepted","seq":3,"cursor":0,"balance":0}`. The state stays at cursor 0 and balance 0 until the missing earlier sequences arrive.

## How it works

- Ruby validates the request before opening storage. It recognizes an identical retry by sequence and delta and returns the current checkpoint. A different delta for a stored sequence is a conflict, even after that event has been applied.
- SQLite stores the first accepted delta for each sequence and one checkpoint. Ruby finds the consecutive keys above the cursor and sums their deltas. A zero delta still advances the cursor. Insertion and checkpoint update commit together under `BEGIN IMMEDIATE`.
- Ruby emits the receipt after SQLite commits. If the process dies between the commit and the receipt, retrying the same event returns `duplicate`. A death before commit allows the retry to return `accepted`. Splitting the insert and checkpoint updates into two commits can strand an event row with a stale checkpoint after a crash.
- A SQLite lock timeout returns `{"error":"busy","retryable":true}` after rolling back any active transaction. The lock wait is configured for 250 ms. Unexpected failures exit nonzero with a diagnostic on stderr.
- Sequences are positive signed 64-bit integers, and each delta is signed 64-bit. Ruby sums with arbitrary precision. SQLite stores the balance as canonical decimal text. The JSON response contains exact integer tokens. JavaScript clients using `Number` can lose precision for values outside the safe-integer range. Use a lossless JSON parser for such values.

An indefinitely missing sequence stalls the checkpoint and lets pending rows accumulate. Applied rows are retained too, so the database grows with the number of unique sequences. That history lets the ledger distinguish identical retries from conflicting deltas after application.

The recovery tests verify process death on one host with one local SQLite database and no external side effects. Power loss and exactly-once delivery across services are outside the tested scope.

## Walkthrough questions

1. What stored fact proves event 3 was received but remains unapplied?
2. Why do the two retries yield different receipts with the same final balance?
3. What changes if the missing sequence never arrives?

## Shopify order and refund ledger

The Shopify path uses a separate SQLite database and leaves the sequence-based
consumer available through `bin/ledger`. Run `bin/shopify-check` for the
black-box Shopify suite and `bin/shopify-demo` for the replay and reconciliation
demo. Both use disposable databases and a local fake Shopify GraphQL server.
They require no Shopify account, credentials, or webhook tunnel.

```sh
bundle check
bin/check
bin/shopify-check
bin/shopify-demo
bin/shopify-demo --evidence > shopify-evidence.jsonl
```

See the [Shopify verification runs](VERIFICATION.md#shopify-verification) and
[recorded demo evidence](shopify-evidence.jsonl).

The same lockfile covers both paths. The CI workflow targets Ubuntu 22.04 with
Ruby 2.6.10, Bundler 1.17.2, sqlite3 1.3.13, and Minitest 5.11.3. Install a C
compiler and SQLite headers for a source build. Ruby 2.6 is end of life and is
retained here to match the available local runtime and the existing CLI. Use a
supported runtime before deploying an Internet-facing service.

### Running the Shopify commands

Set `SHOPIFY_LEDGER_CONFIG` to the path of a local JSON configuration. The
database path is resolved relative to that file. Keep the file outside version
control and use a different database from the original ledger.

```json
{
  "database": "shopify.sqlite3",
  "secret": "REPLACE_WITH_APP_CLIENT_SECRET",
  "shops": {
    "example.myshopify.com": {
      "token": "REPLACE_WITH_ADMIN_ACCESS_TOKEN"
    }
  }
}
```

```sh
export SHOPIFY_LEDGER_CONFIG=/path/to/shopify-ledger.local.json
bin/shopify-webhook
```

The service listens on IPv4 localhost at port 9292 by default. Set
`SHOPIFY_LEDGER_PORT` to change it. Register `orders/updated` and
`refunds/create` on an HTTPS endpoint that routes `POST /webhooks` to the
service and limits request body size. For order reads, use a configured shop token with `read_orders` and
Shopify's applicable data permissions. Trusted configuration selects the
destination and token. The HTTP loopback override is used by the synthetic
fixtures.

From another terminal with the same configuration:

```sh
bin/shopify-worker --once
bin/shopify-summary example.myshopify.com
bin/reconcile example.myshopify.com
```

`--once` processes one eligible delivery. It reports `processed`, `idle`, or
`retry`. A retry exits nonzero and defers the delivery for 2, 4, 8, 16, 32,
then at most 60 seconds per attempt. The worker selects the oldest eligible
delivery and can process other orders while a failure backs off. Invoke the
worker repeatedly to drain the inbox.

### Storage and recovery

- Verify the Shopify signature over the raw body before JSON parsing. Store only shop, delivery ID, topic, and order ID plus processing metadata. Return HTTP 200 after committing a new delivery or confirming a matching retry. Reusing the same shop and delivery ID for a different order or topic returns HTTP 409. The first delivery remains available to the worker.
- The worker fetches a complete order transaction set through Admin GraphQL `2026-10` outside the SQLite write transaction. It requires an exact transaction count and distinct IDs. It counts successful sales and captures as collected, and successful refunds as positive refunds. Net is collected minus refunded. Totals are exact decimal strings separated by shop and shop currency. They describe observed order payment transactions.
- Worker writes and the inbox processed flag commit together. A delivery ID deduplicates HTTP retries, and a transaction ID deduplicates payment effects across different deliveries. Shopify webhook delivery order is irrelevant because each accepted delivery points to the current order transactions.
- Reconciliation reads a fixed window of changed orders using `UPDATED_AT`. It saves the start of the first seven-day window before fetching page one. A retry keeps that starting point even if the first scan failed days ago. After a successful run, later scans start five minutes before the completed checkpoint. Failed scans can leave imported orders durable while preserving the checkpoint for replay. Recovery covers the chosen window and the shop's authorized order history.
- Older Shopify ledger databases upgrade automatically in a SQLite transaction. Commands verify the application tables before reporting merchant totals. An incompatible database produces an error.
- The demo proves recovery from process death on one host. Verification uses synthetic Shopify responses and a single SQLite database. A live Shopify installation, power loss, and multi-host operation are outside the verified scope.

[Shopify webhook verification](https://shopify.dev/docs/apps/build/webhooks/verify-deliveries) ·
[Order transaction schema](https://shopify.dev/docs/api/admin-graphql/2026-10/objects/OrderTransaction) ·
[Order reconciliation query](https://shopify.dev/docs/api/admin-graphql/2026-10/queries/orders)
