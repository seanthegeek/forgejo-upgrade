# Usage

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
[How the script works](how-it-works.md).

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
[`BACKUP_DIR`](configuration.md#forgejo-settings); for PostgreSQL or
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

## Knowing when to run it

Forgejo announces security releases about five days ahead in the
[security-announcements](https://codeberg.org/forgejo/security-announcements/issues)
repository. Subscribe to its
[RSS feed](https://codeberg.org/forgejo/security-announcements.rss) and run the
upgrade on release day. Stay on the LTS line unless you need a feature from the
current stable line, which
[goes end-of-life a few weeks after the next one ships](https://forgejo.org/docs/latest/admin/upgrade/#release-life-cycle).
