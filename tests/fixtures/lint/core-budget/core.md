# Core

- Compile the parser from a clean checkout before trusting any green test run.
- Migrate the database on a copy first, then compare row counts by hand.
- Deploy only after the staging smoke check passes and the rollback command is written down.
- Benchmark with the real dataset because synthetic inputs hide the slow paths.
- Profile the scheduler before rewriting it, since guesses about hot loops are usually wrong.
- Refactor in small commits so a reviewer can follow each renamed function.
- Package the exporter with pinned versions to keep reinstalls reproducible.
- Document every environment variable next to the code that reads it.
