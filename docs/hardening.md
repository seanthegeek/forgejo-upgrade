# Hardening

Upgrading promptly closes known holes. The settings below limit what the next
unknown one can reach. They apply wherever each component runs, as a binary
install under its own user and service; a host does not need to run both.

## Reduce exposure

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

## Turn off what you do not use

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

## Contain the server process

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

This profile assumes Forgejo listens only on unprivileged ports, which is the
default:
[`HTTP_PORT`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#server-server)
is `3000`, with
[a reverse proxy](https://forgejo.org/docs/latest/admin/setup/reverse-proxy/)
in front on 80 and 443, and the built-in SSH server is off
([`START_SSH_SERVER`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#server-server)
defaults to `false`). If Forgejo itself binds a port below 1024 —
`HTTP_PORT = 443`, say, or the built-in SSH server on port 22 — this drop-in
stops it: the empty
[`CapabilityBoundingSet=`](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#CapabilityBoundingSet=)
removes `CAP_NET_BIND_SERVICE` from every capability set, and
`NoNewPrivileges=true` means a file capability set on the binary with
`setcap` is not honored at `execve` either, so the restart below fails with
"permission denied" on the port and the journal says so. In that case,
replace the drop-in's last line with these two, which grant the one
capability through systemd itself, so no `setcap` on the binary is needed:

```ini
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
```

[How the script works](how-it-works.md) keeps a `setcap` file
capability across an upgrade for installs that rely on one without this
profile; under this profile,
[`AmbientCapabilities=`](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#AmbientCapabilities=)
is what does the work instead.

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

## Contain the runner

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

## Keep the door locked

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
