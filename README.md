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
