# Crash-safe event processing in Ruby and SQLite

This project implements two event consumers. The Shopify ledger tracks sales and refunds by shop and currency, handles webhook retries, and reconciles missed deliveries. The sequence ledger applies inventory adjustments in order, including when a scan arrives late or a process dies after committing.

## Quick start

With Ruby 3.4.13 active, from the repository root install the locked dependencies and run both synthetic demos. The Shopify demo uses local fixtures and requires no merchant credentials.

```sh
bundle check || bundle install
bin/shopify-demo
bin/inventory-demo
```

In the Shopify demo, a 100.00 sale and a 25.00 refund leave 75.00 after replay. In the warehouse demo, the final count is 25 units after a missing scan arrives and the sender retries. Run `bin/check` and `bin/shopify-check` for the regression suites.

[Shopify ledger](#shopify-order-and-refund-ledger) · [Inventory walkthrough](#warehouse-inventory-walkthrough) · [Benchmark](#benchmark) · [Verification notes](VERIFICATION.md)

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

Both consumers share one lockfile. CI uses the Ruby version in `.ruby-version` on Ubuntu 22.04.

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

## Warehouse inventory walkthrough

From the project root, install the locked dependencies if needed. Run the inventory demo to exercise crash recovery.

```sh
bundle check || bundle install
project="$PWD"
"$project/bin/inventory-demo"
```

The warehouse opens with 20 units. Its ledger balance tracks *adjustments*. Watch scan 3 wait behind a gap, then watch SQLite after the child dies while acknowledging scan 2. The retry should leave 25 units on hand.

Output from `bin/inventory-demo` on Ruby 3.4.13

```text
Opening stock is 20 units. The ledger records adjustments starting at zero.
Scan 1 (+10) accepted. Cursor 1, adjustment +10, 30 units on hand.
Scan 3 (-2) accepted. Cursor 1, adjustment +10, 30 units on hand.
Waiting for scan 2. Scan 3 is already stored.
Scan 2 (-3) committed. SIGKILL (9) before acknowledgment, 0 stdout bytes.
SQLite before retry: rows=[[1,10],[2,-3],[3,-2]] checkpoint=[3,"5"]
Retry scan 2: {"status":"duplicate","seq":2,"cursor":3,"balance":5}
20 opening units + 5 adjustment units = 25 units on hand.
```

To inspect a stalled stream yourself, run the following from that same shell. The two deliveries create a ledger in a new temporary directory.

```sh
(
  cd "$(mktemp -d)" || exit 1
  printf '%s\n' '{"op":"deliver","seq":1,"delta":10}' | "$project/bin/ledger"
  printf '%s\n' '{"op":"deliver","seq":3,"delta":-2}' | "$project/bin/ledger"
  "$project/bin/doctor"
)
```

The doctor reads the caller's ledger in one SQLite snapshot. Here the applied balance is +10, and scan 3 is already stored. Receiving scan 2 will allow both adjustments to apply.

Doctor supports the original ledger's rollback journal. It reports a missing ledger without creating a file and refuses externally configured WAL mode before SQLite can create sidecars.

### Benchmark

Run `"$project/bin/benchmark"` from any working directory. Each workload gets its own scratch database. The command checks the durable cursor, adjustment balance, and unique event count before printing JSON.

- **Ordered deliveries** averaged 3,392 acknowledgments/s over 1,000 new events. Median latency was 0.278 ms and p95 was 0.391 ms.
- **Identical retries** averaged 12,062 acknowledgments/s over 1,000 retries. Median latency was 0.078 ms and p95 was 0.087 ms. Both batches finished with 1,000 unique events, cursor 1,000 and balance 1,000.
- **Gap closure** took 23.932 ms for one delivery. Sequences 2 through 10,001 were already durable when the timer started. Sequence 1 applied all 10,000 buffered events and itself, leaving cursor, balance, and unique event count at 10,001.

This sample used one writer on an Apple M5 MacBook Air with 16 GB RAM, macOS 26.5.1, Ruby 2.6.10, SQLite 3.51.0, sqlite3 gem 1.3.13 and Bundler 1.17.2. A monotonic clock measures the in-process ledger call, including database open, schema check, commit and close. Ruby startup, JSON parsing, output, fixture setup and verification are outside the timer. End-to-end CLI latency and concurrent throughput were unmeasured. [Full observed results](benchmark/results.json)

## Setup and original demo

Tested on macOS arm64 with Ruby 3.4.13, Bundler 4.1.0, sqlite3 gem 2.10.2, and Minitest 5.27.0.

Run these commands from the project directory.

```sh
bundle check || bundle install
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
