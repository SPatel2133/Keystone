# Shopify operations verification on Linux

Branch `devin/1795078530-shopify-operations`, based on `66ab683`. The machine was Linux x86_64 (8 vCPU Intel Xeon, kernel 6.8, 32 GiB) running Ruby 3.4.13, Bundler 4.1.0, SQLite 3.54.1 and the sqlite3 2.10.2 gem. Every database was disposable. The Shopify Admin API was the local synthetic GraphQL server, and no credentials or merchant data were used.

## Baseline before changes

`bin/check` passed 29 tests / 483 assertions, and `bin/shopify-check` passed 20 tests / 153 assertions. The demos and `test/whiteboard` exited 0.

## Final integrated run

The block in "Reproduce the integrated run" ran from a scratch directory whose path contained a space. The project was reached through a symlink with a space in its path. `BUNDLE_GEMFILE` and `RUBYOPT` were unset, and the bundle was frozen in an empty `BUNDLE_PATH`. `bin/shopify-ops-demo` and five repeats of the new operations, resumable-reconciliation and race tests were added to the run.

- `bin/check` passed **29 / 483**, and `bin/shopify-check` passed **37 / 378**. There were zero failures, errors or skips.
- Contention ran five times at 1 / 8 each. Maintenance passed 4 / 38. Seeds 1–10 passed 1 / 430. The Shopify operations, resume and race subset passed five times at 7 / 80 each.
- `bin/demo`, `bin/inventory-demo`, `bin/shopify-demo`, `bin/shopify-ops-demo`, `test/whiteboard`, both evidence commands and both benchmark modes exited 0. The caller ledger seeded with `1:+99` kept the same SHA-256.
- `bin/benchmark --full` on this machine ran 100,000 ordered events at 917 ack/s (p50 0.96 ms, p95 1.59 ms) and 100,000 identical retries at 6,516 ack/s (p50 0.13 ms). It closed a 10,000-event gap in 80 ms. Through the CLI with interpreter startup, p50 was 189 ms. Storage was 8.89 bytes per event. `benchmark/results.json` is still the macOS sample cited in the README.
- Hosted CI (`verify.yml`, Ubuntu 22.04) passed on PR #1. The workflow now also runs `bin/shopify-ops-demo`.

## Crash, retry and concurrency outcomes

- **Killed reconciliation.** A child reconciler was sent SIGKILL while it waited on page 2. The run stayed `running` with page 1 and its cursor durable. The next `bin/reconcile` resumed at that cursor, finished the window, then ran a fresh window. Totals were exact, and no transaction was duplicated.
- **Expired cursor.** When the first request with a saved cursor failed, the cursor was cleared and the next attempt rescanned from page one. Replayed pages were idempotent.
- **Concurrent reconcilers.** A second process ran to completion while the first was blocked mid-fetch. It resumed the same open run, then scanned a fresh window. The first process then finished without moving the checkpoint backwards. Both runs ended `completed` with two transactions.
- **Operator retry racing a worker.** An operator requeue happened during a failing Admin fetch. The worker's attempt-count guard discarded its stale failure update, so the delivery was neither parked nor double-counted (attempts 1, requeues 1).
- **Poison delivery.** After `max_attempts` the delivery was parked, and deliveries for other orders were still processed. Processed deliveries refuse `retry`.
- **Admin retries.** HTTP 429/5xx, `THROTTLED` and connection failures were retried within `api_attempts`, with `Retry-After` capped at 2 s. Permanent 4xx, malformed JSON and other GraphQL errors made exactly one request.
- **Migrations.** Legacy databases from each known version upgraded in one transaction. A forced failure on the final statement rolled back to the prior version, and the next open completed the upgrade. Pre-upgrade transactions report provenance `unknown`.

## Measured boundary: parked history

`ruby benchmark/shopify_operations.rb 50000` filled one shop's inbox with 50,000 parked rows, 50,000 processed rows and 1 eligible delivery.

| Query | Plan | Mean |
| --- | --- | --- |
| Worker selection with `inbox_eligible` partial index | index scan of unfinished, unparked rows | 0.02 ms |
| Same query through the older `inbox_ready` index | range search plus temporary B-tree sort | 5.9 ms |
| Full `bin/shopify-status` report for the shop | | 37 ms |

Without the partial index, worker selection cost grew with parked history. That finding is why the worker names `INDEXED BY inbox_eligible`: SQLite's planner chose `inbox_ready` without statistics.

## Concurrent workers

`bin/shopify-worker --drain` was run by 1, 2, 4 and 8 processes over 200 deliveries for 200 orders.

- **Before claims (found defect).** With an instant fake Admin API, totals were exact, but Admin fetches were 200, 314, 456 and 614. Workers raced on the same oldest row, and the loser's fetch was discarded. Wall time stayed about 0.8–1.1 s, so the extra workers gained nothing.
- **Before raising the worker's busy timeout (found defect).** Once claims added a write per selection, 4 and 8 workers sometimes hit `SQLite3::BusyException` at the 250 ms timeout. One worker stopped with `storage_error`, or a delivery was deferred 2 s after a wasted fetch. Raising the worker's timeout to 5 s fixed it. Three repeated runs at each worker count then succeeded with 200 fetches and net CAD 200.00.
- **After.** `ruby benchmark/shopify_drain.rb 200 50` uses a fake Admin API that answers in 50 ms.

| Workers | Admin fetches | Seconds | Deliveries/s |
| --- | --- | --- | --- |
| 1 | 200 | 11.14 | 17.9 |
| 2 | 200 | 5.61 | 35.6 |
| 4 | 200 | 2.92 | 68.5 |
| 8 | 200 | 1.63 | 122.8 |

`test/shopify/drain_test.rb` checks the following:
- Four concurrent drains over 40 deliveries apply each delivery once with exactly 40 fetches, and no claim is left over.
- A worker started mid-fetch finds nothing to claim.
- `--limit` and the exit codes behave as documented.
- The existing worker kill tests at both seams still recover immediately, because a dead claimant's claim is taken over.

## Webhook ingest under contention

`ruby benchmark/shopify_ingest.rb 400 8 W` sends 400 signed webhooks from 8 threads. A sender retries any non-200 response, as Shopify does. Meanwhile W `--drain` loops run against the same file.

| Drain workers | 200 | 503 `storage_busy` | Ack/s | p50 ms | p95 ms | Max ms |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 400 | 7 | 152.4 | 15.2 | 23.0 | 1,787 |
| 4 | 400 | 6 | 109.1 | 28.4 | 118.2 | 1,535 |

Every delivery was stored exactly once and processed, giving 400 transactions and net CAD 400.00. About 1.5–1.75% of attempts hit the webhook's 250 ms lock wait and got a retryable 503. That happened even with no workers running, so the senders were contending with each other under FULL synchronous commits. The slowest acknowledgment stayed well under Shopify's 5 s delivery timeout. A higher webhook ingest rate would need WAL mode or a server database. WAL was not adopted here because the documented durability and benchmark settings assume rollback-journal mode.

## Edge cases, fleet commands and setup

`test/shopify/operations_edge_test.rb` covers four edge cases:
- **Large and fractional amounts:** a 20-digit CAD sale, and BHD amounts with three and six decimal places, gave identical exact totals in summary, status and both audit modes.
- **Cross-shop isolation:** the delivery ID `shared` was reused by two shops. Listing, retry refusal, status, audit and parking each stayed within their shop.
- **Repeated page cursor:** a page whose next cursor repeats the current one fails the run, and the run is not saved past the last good page. It resumes once the API is fixed.
- **Corrupt currency:** a row with an invalid currency no longer makes `bin/shopify-audit` exit 1. The audit lists the row and reports `totals_error` (found defect).

`test/shopify/fleet_test.rb` checks two commands:
- `bin/reconcile --all` exits 1 when one shop's API returns HTTP 500. It still completes the healthy shop.
- `bin/shopify-status --prometheus` emits integer samples only, includes no money, and filters by shop.

`bin/setup` passed from a checkout path with a space and with `RUBYOPT=-w BUNDLE_GEMFILE=/nonexistent` in the caller's environment. Without Ruby on `PATH`, it exited 1 with an install hint.

## Online backup under writers

Five `bin/shopify-backup` copies were taken in sequence while 4 `--drain` workers processed 300 deliveries against a fake Admin API that answers in 10 ms. The copies captured 0, 11, 43, 73 and 105 processed deliveries. Each copy had exactly as many transactions as processed deliveries, and each passed `PRAGMA integrity_check`. `test/shopify/backup_test.rb` repeats this with 3 workers. It also checks that the command refuses to overwrite an existing file, rejects bad usage, and leaves no partial file.

## Long-running worker

`bin/shopify-worker --watch` processed a delivery that arrived after it started. On SIGTERM it exited 0 with `{"processed":1,"retry":0,"parked":0,"status":"stopped"}`. The test is `test_watch_processes_new_deliveries_and_stops_cleanly_on_sigterm`. Final local counts at this point: `bin/check` 29 / 483 and `bin/shopify-check` 50 / 620, with no failures, errors or skips.

## Same-order coalescing

`test_one_fetch_completes_earlier_deliveries_for_the_order_but_not_later_ones` sends three deliveries for one order and injects a fourth while the first fetch is in flight. The result was 2 Admin fetches, all 4 deliveries processed, and the exact final totals. The existing `test_duplicate_reversed_deliveries_and_shop_currency_isolation` now expects 2 fetches for 4 deliveries across two shops, down from 4. Cross-shop deliveries are never coalesced.

### Coalescing under a burst

`ruby benchmark/shopify_drain.rb 100 50 3` sends 100 orders × 3 interleaved updates (300 deliveries) with 50 ms of fake Admin latency. The "before" row ran the worker from `2bc8976`, before coalescing.

| Workers | Admin fetches before → after | Seconds before → after | Deliveries/s before → after |
| --- | --- | --- | --- |
| 1 | 300 → 100 | 17.23 → 5.96 | 17.4 → 50.3 |
| 2 | 300 → 101 | 8.70 → 3.14 | 34.5 → 95.5 |
| 4 | 300 → 103 | 4.64 → 1.69 | 64.6 → 177.5 |
| 8 | 300 → 106 | 2.35 → 1.13 | 127.7 → 266.1 |

All runs completed 300 of 300 deliveries with net CAD 100.00. With several workers, a few fetches are wasted. Claims are per delivery, so two workers can fetch the same order at once. The second worker's recheck then finds its delivery already completed and discards the result. These extra fetches cost no correctness.

## Randomized crash testing (bin/shopify-fuzz)

| Run | Operations | Failures | Time |
| --- | --- | --- | --- |
| `bin/shopify-fuzz --seed 100000 --runs 2000 --steps 300` | 600,000 | 0 | 3,114 s (51 min 54 s wall), max RSS 227 MB |
| `--seed 1000 --runs 100 --steps 300` | 30,000 | 0 | 150 s |
| CI fixed seeds: 25 × 200 in process, 3 × 60 with `--processes` | 5,180 | 0 | about 30 s |

The 2,000-run campaign included 19,940 crashes before commit and 20,338 after commit. It also included 20,090 claims left by dead workers, 40,469 Admin faults, 20,161 reconciliation runs with a failing page, 6,799 backups checked against the oracle, and 6,656 maintenance runs.

- **Oracle check:** a planted wrong stored amount is reported, and the operation list is shrunk until the planted operation is last.
- **Harness issue found and fixed:** with `--processes`, a SIGKILLed worker can leave a hot rollback journal. A `readonly: true` reader then raises `SQLite3::ReadOnlyException`. The checker now uses a writable connection.
- **No ledger bug was found.**

## Payment domain

`test/shopify/payment_domain_test.rb` adds 7 tests. With them, `bin/check` passes 29 runs / 483 assertions and `bin/shopify-check` passes 66 runs / 732 assertions, with no failures.

Mutation check of the extended fuzzer (5 runs × 200 steps, seed 1):

| Mutant | Result |
| --- | --- |
| Count `PENDING` payments as money | Caught; shrunk to 1 operation |
| Statuses never update | Caught at settle; shrunk to 3 operations |
| Remove the stale-read guard | Not caught. It only causes retries, not wrong data. |
| Overwrite presentment money on every fetch | Not caught, as expected: it changes nothing |

## PostgreSQL workers

Locally against Docker `postgres:16-alpine`, `test/shopify/postgres_test.rb` passes 4 runs / 69 assertions:
- Four workers with different machine IDs drain 40 deliveries with 50 ms Admin latency. That takes exactly 40 Admin fetches, and the total is `830.00`.
- Workers SIGKILLed before and after commit leave exactly one payment.
- Admin 500s back off and then park the delivery.

Hosted CI ran it against the `postgres:16` service container: `bin/shopify-check` passed 70 runs / 801 assertions with 0 skips.

## Shop routing and moves

`test/shopify/shop_routing_test.rb` passes 8 tests. With them, `bin/shopify-check` passes 78 runs / 880 assertions (with PostgreSQL).

The fuzzer's `move_shop` operation crashes after the copy or after the switch. In a 30 runs × 200 steps run (seed 1, including 174 moves) it found two bugs. A regression test was written before each fix:
1. Cleanup refused, forever, a stale orphan copy left by a crash after the copy.
2. A worker draining a database that a shop had left processed the stale copy's deliveries.

After the fixes, the same run had 0 failures in 27 s.

## Fuzzing the PostgreSQL worker

| Run | Operations | Failures | Time |
| --- | --- | --- | --- |
| `bin/shopify-fuzz --postgres --seed 300000 --runs 500 --steps 300` | 150,000 | 0 | 330.8 s |
| `--postgres --processes --seed 100 --runs 20 --steps 150` (52 concurrent multi-machine drains, 72 workers SIGKILLed mid-fetch) | 3,000 | 0 | 42.8 s |
| `--postgres --seed 400000 --runs 500 --steps 300`, after reconciliation was ported (7,522 reconciles, 4,492 with a failing page) | 150,000 | 0 | 585.7 s |

## Full-feature SQLite campaign

`bin/shopify-fuzz --seed 500000 --runs 1000 --steps 300` was run at the hardening head. Its operations include shop moves, crashing at either seam (9,022), real Admin read timeouts, every payment kind and status, stale Admin reads (9,205) and reconciliation runs with a failing page (9,079). It performed 300,000 operations with 0 failures in 1,841.5 s (30 min 42 s wall), with a max RSS of 188 MB.

`bin/shopify-fuzz --processes --seed 600000 --runs 100 --steps 300` performed 30,000 operations with 0 failures in 366.9 s. They included 554 rounds of 2–4 concurrent `--drain` processes, 594 workers SIGKILLed mid-fetch and 913 shop moves.

`bin/shopify-fuzz --postgres --processes --seed 700000 --runs 100 --steps 300` performed 30,000 operations with 0 failures in 498.0 s. They included 588 rounds of concurrent multi-machine `bin/shopify-pg-worker --drain` processes, 567 workers SIGKILLed mid-fetch and 1,433 reconciliations.

## Fresh-clone run of the hardening branch

`~/sprint/final.sh` was run against a fresh clone of `devin/1795087967-shopify-hardening` (3f5bb2d) in a path that contains a space. It ran `bin/check`, `bin/shopify-check` (with the PostgreSQL tests skipped, since no URL was set), repeated race tests, `bin/setup`, every demo (including the new ops-demo step 9), the whiteboard, both benchmark modes, both evidence commands, and the drain and ingest benchmarks. Afterwards the caller's ledger SHA was unchanged, and the script exited with `FINAL_EXIT=0`.

The first attempt failed in `bin/shopify-demo --evidence`, with `Errno::EISDIR` on the new `test/support/shopify_fuzz/` directory. The evidence digest now covers nested source files and skips directories, and CI now runs that command too.

## Found in review (PostgreSQL)

Each bug got a regression test, which failed before its fix:
- **`PG::UniqueViolation`** when two PostgreSQL workers apply the same order concurrently. Inserts are now `ON CONFLICT DO NOTHING RETURNING 1`, followed by a comparison with the winner's row.
- **NULL `last_attempt_at`** on PostgreSQL completion.

Afterwards, `bin/shopify-check` passed 88 runs / 948 assertions, and `--postgres --processes --seed 21 --runs 10 --steps 150` had 0 failures.

## Found by fuzzer (PostgreSQL deadlock)

The PostgreSQL fuzzer now runs two workers at once on separate connections on every third worker step. With that change, `--postgres --seed 31 --runs 20 --steps 200` hung.

`test_concurrent_workers_on_the_same_orders_never_deadlock` uses 4 threads on 20 orders × 3 deliveries. It raised `PG::TRDeadlockDetected` in 3 of 3 runs before the fix. Completion locked only its own inbox row, then updated the other same-order rows. It now locks every same-order row up to the fence in ID order first.

As a mutation check, I reverted only the lock-ordering fix and ran seeds 31–50 (200 steps each) one by one. 11 of the 20 failed with `concurrent worker raised PG::TRDeadlockDetected`, each within 1–2.3 s, and the fix was then restored. The original campaign "hang" was shrinking working through many failing runs. Runs are now also bounded by `SHOPIFY_FUZZ_RUN_TIMEOUT` (default 120 s).

A longer campaign after the fix, `--postgres --seed 800000 --runs 300 --steps 300` with concurrent workers, performed 90,000 operations with 0 failures in 666.9 s.

After the fix, the test passed 3 of 3 runs, the seed-31 campaign had 0 failures in 31.3 s, and `bin/shopify-check` passed 89 runs / 950 assertions.

## Drain throughput: SQLite and PostgreSQL

`ruby benchmark/shopify_drain.rb ORDERS 50 UPDATES [sqlite|postgres]` uses a fake Admin API that adds 50 ms of latency. Local Docker `postgres:16-alpine` was used, and a fuzz campaign was running on the same machine at the time.

| Backend, deliveries | 1 worker | 2 workers | 4 workers | 8 workers | Admin fetches (1/2/4/8 workers) |
| --- | --- | --- | --- | --- | --- |
| SQLite, 200 orders × 1 update | 17.2/s | 33.3/s | 57.6/s | 115.9/s | 200 / 200 / 200 / 200 |
| PostgreSQL, 200 orders × 1 update | 17.6/s | 34.5/s | 65.1/s | 117.5/s | 200 / 200 / 200 / 200 |
| PostgreSQL, 100 orders × 3 updates (coalescing) | 50.8/s | 99.2/s | 171.3/s | 278.3/s | 100 / 100 / 102 / 108 |

Every run completed all deliveries with the exact expected net. Throughput is limited by Admin latency, not by the database.

## Not run

PostgreSQL, multi-host workers, and a real Shopify store or tunnel were not run. Operational logs were checked for shape only. No log shipping or alerting was configured.

# Local verification on Ruby 3.4

The baseline was GitHub commit `b648d7c`. The project directory initially belonged to an unrelated, uncommitted parent workspace. Its files matched a fresh clone of the published project. The project now has its own checkout and forward-only local branch, `codex/recovery-verification`. The published runtime migration already pinned Ruby 3.4.13 and supplied a lockfile for macOS ARM and Linux x86-64 GNU.

## Baseline

From a new directory with `BUNDLE_GEMFILE` and `RUBYOPT` unset, ran `"$project/bin/check"` (22 tests, 300 assertions), `"$project/bin/shopify-check"` (20 tests, 153 assertions), `"$project/bin/demo"`, `"$project/bin/inventory-demo"`, and `"$project/bin/shopify-demo"`. All passed. There were zero failures, errors, or skips. Both ledger crash seams produced signal 9 with empty stdout; inventory closed at 25 units and the Shopify demo closed at CAD 75.00.

## Reproduce the integrated run

Start in the project checkout with the Ruby in `.ruby-version` active. All databases below are disposable. Copying the three dependency input files makes the clean installation independent of checkout-local Bundler configuration.

```sh
set -eu
project="$PWD"
scratch="$(mktemp -d)"
unset RUBYOPT BUNDLE_GEMFILE
export BUNDLE_FROZEN=true BUNDLE_PATH="$scratch/bundle" BUNDLE_APP_CONFIG="$scratch/bundle-config"
mkdir "$scratch/setup" "$scratch/caller"
cp Gemfile Gemfile.lock .ruby-version "$scratch/setup/"
(cd "$scratch/setup" && bundle install && bundle check)
cd "$scratch/caller"
printf '%s\n' '{"op":"deliver","seq":1,"delta":99}' | "$project/bin/ledger"
shasum -a 256 ledger.sqlite3 > "$scratch/caller.sha"
"$project/bin/check"
"$project/bin/shopify-check"
for repeat in 1 2 3 4 5; do "$project/bin/check" -n /concurrent_delivery/; done
"$project/bin/check" -n /MaintenanceTest/
"$project/bin/check" -n /seeded_delivery/
LEDGER_SEEDS=1,2,3,4,5,6,7,8,9,10 "$project/bin/check" -n /seeded_delivery/
"$project/bin/demo"
"$project/bin/inventory-demo"
"$project/bin/shopify-demo"
"$project/test/whiteboard"
"$project/bin/benchmark" --smoke > "$scratch/smoke.json"
"$project/bin/benchmark" --full > "$scratch/full.json"
"$project/bin/demo" --evidence > "$scratch/evidence.jsonl"
"$project/bin/shopify-demo" --evidence > "$scratch/shopify-evidence.jsonl"
shasum -a 256 -c "$scratch/caller.sha"
```

## Results and failure log

- Clean frozen install on macOS arm64 loaded Ruby 3.4.13, Bundler 4.1.0, SQLite 3.54.1, sqlite3 gem 2.10.2 (native arm64-darwin), Minitest 5.27.0, WEBrick 1.9.2, BigDecimal 4.1.3 and Base64 0.3.0. The verified Ruby executable was `/opt/homebrew/Cellar/ruby@3.4/3.4.13/bin/ruby`. The lockfile also includes x86_64-linux-gnu. Ubuntu 22.04 x64 is configured; its [Ruby build artifact](https://github.com/ruby/ruby-builder/releases/download/ruby-3.4.13/ruby-3.4.13-ubuntu-22.04-x64.tar.gz) was available. Hosted execution for the local commit is unrun.
- Final integrated workflow on macOS: original and extended suite **29 tests / 483 assertions**; Shopify **20 / 153**. Zero failures, errors, or skips. The workflow shell body was extracted from YAML, syntax-checked with Bash, and executed with the clean bundle. Actionlint 1.7.12 also validated the workflow.
- Five focused contention runs passed (1 test / 8 assertions each). Every reservation forced five real busy receipts with no partial write. Default randomized seeds passed 1 / 129; seeds 1–10 passed 1 / 430. Maintenance passed 4 / 38. These focused counts repeat coverage included in the integrated suites.
- `bin/demo`, `bin/inventory-demo`, `bin/shopify-demo`, `test/whiteboard`, both evidence commands, and both benchmark modes passed. A real scratch caller ledger seeded with `1:+99` had the same SHA-256 before and after. The demo and benchmark commands also completed from a caller directory with spaces in the checkout path.
- **Harness defect during development.** `bin/check -n /concurrent_delivery/` initially produced EACCES instead of a receipt when the executable path contained a space. Passing an explicit executable/argv pair to Open3 fixed invocation. The five repeated checks above passed.
- **Deliberate transaction failure.** `test/whiteboard` creates its own broken project copy. Its rollback assertion expected rows 1 and 3 but observed 1, 2 and 3 with checkpoint `(1,"5")`. Replay returned duplicate with balance 5. The intact executable passed the identical assertion; replay was accepted with balance 6. [Interview walkthrough](docs/interview.md)
- **Deliberate history loss.** `bin/check -n /pruning_an_applied_row/` deletes applied identity `1:+10` only in a scratch fixture. Submitting `1:-99` then returns accepted and retains the stale balance 10. The maintenance implementation retains every row; matching and conflicting retries survived VACUUM unchanged.
- **Ranked follow-up checks.** (1) False acknowledgment after simultaneous replay: after losing the receipt for `2:-1`, race two matching senders against `2:-9`. Five independent trials returned two duplicates and one conflict, and separate SQLite reads retained balance 6. (2) Integer overflow on gap closure: with 1 and 3 both at INT64_MAX, deliver `2:+1` at both seams. Final balance was exactly 18,446,744,073,709,551,615. (3) Measurement and setup: the public CLI benchmark includes interpreter startup, full duplicate replay preserves 100,000 identities, and installation from an empty bundle succeeded. These probes found no additional production defect.
- The local gem was built from an explicit four-file allowlist, installed in an empty GEM_HOME with the locked sqlite3 gem, and invoked from an unrelated directory. Actual receipts were accepted/accepted/accepted/duplicate/conflict with a final balance of 6. The gem was not published. PostgreSQL implementation and backend equivalence checks are unrun.

## Reproduce the isolated gem install

After the clean bundle installation above, run:

```sh
cd "$project"
gem build sequence-ledger.gemspec --output "$scratch/sequence-ledger.gem"
export GEM_HOME="$scratch/gem-home" GEM_PATH="$scratch/gem-home"
gem install --local "$BUNDLE_PATH"/ruby/3.4.0/cache/sqlite3-*.gem "$scratch/sequence-ledger.gem" --no-document
gem contents sequence-ledger
mkdir "$scratch/gem-caller"
cd "$scratch/gem-caller"
printf '%s\n' '{"op":"deliver","seq":1,"delta":5}' | "$GEM_HOME/bin/sequence-ledger"
```

## Repository metadata draft

The public repository description observed during this run was “A crash-safe local event consumer in Ruby and SQLite.” Its default branch was `main` and its topic list was empty. Proposed description: “Ruby and SQLite event consumers for crash-safe inventory updates and Shopify order and refund reconciliation.” Proposed topics: `ruby`, `sqlite`, `shopify`, `idempotency`, `webhooks`, `fault-tolerance`. This run did not publish commits, open a PR, or change public metadata.

# Historical verification on Ruby 2.6

The earlier release passed on macOS arm64 with Ruby 2.6.10, RubyGems 3.0.3.1, Bundler 1.17.2, sqlite3 gem 1.3.13, SQLite 3.51.0, Minitest 5.11.3, and Python 3.9.6.

## Setup and local checks

`bundle check` passed with the available system gems. In a separate project copy with an empty bundle directory, `bundle install --local --deployment --path vendor/bundle` installed the two locked gem archives from `vendor/cache`, including the native SQLite extension. The loaded gems resolved to that local bundle. A full run with those dependencies also passed all 15 tests and 221 assertions. The subsequent Shopify release check below also installed the locked gems directly from RubyGems.

The following release commands were run from a fresh, unrelated directory, with `BUNDLE_GEMFILE` and `RUBYOPT` unset for each executable. Set `project` from the project directory first.

```sh
project="$PWD"
cd "$(mktemp -d)"
env -u BUNDLE_GEMFILE -u RUBYOPT "$project/bin/check"
env -u BUNDLE_GEMFILE -u RUBYOPT "$project/bin/check" --name test_before_commit
env -u BUNDLE_GEMFILE -u RUBYOPT "$project/bin/check" --name test_after_commit_before_ack
env -u BUNDLE_GEMFILE -u RUBYOPT "$project/bin/demo"
env -u BUNDLE_GEMFILE -u RUBYOPT "$project/bin/demo" --evidence > evidence.jsonl
```

- The full suite passed 15 tests and 221 assertions with zero failures, errors, or skips. It covers all six permutations against an independent prefix oracle and verifies busy responses, unchanged storage, and a successful retry with both an independent writer and an independent reader.
- Each isolated crash test passed six assertions. Both children died by SIGKILL (signal 9) and wrote zero stdout bytes. Before the pre-commit retry, SQLite held rows `(1,5), (3,2)` and checkpoint `(1,"5")`. The retry returned `{"status":"accepted","seq":2,"cursor":3,"balance":6}`.
- Before the post-commit retry, SQLite held rows `(1,5), (2,-1), (3,2)` and checkpoint `(3,"6")`. The retry returned `{"status":"duplicate","seq":2,"cursor":3,"balance":6}`. Both cases then rejected a conflicting delta for sequence 3 and preserved the stored rows and checkpoint.
- The demo completed in about 1.5 seconds. The oracle and ledger both calculated 6 for the 1, 3, 2 feed. The naive last-seen rule calculated 7. The demo and evidence command left the fresh invocation directory free of ledger files. A separate demo run preserved a pre-existing caller file named `ledger.sqlite3` byte for byte. [Machine-generated evidence](evidence.jsonl)
- In two other unrelated directories, the absolute production and hook entry paths produced independent databases. A direct SQL read showed only `(3,2)` in the first and only `(1,5)` in the second.

## Independent release checks

- The Python block from `final2.md` was copied unchanged to a temporary `embedded_acceptance.py`. The command `python3 -E "$release_check/embedded_acceptance.py" "$project/test/support/ledger-with-hooks"` reported `before_commit passed` and `after_commit_before_ack passed`.
- The historical `November project selection/acceptance.py` matched SHA-256 `4e0adc82ed78df738a2305d907aaf00d98a75416a325971aaed392e02ae6af3d`. The unchanged script passed `python3 -E "$historical" K4 "$project/test/support/ledger-with-hooks"` with exit 0. Its post-commit replay returned `duplicate` at cursor 3, balance 6.

## Failures corrected during the build

- The first standalone checkpoint probe expected the old pair `[1,"5"]` after the pre-commit kill. It got a SQLite connection object because the gem constructor returns the connection even with a block. Capturing the query result inside the block fixed the probe. Both seams passed in `bin/check --name test_actual_process_harness` and in the full suite.
- `bin/check --name test_valid_escaped_string_and_json_whitespace` expected a state response, but Ruby split the executable path at the space in the parent directory and raised `EACCES`. Passing an explicit executable and argument zero to the process launcher fixed it. The focused test and full suite passed on rerun.
- `bundle install --local` attempted to create a lock in the protected system gem directory. The local deployment install above used a writable, empty bundle directory and passed without modifying system gems.

## Shopify verification

The release check downloaded both locked gems from RubyGems into a fresh project
copy with `BUNDLE_FROZEN=true bundle install --deployment`. It built the native
SQLite extension and ran
the commands from the workflow's test step on macOS arm64 with Ruby 2.6.10,
Bundler 1.17.2, sqlite3 1.3.13, and SQLite 3.51.0.

Set `project="$PWD"` from the project root to rerun the checks from a fresh
working directory.

```sh
project="$PWD"
cd "$(mktemp -d)"
env -u BUNDLE_GEMFILE -u RUBYOPT "$project/bin/check"
env -u BUNDLE_GEMFILE -u RUBYOPT "$project/bin/shopify-check"
env -u BUNDLE_GEMFILE -u RUBYOPT "$project/bin/shopify-demo"
for check in test_before_commit test_after_commit test_lost_webhook_ack \
  test_reconciliation_retry test_missed_webhook \
  test_reconciliation_preserves_newer_checkpoint_written_during_fetch; do
  env -u BUNDLE_GEMFILE -u RUBYOPT "$project/bin/shopify-check" --name "$check"
done
env -u BUNDLE_GEMFILE -u RUBYOPT "$project/bin/shopify-demo" --evidence > shopify-evidence.jsonl
```

- The original suite passed 15 tests and 221 assertions. The Shopify suite passed 20 tests and 153 assertions. Both had zero failures, errors, or skips.
- Both worker crash children died with signal 9 and zero stdout bytes. Each isolated run passed five assertions. Before the pre-commit restart, SQLite held only the sale and the refund delivery was pending. Before the post-commit restart, SQLite held one refund and marked the delivery processed. The first restart processed the refund. The second restart was idle. Both reported CAD 100.00 collected, CAD 25.00 refunded, and CAD 75.00 net.
- The lost acknowledgment replay returned HTTP 200 and left one inbox row. Reconciliation repaired the missed refund from CAD 100.00 to CAD 75.00 net. A simulated page-two HTTP 503 kept the old checkpoint, and a retry revisited page one without duplicating a payment. An isolated checkpoint race test preserved the newer checkpoint.
- The [machine-generated trace](shopify-evidence.jsonl) captures the durable rows, worker exits, summaries, webhook retry, and reconciliation requests. The demo and evidence command left the scratch working directory free of ledger files.

The first sandboxed demo failed to bind a localhost TCP socket. Localhost
execution succeeded with approval. The first integrated payment demo then
expected a processed sale but returned retry because SQLite received the
formatted amount as a BLOB. A direct `SELECT typeof(?)` reproduced the binding
issue. The signed webhook tests also exposed SQLite BLOB bindings for binary
HTTP metadata. Both fixes normalize the affected values to UTF-8 before binding.
The demo and focused tests passed on rerun.

The [pull-request workflow](.github/workflows/verify.yml) passed local YAML
parsing and Bash syntax checks. Its test step ran locally. The Ubuntu runner
and GitHub Actions were unavailable for this local-only release check.

### Ranked audit results

1. **Missed payments and incorrect totals.** A failed first reconciliation shifted its lower bound on retry and skipped an eligible refund. The first window now survives retries. A foreign database containing duplicate rows previously reported twice the payment. The CLI now rejects incompatible application tables and upgrades the known earlier schema.
2. **Currency and delivery identity.** The earlier parser accepted a fictitious currency. The worker now defers that delivery. For existing affected rows, the summary exits with a diagnostic. Reconciliation repairs the currency only when the authoritative transaction matches the recorded shop, transaction, order, kind, and amount. A conflicting delivery ID previously received HTTP 200. It now receives HTTP 409.
3. **Stalled work.** A corrupt compressed HTTP response kept the oldest delivery eligible after failure. It now receives retry backoff. In a two-worker race, the loser used to return idle while another order waited. It now selects the next eligible delivery.
4. **Demo and release evidence.** The terminal demo prints the durable sale, refund, and inbox status before each restart. The page-two failure fixture starts with an older checkpoint so premature advancement is observable even when the entire test finishes in one second.

All reproduced issues above have passing regression coverage. Both independent Python checks for the original CLI also passed after integration.

## Inventory, diagnostics and benchmark

Baseline: 15 original tests (221 assertions) and 20 Shopify tests (153 assertions). Final: `bin/check` passed 22 tests (300 assertions) including the seven new tests, and `bin/shopify-check` passed 20 tests (153 assertions). Zero failures, errors, or skips.

Ranked probes, all closed:

1. Incorrect stock or double application. Two runs from a directory with independent stock adjustments returned the same duplicate receipt and 25 units. The killed child emitted zero stdout bytes. A separate SQLite reader observed all three events before replay.
2. Misleading gap-closure timing. An independent call-count probe attributed 1,000 timed calls to each batch and one to gap closure. The 10,000 buffering calls happened before its timer.
3. Inconsistent diagnostics or writes. An uncommitted writer was invisible to doctor. A sparse maximum sequence used an integer primary-key range search. A WAL probe exposed a generic open failure, now reported explicitly without creating sidecars. The missing-file check created nothing. After both suites, doctor, inventory demo and full benchmark, the caller's pre-existing stalled database compared byte-for-byte equal to its backup.

To reproduce, run the reviewer walkthrough in README, followed by `"$project/bin/check"`, `"$project/bin/shopify-check"`, and `"$project/bin/benchmark"`. The measured output is in [benchmark/results.json](benchmark/results.json).
