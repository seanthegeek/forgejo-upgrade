# Development

The script must pass `shellcheck` with no findings, and the test suite must
pass. The suite uses [bats-core](https://github.com/bats-core/bats-core); the
tools are dev-only and are never needed on the Forgejo host:

```bash
sudo apt install bats kcov attr acl shellcheck
make lint        # shellcheck over the script, the helpers, the link checker and every stub
make test        # the offline suite in tests/unit, no network
make test-live   # tests/live: downloads a real runner release and verifies it
make links       # check every https:// URL in the docs and script (network)
make coverage    # kcov line coverage of the offline suite
```

The suite needs bats 1.5.0 or later. Ubuntu 24.04 has no `kcov` package —
it is in 22.04 and again from 25.04 on — so leave `kcov` out of that line
there; `make lint` and `make test` work without it, and CI measures
coverage. Ubuntu 22.04 ships bats 1.2.1, too old for the suite: install the
rest from apt, clone [bats-core](https://github.com/bats-core/bats-core),
and run the targets with `BATS=/path/to/bats-core/bin/bats`.

`make test-live` is the verification path: it downloads
[a real release](https://code.forgejo.org/forgejo/runner/releases), checks its
signature and checksum, and proves a tampered copy is rejected. Both suites
run in CI on every pull request and on every push to `main`. See `AGENTS.md`
for how the suite is laid out, the conventions, and the facts about Forgejo's
release artifacts that the script depends on.
