# Installation

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

## Before the first upgrade

Run `sudo forgejo-upgrade settings` and read each line. Every value can be
overridden with the environment variable it is labelled with, except
`RUNNER_REG_FILE`, which the script derives from `RUNNER_HOME` and
`RUNNER_CONFIG` and does not read from the environment. See
[Configuration](configuration.md) for what each of those variables
does and its default.
