# How the script works

The command table for each subcommand is in [Usage](usage.md). This page
walks through what a server or runner upgrade actually does, step by step.


A server upgrade runs these steps in order:

1. Resolve every setting from the environment, the systemd unit, and `app.ini`,
   then print what it found and where each value came from.
2. Resolve the version and, if that version is already installed, log "already
   on ..., nothing to do" and exit 0 without touching anything.
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
   The script creates the archive itself first, as `FORGEJO_USER` and with
   mode `0600`, because Forgejo
   [creates it at the umask and tightens it to `0600` only after a successful
   dump](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/cmd/dump.go#L419-L421),
   so an interrupted dump cannot leave a world-readable partial archive of
   `app.ini` and the database behind.
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
