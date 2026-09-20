# Configuration

Every setting is resolved in this order: an environment variable the operator
set, then a value read from the systemd unit or `app.ini`, then
[a documented default](https://forgejo.org/docs/latest/admin/config-cheat-sheet/).
Resolution happens before anything is stopped, and `forgejo-upgrade settings`
prints every value together with which of those three places it came from. Any
path override must be given as an absolute path, because the checks before the
stop and the commands after it can otherwise resolve it against two different
directories.

A component counts as installed when its systemd unit is loaded, its resolved
binary is executable, or the operator set its service or binary variable
(`FORGEJO_SERVICE`/`FORGEJO_BIN`, `RUNNER_SERVICE`/`RUNNER_BIN`). Otherwise
`settings` prints one line saying so instead of a guessed settings block, and
`check` prints "not installed" with "-" for the latest version instead of asking
[the release API](https://code.forgejo.org/api/swagger#/repository/repoGetLatestRelease)
about it.

The download and its signature go into a directory made under `TMPDIR`, which
defaults to `/tmp`. The downloaded binary is run from there once, to check
which version it really is before it is installed, so on a host whose `/tmp` is
mounted `noexec` set `TMPDIR` to a directory on a filesystem that allows
execution. `sudo` passes `TMPDIR` through only when it is given on `sudo`'s own
command line:

```sh
sudo TMPDIR=/var/tmp forgejo-upgrade forgejo latest
```

## Forgejo settings

| Variable | Read from | Default |
| --- | --- | --- |
| `FORGEJO_SERVICE` | — | `forgejo` |
| `FORGEJO_BIN` | `ExecStart=` program; a loaded unit whose `ExecStart=` cannot be read back stops `forgejo` and `rollback` and warns in `settings` rather than falling back to the default | [`/usr/local/bin/forgejo`](https://forgejo.org/docs/latest/admin/installation/binary/#install-forgejo-and-git-create-git-user) |
| `FORGEJO_USER` | `User=` | `root` for a loaded unit that sets no `User=` ([systemd's default](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#User=)); [`git`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/contrib/systemd/forgejo.service#L56) only when the unit is not found |
| `FORGEJO_CONFIG` | `--config`/`-c` in `ExecStart=` (relative to `WorkingDirectory=`, or `/` if unset) | [Forgejo's own default](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/path.go#L93-L207): `<work path>/custom/conf/app.ini`, work path from `--work-path` or `Environment=` (`FORGEJO_WORK_DIR`/`GITEA_WORK_DIR`), else the binary's directory; `custom` is assumed since `FORGEJO_CUSTOM`/`--custom-path` are not read; [`/etc/forgejo/app.ini`](https://forgejo.org/docs/latest/admin/installation/binary/#create-directories-forgejo-will-use) only if the unit is not found |
| `FORGEJO_WORK_PATH` | `--work-path`/`-w` in `ExecStart=`, then `FORGEJO_WORK_DIR`/`GITEA_WORK_DIR` in `Environment=` (the flag wins, [as it does for Forgejo](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/path.go#L177-L178)), then [`WORK_PATH` in `app.ini`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#overall-default), which replaces the unit's value when set; `WorkingDirectory=` is not consulted; a relative value from any of these sources is refused, because Forgejo itself [refuses to start on one](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/path.go#L157) (`settings` warns, `forgejo` and `rollback` stop); a unit value and an `app.ini` value naming the same directory through different paths [are not a conflict](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/path.go#L195-L199) | unset; Forgejo then uses the directory holding the binary, with a warning |
| `FORGEJO_URL` | `[server]` in `app.ini`: [`LOCAL_ROOT_URL`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#server-server) if set, with `%(NAME)s` references expanded [as Forgejo does](https://github.com/go-ini/ini/blob/v1.67.3/key.go#L142-L176), else `PROTOCOL`/`HTTP_ADDR`/`HTTP_PORT` (`0.0.0.0` becomes `localhost`); with `http+unix` the URL is `http://unix` and curl dials `FORGEJO_SOCKET` | `http://127.0.0.1:3000` |
| `FORGEJO_SOCKET` | `HTTP_ADDR` in `[server]` when `PROTOCOL` is `http+unix`, whatever `LOCAL_ROOT_URL` says, because that is [the socket Forgejo itself dials](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/private/internal.go#L56) | unset |
| `FORGEJO_DB_TYPE` | [`DB_TYPE` in `[database]`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#database-database) | unset (unknown) when the config cannot be read |
| `BACKUP_DIR` | — | `/var/backups/forgejo` |
| `SKIP_BACKUP` | — | `0` |

`FORGEJO_DB_TYPE` decides what the backup step and the rollback messages say:
the `forgejo dump` zip always carries an SQL copy of the database, but only for
SQLite is that copy a usable restore; for PostgreSQL and MySQL,
[Forgejo's own guide](https://forgejo.org/docs/latest/admin/upgrade/#backup)
says to restore from a native dump instead. An unreadable config is treated as
external out of caution.

The unit's `Environment=` entries are passed to every Forgejo CLI call the
script makes. Those calls run as `FORGEJO_USER` — via `runuser`, falling back to
`sudo` if `runuser` is not on `PATH` — from the resolved work path, with
`--config` and `--work-path` given explicitly
[before the subcommand](https://forgejo.org/docs/latest/admin/command-line/#forgejo---help).

A `FORGEJO_WORK_PATH` override must agree with `WORK_PATH` in `app.ini` when
that is set.
[Forgejo follows `app.ini` and ignores `--work-path`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/path.go#L189-L202),
so a conflicting override could never take effect; the script refuses it before
anything is stopped rather than claim in `settings` that it will.

If
[`PROTOCOL` in `app.ini`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#server-server)
is `https`, `fcgi`, or `fcgi+unix`, the script refuses to guess an address and
dies before stopping anything, asking for `FORGEJO_URL` — a URL that answers
`/api/healthz` with HTTP 200, such as
[the reverse proxy](https://forgejo.org/docs/latest/admin/setup/reverse-proxy/)
in front of Forgejo.

## Runner settings

| Variable | Read from | Default |
| --- | --- | --- |
| `RUNNER_SERVICE` | — | `forgejo-runner` |
| `RUNNER_BIN` | `ExecStart=` program; a loaded unit whose `ExecStart=` cannot be read back stops `runner` and `rollback` and warns in `settings` rather than falling back to the default | [`/usr/local/bin/forgejo-runner`](https://forgejo.org/docs/latest/admin/actions/installation/binary/#downloading-and-installing-the-binary) |
| `RUNNER_HOME` | `WorkingDirectory=` | `/` for a loaded unit that sets no `WorkingDirectory=` ([systemd's default](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#WorkingDirectory=)); [`/home/runner`](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/contrib/forgejo-runner.service#L12) only when the unit is not found |
| `RUNNER_CONFIG` | [`-c`/`--config` in `ExecStart=`](https://forgejo.org/docs/latest/admin/actions/installation/binary/#configuration) | unset; the guide says "There is no default configuration file location", so the script has no fallback |

The registration file the runner already holds is
[`runner.file`](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/internal/pkg/config/config.example.yaml#L23)
from `RUNNER_CONFIG` (a relative path there is
[under `RUNNER_HOME`](https://forgejo.org/docs/latest/admin/actions/installation/binary/#starting-the-runner)),
or else `$RUNNER_HOME/.runner`. A missing file only warns; the upgrade
continues, since a binary swap
[does not need re-registration](https://forgejo.org/docs/latest/admin/actions/registration/#interactive-registration).

`FORGEJO_SERVICE` and `RUNNER_SERVICE` must still name a real unit; if systemd
does not know it, the script dies listing services with `forgejo`, `gitea`, or
`runner` in the name.

## Examples

A host whose Forgejo unit is not named the way the script expects, for example a
service actually called `gitea.service`:

```bash
sudo FORGEJO_SERVICE=gitea forgejo-upgrade forgejo latest
```

Everything else — binary, user, config, work path, URL — is then read from
`gitea.service` instead of `forgejo.service`.

A reverse-proxied instance that only answers `https`, which the script cannot
health-check by guessing:

```bash
sudo FORGEJO_URL=https://git.example.com forgejo-upgrade forgejo latest
```

## Limits

Several runner units sharing one binary: the script stops and starts only
`RUNNER_SERVICE`. Upgrade each unit in turn, or restart the others by hand once
the binary on disk has changed.

## About `latest`

[The release API returns the newest tag across every release line](https://code.forgejo.org/api/swagger#/repository/repoGetLatestRelease).
If you run
[the v15 LTS line](https://forgejo.org/docs/latest/admin/upgrade/#release-life-cycle),
`latest` will offer you 16.x. Pass an explicit version instead. The major
version confirmation prompt is the safety net if you forget.
