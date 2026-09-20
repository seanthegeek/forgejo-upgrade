# forgejo-upgrade

A single Bash script that upgrades binary installs of
[Forgejo](https://forgejo.org) and
[forgejo-runner](https://code.forgejo.org/forgejo/runner) safely: it
[verifies the release signature and checksum](https://forgejo.org/download/#installation-from-binary),
backs up before touching anything, keeps the previous binary for rollback, and
checks that the service came back healthy. It upgrades whichever of the two is
installed on a given host — a host may run Forgejo, the runner, or both. The
runner is optional and is often installed on a separate host from Forgejo;
see [Contain the runner](docs/hardening.md#contain-the-runner) for why.

It exists because Forgejo has shipped a security release nearly every month of
2026, and a patch should take one command, not a checklist.

## Documentation

- [How the script works](docs/how-it-works.md): the step-by-step
  walkthrough of a server and runner upgrade.
- [Configuration](docs/configuration.md): every setting, where it is
  read from, and its default.
- [Hardening](docs/hardening.md): reducing what a compromise of Forgejo
  or the runner can reach.

## Installation

Fetch the latest release and copy it to each host that runs Forgejo or the
runner:

```bash
curl -qfsSLO https://github.com/seanthegeek/forgejo-upgrade/releases/latest/download/forgejo-upgrade.sh && sudo install -m 755 forgejo-upgrade.sh /usr/local/sbin/forgejo-upgrade
```

`-f` makes `curl` fail on an HTTP error instead of saving the error page as
the script, `-L` follows GitHub's redirect from `latest/download` to the
release asset (without it `-f` sees only the redirect and saves an empty
file), `-q` keeps a `~/.curlrc` out of it, `-S` still prints the error that
`-s` would otherwise hide, and `&&` installs only what was downloaded.

The script upgrades an existing install; it refuses to run when the binary it is
asked to upgrade is missing. Run `forgejo-upgrade version` at any time to see
which release is installed on a host.

Requirements: `bash`, `curl`, `gpg`, `runuser` (util-linux, present on every
systemd host) or `sudo`, `sed`, `grep`, GNU coreutils (`install`, `sha256sum`,
`mktemp`, `cp`, `date`, `stat`), and systemd (`systemctl`, `journalctl`). The
script must run as root because it stops services and writes to
[`/usr/local/bin`](https://forgejo.org/docs/latest/admin/installation/binary/#install-forgejo-and-git-create-git-user);
`runuser` or `sudo` is needed to run Forgejo's own commands as `FORGEJO_USER`
even though the script itself already runs as root.

PostgreSQL and MySQL installs also need their own database backup tooling
([`pg_dump`, `mysqldump`](https://forgejo.org/docs/latest/admin/upgrade/#backup))
kept up to date. The script does not run a native dump itself: doing so would
mean a new dependency, database credentials, and possibly a remote database
host, all inside the window the service is stopped for.

### Before the first upgrade

Run `sudo forgejo-upgrade settings` and read each line. Every value can be
overridden with the environment variable it is labelled with, except
`RUNNER_REG_FILE`, which the script derives from `RUNNER_HOME` and
`RUNNER_CONFIG` and does not read from the environment. See
[Configuration](docs/configuration.md) for what each of those variables
does and its default.

## Usage

| Command | Effect |
| --- | --- |
| `forgejo-upgrade check` | Print installed and latest versions of both components; a component that is not installed on this host shows as "not installed". |
| `forgejo-upgrade settings` | Print every setting an upgrade would use and where it came from, or one line saying a component is not installed instead of guessing its settings. Read-only; works without root. |
| `forgejo-upgrade forgejo <version\|latest>` | Upgrade the Forgejo server. |
| `forgejo-upgrade runner <version\|latest>` | Upgrade forgejo-runner. |
| `forgejo-upgrade rollback forgejo\|runner [--no-start]` | Stop, restore the previous binary, then start and confirm it is active — unless `--no-start` is given or [the major version changed](https://forgejo.org/docs/latest/admin/upgrade/#unexpected-database-version), in which case it leaves the service stopped and prints what to restore first. |
| `forgejo-upgrade version` | Print this script's own version and exit. |

Only one `forgejo`, `runner`, or `rollback` invocation runs at a time; a second
one stops at the lock held in `/run/forgejo-upgrade.lock`.

The step-by-step walkthrough of what each of those does is in
[How the script works](docs/how-it-works.md).

Check what is installed against what is published:

```bash
sudo forgejo-upgrade check
```

Apply a patch release:

```bash
sudo forgejo-upgrade forgejo 16.0.5
```

```bash
sudo forgejo-upgrade runner 13.1.0
```

If the server does not come back healthy:

```bash
sudo forgejo-upgrade rollback forgejo
```

Rollback works for patch releases because they normally do not change the
database schema. After a major upgrade,
[Forgejo refuses to start the older release](https://forgejo.org/docs/latest/admin/upgrade/#unexpected-database-version)
against the migrated database, so rollback deliberately leaves the service
stopped and tells you what to restore first: for SQLite, the dump zip in
[`BACKUP_DIR`](docs/configuration.md#forgejo-settings); for PostgreSQL or
MySQL, the native dump you took before the upgrade, because the zip's SQL
is not a safe restore — see Forgejo's own
[upgrade guide's Backup section](https://forgejo.org/docs/latest/admin/upgrade/#backup)
— then run `systemctl start` yourself. Pass `--no-start` to force that same
stopped-and-waiting behavior on any rollback, patch or major. Rollback does not
require the current binary to be intact — it only needs the `.prev` file, which
is what a failed install leaves behind. That file has to be a plain file — not
a symbolic link, not a directory — and it has to run and report a version the
script recognizes, all checked before anything is stopped; otherwise it is not
the binary an upgrade set aside and the rollback refuses.

### Knowing when to run it

Forgejo announces security releases about five days ahead in the
[security-announcements](https://codeberg.org/forgejo/security-announcements/issues)
repository. Subscribe to its
[RSS feed](https://codeberg.org/forgejo/security-announcements.rss) and run the
upgrade on release day. Stay on the LTS line unless you need a feature from the
current stable line, which
[goes end-of-life a few weeks after the next one ships](https://forgejo.org/docs/latest/admin/upgrade/#release-life-cycle).

## Development

The script must pass `shellcheck` with no findings, and the test suite must
pass. The suite uses [bats-core](https://github.com/bats-core/bats-core); the
tools are dev-only and are never needed on the Forgejo host:

```bash
sudo apt install bats kcov attr acl shellcheck
make lint        # shellcheck over the script, the helpers and every stub
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

## License

Apache License 2.0. See `LICENSE`.
