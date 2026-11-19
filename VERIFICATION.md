# Verification

The final source passed on macOS arm64 with Ruby 2.6.10, RubyGems 3.0.3.1, Bundler 1.17.2, sqlite3 gem 1.3.13, SQLite 3.51.0, Minitest 5.11.3, and Python 3.9.6.

## Setup and local checks

`bundle check` passed with the available system gems. In a separate project copy with an empty bundle directory, `bundle install --local --deployment --path vendor/bundle` installed the two locked gem archives from `vendor/cache`, including the native SQLite extension. The loaded gems resolved to that local bundle. A full run with those dependencies also passed all 15 tests and 221 assertions. Linux and installation directly from RubyGems were untested.

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
