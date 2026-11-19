# Verification

The final source passed on macOS arm64 with Ruby 2.6.10, RubyGems 3.0.3.1, Bundler 1.17.2, sqlite3 gem 1.3.13, SQLite 3.51.0, Minitest 5.11.3, and Python 3.9.6.

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
