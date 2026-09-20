# Changelog

All notable changes to this project will be documented in this file.

The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-20

### Added

- `forgejo-upgrade.sh`, a single script that upgrades binary installs of
  Forgejo and forgejo-runner on a systemd host, treating each component as
  optional so a host can run either, both, or neither.
- Verification before anything is installed: the downloaded binary's GPG
  signature is checked against the pinned Forgejo release key (tolerating
  the release's rotating signing subkey) and its sha256 checksum, a
  tampered file is refused, and a missing key is refreshed from the
  keyserver and retried once before giving up.
- A backup (`forgejo dump`) taken after the service is stopped and before
  the binary is replaced, skippable with `SKIP_BACKUP` for hosts that back
  up some other way.
- A warning, read from `app.ini`'s `[database]` section before anything is
  stopped, when the database is not SQLite: `forgejo dump`'s zip holds an
  SQL copy that is not a safe restore, so a major-version upgrade's
  confirmation prompt is worded to require a native dump (`pg_dump`,
  `mysqldump`) taken first.
- The previous binary kept as `.prev`, with its file capabilities, ACL, and
  other extended attributes preserved, so `rollback` can restore it.
- `rollback`, which refuses to auto-start after a major-version upgrade
  (an older Forgejo will not start against a migrated database) and
  instead leaves the service stopped with instructions to restore a
  database backup first.
- A health check that requires exactly HTTP 200, so a reverse proxy
  redirecting to a login page is never mistaken for a healthy service.
- `check` and `settings`, read-only commands that show installed versus
  latest versions and every setting an upgrade would use, each read from
  the systemd unit and `app.ini` rather than assumed.
- A lock so only one `forgejo`, `runner`, or `rollback` run happens at a
  time on a host.
- A recovery message on any exit that leaves the service stopped: the
  journal output plus the exact `systemctl start` or `rollback` command
  to run next, with the run's own overrides and `sudo` prefix carried
  over.
- A check that `TMPDIR` allows execution, since a downloaded binary has to
  run once to report its version before it is installed.
- A bats test suite, split into an offline suite (`tests/unit`) and a live
  suite (`tests/live`) that exercises the real release API, keyserver, and
  a real runner download, with kcov line coverage of both.
- CI on GitHub Actions and Forgejo Actions running the lint, both test
  suites, coverage, and a markdownlint check on every pull request and
  push to `main`.
- Documentation split into `docs/how-it-works.md`, `docs/configuration.md`,
  and `docs/hardening.md`, linked from the README, with a test that every
  relative link between them resolves to a real file and, where given, a
  real heading.
- A `version` subcommand (and `--version`) printing this script's own
  version, and this changelog.

[Unreleased]: https://github.com/seanthegeek/forgejo-upgrade/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/seanthegeek/forgejo-upgrade/releases/tag/v0.1.0
