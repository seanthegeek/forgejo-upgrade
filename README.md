# forgejo-upgrade

A single Bash script that upgrades binary installs of [Forgejo](https://forgejo.org)
and [forgejo-runner](https://code.forgejo.org/forgejo/runner) safely: it
verifies the release signature and checksum, backs up before touching
anything, keeps the previous binary for rollback, and checks that the service
came back healthy.

It exists because Forgejo has shipped a security release nearly every month of
2026, and a patch should take one command, not a checklist.

## What the script does

| Command | Effect |
| --- | --- |
| `forgejo-upgrade check` | Print installed and latest versions of both components. |
| `forgejo-upgrade settings` | Print every setting an upgrade would use and where it came from. Read-only; works without root. |
| `forgejo-upgrade forgejo <version\|latest>` | Upgrade the Forgejo server. |
| `forgejo-upgrade runner <version\|latest>` | Upgrade forgejo-runner. |
| `forgejo-upgrade rollback forgejo\|runner` | Stop, restore the previous binary, start, confirm it is active. |

A server upgrade runs these steps in order:

1. Resolve every setting from the environment, the systemd unit, and
   `app.ini`, then print what it found and where each value came from.
2. Resolve the version and refuse silently to reinstall the same one.
3. Warn and ask for confirmation on a major version change.
4. Import the Forgejo release key if it is not already in the root keyring.
5. Download the binary and its detached signature, and verify that the
   signature chains to the Forgejo release key. Verify the `.sha256` file too
   when one is published.
6. Confirm the downloaded binary reports the requested version.
7. While the service is still up: if it is active, confirm it answers a
   health check; if a backup will be taken, create `BACKUP_DIR` and confirm
   the binary runs as `FORGEJO_USER`, and that this account can read the
   config and write to `BACKUP_DIR`.
8. Flush Forgejo's queues, then stop the service.
9. Take a `forgejo dump` backup into `BACKUP_DIR`.
10. Copy the old binary to `<name>.prev`, install the new one, keeping its
    owner, group, and mode.
11. Start the service and poll `/api/healthz` for up to a minute.
12. Run `forgejo doctor check --all`.

Any failure once the service has been stopped — the health check timing out,
or an error in an earlier step such as the backup — prints the last 40 lines
of the journal and the exact command to recover. `rollback` stops the
service, restores the previous binary, starts it, and confirms the service is
active again before reporting success.

A runner upgrade is the same minus the queue flush, backup, and doctor. The
runner's registration lives in its `.runner` file, so no re-registration is
needed. Stopping through systemd sends `SIGTERM`, which lets in-flight jobs
finish. The stock unit sets `TimeoutStopSec=infinity`, so a stuck job blocks
the upgrade until it finishes; set a finite value in a drop-in if you want a
bound.

## Installation

Copy the script to the host that runs Forgejo:

```bash
sudo install -m 755 forgejo-upgrade.sh /usr/local/sbin/forgejo-upgrade
```

The script upgrades an existing install; it refuses to run when the binary
it is asked to upgrade is missing.

Requirements: `bash`, `curl`, `gpg`, `runuser` (util-linux, present on every
systemd host) or `sudo`, `sed`, `grep`, GNU coreutils (`install`,
`sha256sum`, `mktemp`, `cp`, `date`, `seq`, `stat`), and systemd
(`systemctl`, `journalctl`). The script must run as root because it stops
services and writes to `/usr/local/bin`; `runuser` or `sudo` is needed to
run Forgejo's own commands as `FORGEJO_USER` even though the script itself
already runs as root.

### Before the first upgrade

Run `sudo forgejo-upgrade settings` and read each line. Every value can be
overridden with the environment variable it is labelled with.

## Configuration

Every setting is resolved in this order: an environment variable the
operator set, then a value read from the systemd unit or `app.ini`, then a
documented default. Resolution happens before anything is stopped, and
`forgejo-upgrade settings` prints every value together with which of those
three places it came from.

### Forgejo settings

| Variable | Read from | Default |
| --- | --- | --- |
| `FORGEJO_SERVICE` | — | `forgejo` |
| `FORGEJO_BIN` | `ExecStart=` program | `/usr/local/bin/forgejo` |
| `FORGEJO_USER` | `User=` | `git` |
| `FORGEJO_CONFIG` | `--config`/`-c` in `ExecStart=` | `<work path>/custom/conf/app.ini` if it exists, else `/etc/forgejo/app.ini` |
| `FORGEJO_WORK_PATH` | `FORGEJO_WORK_DIR`/`GITEA_WORK_DIR` in `Environment=`, then `--work-path`/`-w` in `ExecStart=`, then `WorkingDirectory=`, then `WORK_PATH` in `app.ini` | unset; Forgejo then uses the directory holding the binary, with a warning |
| `FORGEJO_URL` | `[server]` in `app.ini`: `LOCAL_ROOT_URL` if set, else `PROTOCOL`/`HTTP_ADDR`/`HTTP_PORT` (`0.0.0.0` becomes `localhost`); `http+unix` uses the socket in `HTTP_ADDR` via `curl --unix-socket` | `http://127.0.0.1:3000` |
| `BACKUP_DIR` | — | `/var/backups/forgejo` |
| `SKIP_BACKUP` | — | `0` |

The unit's `Environment=` entries are passed to every Forgejo CLI call the
script makes. Those calls run as `FORGEJO_USER` — via `runuser`, falling
back to `sudo` if `runuser` is not on `PATH` — from the resolved work path,
with `--config` and `--work-path` given explicitly before the subcommand.

If `PROTOCOL` in `app.ini` is `https`, `fcgi`, or `fcgi+unix`, the script
refuses to guess an address and dies before stopping anything, asking for
`FORGEJO_URL` — a URL that answers `/api/healthz`, such as the reverse proxy
in front of Forgejo.

### Runner settings

| Variable | Read from | Default |
| --- | --- | --- |
| `RUNNER_SERVICE` | — | `forgejo-runner` |
| `RUNNER_BIN` | `ExecStart=` program | `/usr/local/bin/forgejo-runner` |
| `RUNNER_HOME` | `WorkingDirectory=` | `/home/runner` |
| `RUNNER_CONFIG` | `-c`/`--config` in `ExecStart=` | unset |

The registration file the runner already holds is `runner.file` from
`RUNNER_CONFIG` (a relative path there is under `RUNNER_HOME`), or else
`$RUNNER_HOME/.runner`. A missing file only warns; the upgrade continues,
since a binary swap does not need re-registration.

`FORGEJO_SERVICE` and `RUNNER_SERVICE` must still name a real unit; if
systemd does not know it, the script dies listing services with `forgejo`,
`gitea`, or `runner` in the name.

### Examples

A host whose Forgejo unit is not named the way the script expects, for
example a service actually called `gitea.service`:

```bash
sudo FORGEJO_SERVICE=gitea forgejo-upgrade forgejo latest
```

Everything else — binary, user, config, work path, URL — is then read from
`gitea.service` instead of `forgejo.service`.

A reverse-proxied instance that only answers `https`, which the script
cannot health-check by guessing:

```bash
sudo FORGEJO_URL=https://git.example.com forgejo-upgrade forgejo latest
```

### Limits

Several runner units sharing one binary: the script stops and starts only
`RUNNER_SERVICE`. Upgrade each unit in turn, or restart the others by hand
once the binary on disk has changed.

### About `latest`

The release API returns the newest tag across every release line. If you run
the v15 LTS line, `latest` will offer you 16.x. Pass an explicit version
instead. The major version confirmation prompt is the safety net if you
forget.

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

Rollback works for patch releases because they do not change the database
schema. After a major upgrade, rollback needs the pre-upgrade dump restored
as well.

### Knowing when to run it

Forgejo announces security releases about five days ahead in the
[security-announcements](https://codeberg.org/forgejo/security-announcements/issues)
repository. Subscribe to its
[RSS feed](https://codeberg.org/forgejo/security-announcements.rss) and run
the upgrade on release day. Stay on the LTS line unless you need a feature
from the current stable line, which goes end-of-life a few weeks after the
next one ships.

## Hardening

Upgrading promptly closes known holes. The settings below limit what the next
unknown one can reach. They assume Forgejo and the runner are installed from
binaries as separate users and services.

### Reduce exposure

Nearly every 2026 Forgejo advisory, including the CVSS 9.9 template
repository remote code execution fixed in 16.0.4, required an account on the
instance. Do not give strangers one.

In `app.ini`:

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
overlay network address, or put it behind a reverse proxy that handles TLS
and, ideally, authentication. If it must be public, `REQUIRE_SIGNIN_VIEW`
makes anonymous users see nothing but the login page.

### Turn off what you do not use

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

Migrations and mirrors have a history of server-side request forgery, most
recently CVE-2026-82556. If you need them, set `ALLOWED_DOMAINS` in
`[migrations]` to the forges you actually pull from. The package registry has
had its own disclosure issues and is a large attack surface for a feature
most personal instances never touch.

### Contain the server process

A hardened systemd unit gives a compromised Forgejo process a read-only view
of the system, no home directories, no device access, and no way to gain
privileges. This gets most of the isolation a container would, without a
container runtime.

Create `/etc/systemd/system/forgejo.service.d/hardening.conf`:

```ini
[Service]
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/forgejo /etc/forgejo
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

Adjust `ReadWritePaths` to wherever your repositories, LFS objects, and
attachments live. If Forgejo writes its log elsewhere, add that path too.
Then:

```bash
sudo systemctl daemon-reload && sudo systemctl restart forgejo && sudo systemd-analyze security forgejo
```

A score under 3 is good. If the service fails to start after adding the
drop-in, the journal names the path or syscall that was blocked.

### Contain the runner

The runner is the riskier component. It exists to execute code that
workflows hand it. Where that code runs decides what a malicious workflow
can reach.

- **Run the runner on a different host or VM from Forgejo.** This is the
  single biggest improvement available. A workflow that escapes its job
  container then lands on a machine holding no repositories, secrets, or
  database.
- **If the runner uses Docker labels, it needs the Docker socket, which is
  root-equivalent on that host.** Treat the runner host as disposable. Do not
  also run anything you care about on it.
- **Do not use `host` labels on a shared machine.** They run workflow steps
  directly as the runner user with no container at all.
- In the runner's `config.yml`, keep jobs from reaching the socket and from
  running privileged:

  ```yaml
  container:
    privileged: false
    docker_host: "-"
    network: bridge
  runner:
    capacity: 1
  ```

  `docker_host: "-"` stops the runner from mounting the Docker socket into
  job containers. Set `network: ""` instead if jobs must not reach the
  network at all.
- Only register runners at repository or organization scope unless every
  repository on the instance is yours.
- Apply a systemd drop-in to the runner too. It needs write access to its
  state directory and, for Docker labels, membership in the `docker` group:

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

  `ProtectHome=tmpfs` hides the rest of `/home` behind an empty, read-only
  tmpfs while `BindPaths=` makes `/home/runner` visible again through it, and
  `ReadWritePaths=` then makes that directory writable; `ReadWritePaths=`
  alone cannot punch through `ProtectHome`. If you moved the runner's state
  out of `/home` (for example to `/var/lib/forgejo-runner`), use
  `ProtectHome=true` instead and list that directory in `ReadWritePaths=`.
  `TimeoutStopSec=` is where to set a finite stop timeout in this drop-in if
  you want one; the stock unit sets it to `infinity`.

### Keep the door locked

- Use a reverse proxy for TLS and set `HTTP_ADDR = 127.0.0.1` in `[server]`
  so Forgejo never listens on a public interface directly.
- Set `[security] REVERSE_PROXY_TRUSTED_PROXIES` to the proxy's address only,
  and leave `ENABLE_REVERSE_PROXY_AUTHENTICATION` off unless you built it on
  purpose.
- Enable two-factor authentication on every admin account.
- Scope API tokens to the minimum needed and expire them. Two of the fixes in
  16.0.4 concerned scoped tokens reaching past their scope.
- Back up the dump directory somewhere the Forgejo user cannot write. A
  compromise that can delete its own backups is much worse than one that
  cannot.

## Development

The script must pass `shellcheck` with no findings. There is no test suite;
the verification path can be exercised without a Forgejo install by sourcing
the function definitions and downloading a real release:

```bash
sed '/^# --- main/,$d' forgejo-upgrade.sh > ./defs.sh && source ./defs.sh && fetch_and_verify "$RUNNER_REPO" "forgejo-runner-13.1.0-linux-$(arch)" 13.1.0
```

See `AGENTS.md` for conventions and the facts about Forgejo's release
artifacts that the script depends on.

## License

Apache License 2.0. See `LICENSE`.
