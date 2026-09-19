# forgejo-upgrade

A single Bash script that upgrades binary installs of
[Forgejo](https://forgejo.org) and
[forgejo-runner](https://code.forgejo.org/forgejo/runner) safely: it
[verifies the release signature and checksum](https://forgejo.org/download/#installation-from-binary),
backs up before touching anything, keeps the previous binary for rollback, and
checks that the service came back healthy. It upgrades whichever of the two is
installed on a given host — a host may run Forgejo, the runner, or both. The
runner is optional and is often installed on a separate host from Forgejo; see
the hardening section below for why.

It exists because Forgejo has shipped a security release nearly every month of
2026, and a patch should take one command, not a checklist.

## What the script does

| Command | Effect |
| --- | --- |
| `forgejo-upgrade check` | Print installed and latest versions of both components; a component that is not installed on this host shows as "not installed". |
| `forgejo-upgrade settings` | Print every setting an upgrade would use and where it came from, or one line saying a component is not installed instead of guessing its settings. Read-only; works without root. |
| `forgejo-upgrade forgejo <version\|latest>` | Upgrade the Forgejo server. |
| `forgejo-upgrade runner <version\|latest>` | Upgrade forgejo-runner. |
| `forgejo-upgrade rollback forgejo\|runner [--no-start]` | Stop, restore the previous binary, then start and confirm it is active — unless `--no-start` is given or [the major version changed](https://forgejo.org/docs/latest/admin/upgrade/#unexpected-database-version), in which case it leaves the service stopped and prints what to restore first. |

Only one `forgejo`, `runner`, or `rollback` invocation runs at a time; a second
one stops at the lock held in `/run/forgejo-upgrade.lock`.

A server upgrade runs these steps in order:

1. Resolve every setting from the environment, the systemd unit, and `app.ini`,
   then print what it found and where each value came from.
2. Resolve the version and refuse silently to reinstall the same one.
3. Warn and ask for confirmation on a major version change.
4. [Import the Forgejo release key](https://forgejo.org/download/#installation-from-binary)
   if it is not already in the root keyring.
5. Download the binary and its detached signature, and verify that the signature
   chains to the Forgejo release key and is neither expired nor made by a
   revoked key. If the signature was made with a subkey not yet in the local
   keyring, refresh only that pinned key from the keyserver and check once more
   before giving up. Any other failure — a bad signature, an expired signature
   or key, a revoked key, or a signature from a different key — stops the
   upgrade with a message naming what gpg reported. Verify the `.sha256` file
   too when one is published; only a 404 counts as "not published" — any other
   download failure stops the upgrade.
6. Confirm the downloaded binary
   [reports the requested version](https://forgejo.org/docs/latest/user/api/versions/#obtaining-the-forgejo-version).
7. While the service is still up: if it is active, confirm it answers a health
   check with HTTP 200; if a backup will be taken, create `BACKUP_DIR` if it
   does not exist (an existing directory keeps its owner and mode) and confirm
   the binary runs as `FORGEJO_USER`, and that this account can read the config
   and write to `BACKUP_DIR`.
8. [Flush Forgejo's queues](https://forgejo.org/docs/latest/admin/command-line/#manager-flush-queues),
   [then stop the service](https://forgejo.org/docs/latest/admin/upgrade/#preparing-the-forgejo-upgrade).
9. Take a
   [`forgejo dump`](https://forgejo.org/docs/latest/admin/command-line/#dump)
   backup into `BACKUP_DIR`. For SQLite this zip is a complete backup, database
   included. The zip also contains an SQL copy of the database for PostgreSQL
   and MySQL, but
   [Forgejo's own upgrade guide](https://forgejo.org/docs/latest/admin/upgrade/#backup)
   says that copy has serious long-standing restore bugs and must not be used to
   restore either of them. So the script warns about this before stopping
   anything and, on a major upgrade, asks whether a native dump has been taken;
   running that native dump (`pg_dump`, `mysqldump`) is the operator's own job.
10. Copy the old binary to `<name>.prev`, install the new one, keeping its
    owner, group, mode, ACL, extended attributes such as file capabilities set
    with `setcap`, and SELinux context. Anything already at `<name>.prev` that
    is not a plain file — a directory, or a symlink — is refused before the
    service is stopped, because that name has to hold the binary a rollback
    reads back.
11. Start the service and poll
    [`/api/healthz`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/routers/web/web.go#L395)
    for up to a minute, until it
    [answers HTTP 200](https://forgejo.org/docs/latest/admin/upgrade/#verify-forgejo-works).
12. Run
    [`forgejo doctor check --all`](https://forgejo.org/docs/latest/admin/command-line/#doctor-check).

Any failure once the service has been stopped — the health check timing out, or
an error in an earlier step such as the backup — prints the last 40 lines of the
journal and the exact command to recover, repeating any `FORGEJO_*`, `RUNNER_*`,
or `BACKUP_DIR` override the run was given so that `rollback` resolves the same
install, and prefixed with `sudo` when the run was started through `sudo`.
`rollback` stops the service, restores the previous binary, starts it, and
confirms the service is active again before reporting success.

A runner upgrade is the same minus the queue flush, backup, and doctor. The
runner's registration lives in its
[`.runner` file](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/internal/pkg/config/config.example.yaml#L23),
so
[no re-registration is needed](https://forgejo.org/docs/latest/admin/actions/installation/binary/#starting-the-runner).
Stopping through systemd sends
[`SIGTERM`](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/main.go#L16);
the runner then waits for in-flight jobs up to its
[`shutdown_timeout`](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/internal/pkg/config/config.example.yaml#L38-L42)
(3h in the generated config; unset or zero cancels them at once)
[before it exits](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/internal/app/cmd/daemon.go#L93-L100).
The stock unit sets
[`TimeoutStopSec=infinity`](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/contrib/forgejo-runner.service#L15),
so systemd never kills it first and a long job blocks the upgrade for up to that
timeout; set
[a finite value in a drop-in](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html#TimeoutStopSec=)
if you want a bound.

## Installation

Copy the script to each host that runs Forgejo or the runner:

```bash
sudo install -m 755 forgejo-upgrade.sh /usr/local/sbin/forgejo-upgrade
```

The script upgrades an existing install; it refuses to run when the binary it is
asked to upgrade is missing.

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
`RUNNER_CONFIG` and does not read from the environment.

## Configuration

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

### Forgejo settings

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

### Runner settings

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

### Examples

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

### Limits

Several runner units sharing one binary: the script stops and starts only
`RUNNER_SERVICE`. Upgrade each unit in turn, or restart the others by hand once
the binary on disk has changed.

### About `latest`

[The release API returns the newest tag across every release line](https://code.forgejo.org/api/swagger#/repository/repoGetLatestRelease).
If you run
[the v15 LTS line](https://forgejo.org/docs/latest/admin/upgrade/#release-life-cycle),
`latest` will offer you 16.x. Pass an explicit version instead. The major
version confirmation prompt is the safety net if you forget.

## Usage

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
`BACKUP_DIR`; for PostgreSQL or MySQL, the native dump you took before the
upgrade, because the zip's SQL is not a safe restore — see Forgejo's own
[upgrade guide's Backup section](https://forgejo.org/docs/latest/admin/upgrade/#backup)
— then run `systemctl start` yourself. Pass `--no-start` to force that same
stopped-and-waiting behavior on any rollback, patch or major. Rollback does not
require the current binary to be intact — it only needs the `.prev` file, which
is what a failed install leaves behind. That file has to be a plain file — not
a symbolic link, not a directory — and it has to run and report a version the
script recognises, all checked before anything is stopped; otherwise it is not
the binary an upgrade set aside and the rollback refuses.

### Knowing when to run it

Forgejo announces security releases about five days ahead in the
[security-announcements](https://codeberg.org/forgejo/security-announcements/issues)
repository. Subscribe to its
[RSS feed](https://codeberg.org/forgejo/security-announcements.rss) and run the
upgrade on release day. Stay on the LTS line unless you need a feature from the
current stable line, which
[goes end-of-life a few weeks after the next one ships](https://forgejo.org/docs/latest/admin/upgrade/#release-life-cycle).

## Hardening

Upgrading promptly closes known holes. The settings below limit what the next
unknown one can reach. They apply wherever each component runs, as a binary
install under its own user and service; a host does not need to run both.

### Reduce exposure

[Nearly every 2026 Forgejo advisory](https://codeberg.org/forgejo/security-announcements/issues),
including the
[CVSS 9.9 template repository remote code execution](https://www.cve.org/CVERecord?id=CVE-2026-89094)
fixed in
[16.0.4](https://codeberg.org/forgejo/forgejo/src/branch/forgejo/release-notes-published/16.0.4.md),
required an account on the instance. Do not give strangers one.

In `app.ini`'s
[`[service]`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#service-service),
[`[openid]`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#openid-openid),
[`[oauth2_client]`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#oauth2-client-oauth2_client),
[`[repository]`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#repository-repository),
and
[`[security]`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#security-security)
sections:

```ini
[service]
DISABLE_REGISTRATION = true
SHOW_REGISTRATION_BUTTON = false
REQUIRE_SIGNIN_VIEW = true
DEFAULT_KEEP_EMAIL_PRIVATE = true

[openid]
ENABLE_OPENID_SIGNIN = false
ENABLE_OPENID_SIGNUP = false

[oauth2_client]
ENABLE_AUTO_REGISTRATION = false

[repository]
DEFAULT_PRIVATE = private

[security]
INSTALL_LOCK = true
```

Keep the instance off the public internet if you can. Bind it to a VPN or
overlay network address, or put it behind a reverse proxy that handles TLS and,
ideally, authentication. If it must be public, `REQUIRE_SIGNIN_VIEW` makes
anonymous users see nothing but the login page.

### Turn off what you do not use

In `app.ini`'s
[`[actions]`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#actions-actions),
[`[packages]`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#packages-packages),
[`[repository]`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#repository-repository),
and
[`[migrations]`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#migrations-migrations)
sections:

```ini
[actions]
ENABLED = false

[packages]
ENABLED = false

[repository]
DISABLE_MIGRATIONS = true

[migrations]
ALLOW_LOCALNETWORKS = false
```

Migrations and mirrors have a history of
[server-side request forgery](https://codeberg.org/forgejo/forgejo/pulls/13490),
most recently [CVE-2026-82556](https://www.cve.org/CVERecord?id=CVE-2026-82556).
If you need them, set `ALLOWED_DOMAINS` in `[migrations]` to the forges you
actually pull from. The package registry has had its own disclosure issues and
is a large attack surface for a feature most personal instances never touch.

### Contain the server process

A hardened systemd unit gives a compromised Forgejo process a read-only view of
the system, no home directories, no device access, and
[no way to gain privileges](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#NoNewPrivileges=).
This gets most of the isolation a container would, without a container runtime.

Create `/etc/systemd/system/forgejo.service.d/hardening.conf`:

```ini
[Service]
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=tmpfs
BindPaths=/home/git
ReadWritePaths=/var/lib/forgejo /etc/forgejo /home/git
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
CapabilityBoundingSet=
```

Adjust `ReadWritePaths` to wherever your
[repositories](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#repository-repository),
[LFS objects](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#lfs-lfs),
and
[attachments](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#issue-and-pull-request-attachments-attachment)
live. If Forgejo writes its
[log](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#log-log)
elsewhere, add that path too.

`/home/git` is there for SSH. Unless Forgejo runs its built-in SSH server, it
manages `authorized_keys` under
[`SSH_ROOT_PATH`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#server-server),
which defaults to the service user's `~/.ssh`, and
[the install guide](https://forgejo.org/docs/latest/admin/installation/binary/#install-forgejo-and-git-create-git-user)
creates that user with its home at `/home/git`.
[`ProtectHome=true`](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#ProtectHome=)
would hide the whole of `/home`, and adding a key in the web UI would then fail.
`ProtectHome=tmpfs` hides `/home` behind an empty tmpfs, `BindPaths=` shows
`/home/git` through it again, and `ReadWritePaths=` makes it writable. If the
service user's home is outside `/home`, or `START_SSH_SERVER = true`, or `sshd`
uses an `AuthorizedKeysCommand` with `SSH_CREATE_AUTHORIZED_KEYS_FILE = false`,
use `ProtectHome=true` and drop the `BindPaths=` line. Then:

```bash
sudo systemctl daemon-reload && sudo systemctl restart forgejo && sudo systemd-analyze security forgejo
```

A
[`systemd-analyze security`](https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html#systemd-analyze%20security%20%5BUNIT...%5D)
score under 3 is good. If the service fails to start after adding the drop-in,
the journal names the path or syscall that was blocked.

### Contain the runner

The runner is the riskier component. It exists to execute code that workflows
hand it. Where that code runs decides what a malicious workflow can reach.

- **Run the runner on a different host or VM from Forgejo.** This is the single
  biggest improvement available. A workflow that escapes its job container then
  lands on a machine holding no repositories, secrets, or database.
- **If the runner uses
  [Docker labels](https://forgejo.org/docs/latest/admin/actions/configuration/#docker-or-podman),
  it needs the Docker socket, which is root-equivalent on that host.** Treat the
  runner host as disposable. Do not also run anything you care about on it.
- **Do not use
  [`host` labels](https://forgejo.org/docs/latest/admin/actions/configuration/#host)
  on a shared machine.** They run workflow steps directly as the runner user
  with
  [no container at all](https://forgejo.org/docs/latest/admin/actions/installation/binary/#host).
- In the runner's
  [`config.yml`](https://forgejo.org/docs/latest/admin/actions/configuration/#configuration-file-reference),
  keep jobs from reaching the socket and from
  [running privileged](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/internal/pkg/config/config.example.yaml#L201):

  ```yaml
  container:
    privileged: false
    docker_host: "-"
    network: bridge
  runner:
    capacity: 1
  ```

  [`docker_host: "-"`](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/internal/pkg/config/config.example.yaml#L220-L223)
  stops the runner from mounting the Docker socket into job containers. Set
  [`network: none`](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/internal/pkg/config/config.example.yaml#L192-L196)
  if jobs must have no network access at all. An empty value (`network: ""`)
  does not isolate anything: it tells the runner to create a network per job,
  which still has outbound access.
  [`capacity: 1`](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/internal/pkg/config/config.example.yaml#L25)
  limits the runner to one job at a time.
- Only register runners at
  [repository or organization scope](https://forgejo.org/docs/latest/admin/actions/registration/#interactive-registration)
  unless every repository on the instance is yours.
- Apply a systemd drop-in to the runner too. It needs write access to its state
  directory and, for Docker labels,
  [membership in the `docker` group](https://forgejo.org/docs/latest/admin/actions/installation/binary/#setting-up-the-runner-user):

  ```ini
  [Service]
  NoNewPrivileges=true
  ProtectSystem=strict
  ProtectHome=tmpfs
  BindPaths=/home/runner
  ReadWritePaths=/home/runner
  SupplementaryGroups=docker
  PrivateTmp=true
  ProtectKernelTunables=true
  ProtectControlGroups=true
  RestrictRealtime=true
  RestrictSUIDSGID=true
  ```

  `ProtectHome=tmpfs` hides the rest of `/home` behind an empty, read-only tmpfs
  while `BindPaths=` makes `/home/runner` visible again through it, and
  `ReadWritePaths=` then makes that directory writable; `ReadWritePaths=` alone
  cannot punch through `ProtectHome`. If you moved the runner's state out of
  `/home` (for example to `/var/lib/forgejo-runner`), use `ProtectHome=true`
  instead and list that directory in `ReadWritePaths=`.
  [`TimeoutStopSec=`](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/contrib/forgejo-runner.service#L15)
  is where to set a finite stop timeout in this drop-in if you want one; the
  stock unit sets it to `infinity`.

### Keep the door locked

- Use a reverse proxy for TLS and set
  [`HTTP_ADDR = 127.0.0.1`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#server-server)
  in `[server]` so Forgejo never listens on a public interface directly.
- Set
  [`[security] REVERSE_PROXY_TRUSTED_PROXIES`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#security-security)
  to the proxy's address only, and leave
  [`ENABLE_REVERSE_PROXY_AUTHENTICATION`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#service-service)
  off unless you built it on purpose.
- Enable two-factor authentication on every admin account.
- [Scope API tokens](https://forgejo.org/docs/latest/user/authentication/token-scope/)
  to the minimum needed and expire them. One of the
  [16.0.4](https://codeberg.org/forgejo/forgejo/src/branch/forgejo/release-notes-published/16.0.4.md)
  fixes, [CVE-2026-89151](https://www.cve.org/CVERecord?id=CVE-2026-89151),
  closed a way for a repository-scoped API token to modify content outside its
  scope.
- `BACKUP_DIR` has to be writable by the Forgejo user, because
  [`forgejo dump` runs as that account](https://forgejo.org/docs/latest/admin/installation/binary/#general-hints-for-using-forgejo).
  Copy completed dumps — and, for PostgreSQL or MySQL, the native database dump
  taken alongside them — somewhere that account cannot write: a root-owned
  directory, or another host entirely. A compromise that can delete its own
  backups is much worse than one that cannot.

## Development

The script must pass `shellcheck` with no findings. There is no test suite; the
verification path can be exercised without a Forgejo install by sourcing the
function definitions and downloading
[a real release](https://code.forgejo.org/forgejo/runner/releases):

```bash
sed '/^# --- main/,$d' forgejo-upgrade.sh > ./defs.sh && source ./defs.sh && fetch_and_verify "$RUNNER_REPO" "forgejo-runner-13.1.0-linux-$(arch)" 13.1.0
```

See `AGENTS.md` for conventions and the facts about Forgejo's release artifacts
that the script depends on.

## License

Apache License 2.0. See `LICENSE`.
