# AGENTS.md

## Project overview

One Bash script, `forgejo-upgrade.sh`, that upgrades binary installs of
[Forgejo](https://forgejo.org) and forgejo-runner on a systemd host. It
downloads a release, checks the GPG signature and sha256, backs up, swaps the
binary keeping the old one, restarts the service, and verifies health.
`README.md` documents usage and a hardening guide for the two services.

No application code, no database, no CI. The deliverable is a script an
operator runs as root on a machine they cannot afford to break, so caution in
the script beats cleverness. It is developed on a machine that does not run
Forgejo and deployed elsewhere by hand.

## Conventions

These rules apply to anyone, human or agent, making changes to this repo.
They are checked in rather than living in any one agent's private memory so
that every collaborator picks them up the same way.

- **Wait for explicit commit AND push permission on the default branch.
  These are separate grants.** Finish the work, run shellcheck, summarize the
  diff, then stop and ask. "Commit this" mid-session is permission for that
  one commit, not a standing grant, and permission to commit is never
  permission to push. If a prior commit was unauthorized, do not push it to
  tidy up. Surface it and let the author decide.
  - Before every `git commit`: has the author typed "commit", or an
    unambiguous equivalent, in a present-tense imperative since your last
    commit? If not, ask. Conditionals such as "if it works we can push" are
    plans to confirm, not authorizations. The literal text of the last
    message governs.
  - Before every `git push`: has the author typed "push" since your last
    push? Same rule.
  - Exception: on a feature branch you created yourself in this session,
    commit and push to that branch freely. It is reviewed at PR-open. This
    never extends to `main` or to branches the author created.
- **Project rules belong here, not in any agent's private memory store.**
  Memory is for user-profile facts and tool preferences. A rule about this
  script is portable across agents only if it is written here.
- **Plain language over jargon.** Comments, log messages, and docs are read
  by an operator at the moment an upgrade has gone wrong. Where a domain
  term is the right word, use it and gloss it once.
- **Neither component is assumed present.** A host may run Forgejo, the
  runner, or both. A component counts as present when its systemd unit is
  loaded, its resolved binary is executable, or the operator set its
  service or binary variable (`FORGEJO_SERVICE`/`FORGEJO_BIN`,
  `RUNNER_SERVICE`/`RUNNER_BIN`). Read-only commands (`settings`, `check`)
  say "not installed" once for a component that is absent, and must not
  warn about it or ask the release API for its latest version. The
  upgrade and rollback commands are unchanged: they still die on a unit
  that does not exist.
- **Never weaken verification to make a download succeed.** No skipping the
  signature check, no `--insecure`, no falling back to an unverified file, no
  accepting a signature from a key other than the one pinned in
  `RELEASE_KEY`. A failed verification stops the upgrade and says why.
- **The pinned fingerprint is the trust root. Changing it is a security
  decision, not a fix.** If a signature check starts failing, first check
  whether the release moved to a new subkey of the same primary key, per
  [GnuPG's DETAILS](https://github.com/gpg/gnupg/blob/eb9d633dd4f75713169446988400882965170caa/doc/DETAILS#L537)
  (`VALIDSIG` lists the subkey fingerprint then the primary), which the
  current check already tolerates. Only change `RELEASE_KEY` after
  confirming the new fingerprint on the
  [download page](https://forgejo.org/download/#installation-from-binary)
  and name that source in the commit message. When a signature fails
  because the
  signing subkey is not yet in the local keyring, the script refreshes
  exactly `RELEASE_KEY` from `KEYSERVER` and retries the check once — that
  is the only automatic key action it takes, it never imports anything
  else, and a second failure is still a hard stop. The trust root does not
  move.
- **Every failure message must be actionable.** Name what was expected, what
  was observed, and the remedy. Any exit that leaves a service stopped or
  unhealthy must print the journal and the exact command to recover, which is
  `systemctl start` when the binary was not replaced and `rollback` when it
  was. The printed `rollback` command carries the overrides the run was
  given (`FORGEJO_OVERRIDES` / `RUNNER_OVERRIDES`, captured before any
  default is applied), shell-quoted, so it resolves the same install; `$0`
  is quoted the same way. It is prefixed with `sudo` when `SUDO_USER` is
  set, since the run was then started through `sudo` and the shell the
  operator pastes into is not root; the overrides go after the `sudo`,
  because `sudo` passes `NAME=value` words from its own command line
  through but strips them from the environment it inherits.
- **Do not suppress errors blanketly.** `|| true`, `|| warn`, and
  `2>/dev/null` are for a specific failure you have decided is acceptable and
  can say why. In the script:
  - `on_exit`: `journalctl ... || warn` — the journal may be unreadable; the
    remedy must still print, and the exit status must be preserved either
    way.
  - `on_exit`: `rm -rf "$WORKDIR" || warn` — a cleanup failure must not
    replace the real exit status.
  - `on_exit`: `rm -rf "$LOCK_DIR" || warn` — like the `WORKDIR` removal, a
    cleanup failure must not replace the real exit status.
  - `acquire_lock`: `err=$(mkdir "$LOCK_DIR" 2>&1)` — output capture, not
    suppression. `mkdir` on an existing directory is the failure that means
    another run holds the lock, and its message is dropped for that case in
    favour of one that names the holder; when no directory is there
    afterwards, `mkdir` could not create anything (a missing or read-only
    `/run`, no space, a plain file at the path) and its message is shown.
  - `acquire_lock`: `kill -0 "$pid" 2>/dev/null` — only "is that pid alive"
    is asked, to decide whether the stale-lock message says "running" or
    "not running".
  - `acquire_lock`: `if ! read -r pid < "$LOCK_DIR/pid"; then :; fi` — read
    returns non-zero for a pid file with no final newline although it has
    filled in the value, and an empty file leaves the value empty; both
    are covered by the message wording, so the exit status is deliberately
    not what is judged.
  - `ensure_key`: `gpg --list-keys "$RELEASE_KEY" >/dev/null 2>&1` — only the
    exit status ("is the key present") is used.
  - `gpg_valid_sig`: `gpg --verify ... 2>/dev/null || true` — the exit
    status is ignored on purpose, because gpg exits non-zero on
    [`NO_PUBKEY`](https://github.com/gpg/gnupg/blob/eb9d633dd4f75713169446988400882965170caa/doc/DETAILS#L829);
    the status-fd lines are what is judged instead
    ([`VALIDSIG`](https://github.com/gpg/gnupg/blob/eb9d633dd4f75713169446988400882965170caa/doc/DETAILS#L537)
    for the pinned key, and none of
    [`EXPSIG`](https://github.com/gpg/gnupg/blob/eb9d633dd4f75713169446988400882965170caa/doc/DETAILS#L485),
    [`EXPKEYSIG`](https://github.com/gpg/gnupg/blob/eb9d633dd4f75713169446988400882965170caa/doc/DETAILS#L492),
    or
    [`REVKEYSIG`](https://github.com/gpg/gnupg/blob/eb9d633dd4f75713169446988400882965170caa/doc/DETAILS#L499)
    present — gpg emits one of those three alongside `VALIDSIG` for a
    signature that is valid but expired, or made by an expired or revoked
    key). `gpg_verdict` reads the same status lines to
    classify a failure — missing key, bad signature, expired, revoked, a
    different key, or unverifiable — for the message `fetch_and_verify`
    prints. The human-readable stderr stays suppressed.
  - `gpg_status_line`: `grep -m1 -E "$1" <<<"$GPG_STATUS" || true` — quotes
    the first matching status line back to the operator in the failure
    message; a status with no matching line at all is a normal case (for
    example, an empty status above all) and must print nothing rather
    than fail the message itself.
  - `fetch_sha256`: runs `curl` without `-f` and reads the HTTP status
    itself; only a 404 is treated as "not published" and warned about, and
    the upgrade continues on the GPG signature alone. A transport error or
    any other status stops the upgrade. There is no `2>/dev/null` here.
  - `resolve_*_settings --rollback`, used only by `rollback`: skips just
    the "current binary must be executable" check, because a failed
    install can leave `$BIN` truncated or missing and that is exactly when
    `rollback` runs. Every other check, including that the unit exists,
    still applies; `.prev` is what `rollback` actually needs.
  - `resolve_forgejo_settings`: `id -u "$FORGEJO_USER" >/dev/null 2>&1` —
    only the exit status ("does this user exist") is used; the message on
    failure is the script's own, not `id`'s.
  - `run_as`: `command -v runuser >/dev/null` and
    `command -v sudo >/dev/null` — only "is it on `PATH`" is checked, not
    any output.
  - `healthz`: `curl -o /dev/null -w '%{http_code}' ... 2>/dev/null` — the
    response body is discarded and stderr is dropped; only the printed
    status code is read, and it must be exactly `200`. A connection
    refused, expected while the service is still starting, and any other
    code are both just "not healthy yet". Each attempt is capped with
    `--max-time`, and `wait_forgejo_healthy` runs against a clock, not a
    count, so the documented one-minute limit is real.
  - `die_unknown_unit`: `systemctl list-units ... || candidates=""` — the
    unit listing is a best-effort hint; if it fails too, the real "unit not
    found" error still has to print, so this failure is swallowed
    deliberately rather than masking that error.
  - `upgrade_forgejo`: `flush-queues || warn` — the service may already be
    stopped.
  - `upgrade_forgejo`: the pre-stop run check,
    `runcheck=$(as_forgejo --version 2>&1)` — output capture for the
    error message, not suppression; if the command fails, its output is
    shown to the operator before anything is stopped.
  - `upgrade_forgejo`: `doctor check --all || warn` — findings are reported,
    not fatal.

  `--version 2>&1` in `installed_forgejo` and `installed_runner` is output
  capture, not suppression: it merges stderr into the string handed to `die`
  or the version parser so a failure message is not lost. The post-download
  checks in `upgrade_forgejo` and `upgrade_runner` capture the downloaded
  binary's `--version` output the same way and show it in the failure
  message.
- **Fix the underlying bug, not the symptom.** A hand-run `systemctl start`
  or a manual `cp` on the Forgejo host to recover from a script failure is
  the bridge. The code change that stops it recurring is the destination.
  Both happen.
- **Research order: the live release artifact, then Forgejo's own docs, then
  Forgejo issues.** Third-party security write-ups and AI explainers are
  pointers, not evidence. One write-up claimed the
  [16.0.4 template repository bug](https://www.cve.org/CVERecord?id=CVE-2026-89094)
  needed no account.
  [Forgejo's release notes](https://codeberg.org/forgejo/forgejo/src/branch/forgejo/release-notes-published/16.0.4.md)
  say it needs a malicious template repository, which needs an account.
  Write-ups showed a capitalized `Forgejo version` string the binary does
  not print; the current docs page on
  [obtaining the version](https://forgejo.org/docs/latest/user/api/versions/#obtaining-the-forgejo-version)
  does not show the string at all. Check the artifact. A CVE id or a CVSS
  score is checked at
  [MITRE](https://cveawg.mitre.org/api/cve/CVE-2026-89094) or
  [NVD](https://services.nvd.nist.gov/rest/json/cves/2.0?keywordSearch=Forgejo),
  never in Forgejo's own release notes or security-announcements issues,
  which carry neither. NVD answers a bare `curl` with an empty body; pass a
  `User-Agent`. The README's "CVSS 9.9" for the 16.0.4 template repository
  fix was wrongly called unsupported after reading only Forgejo's notes.
- **A number in the docs is a claim like any other.** A count, a score, a
  timeout, a version: each is checked against its artifact the same way a
  version string is, before it is written and again when it is cited.
  Today's finds: "two of the fixes in 16.0.4" was one; "waits for in-flight
  jobs" was "waits up to `runner.shutdown_timeout`".
- **Read official documentation in full before changing behavior that
  depends on it.** The
  [upgrade guide](https://forgejo.org/docs/latest/admin/upgrade/), the
  [binary installation guide](https://forgejo.org/docs/latest/admin/installation/binary/),
  and the
  [runner installation guide](https://forgejo.org/docs/latest/admin/actions/installation/binary/)
  are short. Read the page, not the heading. A `grep` over a downloaded
  page is a heading skim, not a reading: grepping the runner installation
  guide for `.runner` missed its statement that the runner has no default
  configuration file location and its instruction to start the daemon from
  the home directory, both of which the script depends on.
- **No new dependencies.** The script needs `bash`, `curl`, `gpg`, `runuser`
  (util-linux) or `sudo`, `sed`, `grep`, GNU coreutils (`install`,
  `sha256sum`, `mktemp`, `cp`, `date`, `stat`), and systemd
  (`systemctl`, `journalctl`). Do not add `jq`, Python, or anything else an
  operator would have to install on a server first. The
  [`tag_name`](https://code.forgejo.org/api/swagger#/repository/repoGetLatestRelease)
  parser uses `sed` for exactly this reason.

## Facts about Forgejo release artifacts

Each of these was learned by running the script against a real release and
having it fail. Do not change the code that depends on them without
re-checking against a current release.

Source links below are pinned to a commit or tag, not a moving branch:
[forgejo commit `a0ad12ba49c03d56347b95f1b40af0a304746e00`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/),
[runner commit `d86d3195ac851bcfed165e692c76e5c44d47b4a9`](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/),
[go-ini tag `v1.67.3`](https://github.com/go-ini/ini/blob/v1.67.3/), and
[gnupg commit `eb9d633dd4f75713169446988400882965170caa`](https://github.com/gpg/gnupg/blob/eb9d633dd4f75713169446988400882965170caa/doc/DETAILS).
Every `#Lnn` line link below points at one of these four pins.

- **Releases are signed by a rotating subkey, not the primary key.** gpg's
  [`VALIDSIG`](https://github.com/gpg/gnupg/blob/eb9d633dd4f75713169446988400882965170caa/doc/DETAILS#L537)
  status line lists the signing subkey fingerprint first and the
  primary key fingerprint last. The check matches the primary fingerprint at
  the end of the line, so subkey rotation does not break it. Matching the
  primary fingerprint right after `VALIDSIG` fails on every release.
  `VALIDSIG` by itself only means the signature is cryptographically
  valid: gpg prints it together with
  [`EXPSIG`](https://github.com/gpg/gnupg/blob/eb9d633dd4f75713169446988400882965170caa/doc/DETAILS#L485),
  [`EXPKEYSIG`](https://github.com/gpg/gnupg/blob/eb9d633dd4f75713169446988400882965170caa/doc/DETAILS#L492),
  or
  [`REVKEYSIG`](https://github.com/gpg/gnupg/blob/eb9d633dd4f75713169446988400882965170caa/doc/DETAILS#L499)
  for a signature that is valid but expired, or made by an expired or
  revoked key, so the check also rejects those three records.
  [`KEYEXPIRED`](https://github.com/gpg/gnupg/blob/eb9d633dd4f75713169446988400882965170caa/doc/DETAILS#L815)
  lines are different — every current release's status carries them for
  older, unrelated subkeys — and must not be treated as a failure.
- **A duplicated key in `app.ini` uses the last assignment, not the
  first.** go-ini's
  [`Section.NewKey`](https://github.com/go-ini/ini/blob/v1.67.3/section.go#L66-L84)
  overwrites the value on a repeated key, and Forgejo's
  [`configProviderLoadOptions()`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/config_provider.go#L189-L194)
  (`modules/setting/config_provider.go`) never sets `AllowShadows`, so
  duplicates are not accumulated, just replaced. `ini_get` matches this:
  it returns the last assignment for a key, and treats an empty last
  value as unset, the same as upstream's
  [`if configWorkPath != ""`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/path.go#L190)
  check. go-ini also expands `%(NAME)s` references when a value is read
  ([`Key.transformValue`](https://github.com/go-ini/ini/blob/v1.67.3/key.go#L142-L176),
  in
  [`gopkg.in/ini.v1 v1.67.3`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/go.mod#L112),
  the version Forgejo pins): NAME is looked up in the same section, then,
  if absent there or if it is the key being read itself, in the keys
  before the first
  `[section]`; a name found in neither stops the expansion and leaves the
  reference in place; the referenced value is itself expanded the same
  way; up to 99 rounds.
  [Forgejo's config cheat sheet](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#server-server)
  documents
  `LOCAL_ROOT_URL: %(PROTOCOL)s://%(HTTP_ADDR)s:%(HTTP_PORT)s/` as the
  default, so an operator who copies that form into `app.ini` is on a
  documented path. `ini_get` does the same expansion on the value it
  returns, with two deliberate approximations: an empty lookup counts as
  "not found" (ini_get already conflates absent and empty), and only
  names made of letters, digits and underscore are expanded. A cycle
  (`A = %(B)s`, `B = %(A)s`) terminates in the script: a replacement that
  still carries a reference is put in place and ends the expansion, and a
  round counter caps it at 99 either way; go-ini itself would recurse
  without limit on such a file, so Forgejo would not start on it.
- **A health check must require exactly HTTP 200.**
  [curl's `-f`](https://curl.se/docs/manpage.html) treats any 2xx or 3xx
  response as success, and a reverse proxy in front of Forgejo can answer
  a redirect to a login page — HTTP 302, say — while Forgejo itself is
  down.
  [`healthz`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/routers/web/healthcheck/check.go#L67)
  reads only the status code and accepts `200` alone.
- **The primary key fingerprint is
  `EB114F5E6C0DC2BCDD183550A4B61A2DC5923710`** per the
  [download page](https://forgejo.org/download/#installation-from-binary).
  The same key signs the runner, per the
  [runner guide](https://forgejo.org/docs/latest/admin/actions/installation/binary/#downloading-and-installing-the-binary),
  which shows the same fingerprint.
- **The server binary prints a lowercase `forgejo version 16.0.5+gitea-...`**
  even though write-ups show it capitalized (the docs page on
  [obtaining the version](https://forgejo.org/docs/latest/user/api/versions/#obtaining-the-forgejo-version)
  does not; re-confirmed against the 16.0.5 binary today). The version
  parsers accept either case.
- **The runner prints `forgejo-runner version v13.1.0`** with a `v`
  prefix, per the
  [runner guide](https://forgejo.org/docs/latest/admin/actions/installation/binary/#downloading-and-installing-the-binary),
  which shows `forgejo-runner version v13.0.0`.
- **Asset names** are `forgejo-<ver>-linux-<arch>` and
  `forgejo-runner-<ver>-linux-<arch>` under
  `https://code.forgejo.org/forgejo/<repo>/releases/download/v<ver>/`,
  seen at the
  [runner releases page](https://code.forgejo.org/forgejo/runner/releases),
  each with `.asc` and `.sha256` siblings. The `.sha256` file is standard
  `sha256sum` format naming the asset, so `sha256sum -c` must run in the
  directory holding the asset.
- **The
  [release API's `latest`](https://code.forgejo.org/api/swagger#/repository/repoGetLatestRelease)
  is across all lines.** On an LTS line it returns the newer stable
  line's version, per the
  [upgrade guide's release life cycle](https://forgejo.org/docs/latest/admin/upgrade/#release-life-cycle).
  That is why the script confirms before a major version change.
- **Forgejo and the runner are versioned independently.**
  [Server 16.x](https://forgejo.org/releases/16.x/) pairs with runner
  13.x. The server release notes state the compatible runner range.
- **The runner's registration survives a binary swap.** It lives in the file
  named by
  [`runner.file`](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/internal/pkg/config/config.example.yaml#L23)
  in the runner config, `.runner` by default, resolved relative to the
  daemon's
  [working directory](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/contrib/forgejo-runner.service#L12)
  (`RUNNER_HOME`), not next to the config file itself. No
  re-registration after an upgrade, per the
  [runner guide's starting section](https://forgejo.org/docs/latest/admin/actions/installation/binary/#starting-the-runner).
- **An older Forgejo binary refuses to start on a database a newer release
  migrated.** It hits `log.Fatal` with "Your database ... is for a newer
  Forgejo ... Forgejo will exit to keep your database safe and unchanged"
  ([`models/gitea_migrations/migrations.go`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/models/gitea_migrations/migrations.go#L489-L496),
  [`models/forgejo_migrations/migrate.go`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/models/forgejo_migrations/migrate.go#L196)).
  This cannot corrupt data, but it does leave the service down, which is
  why `rollback` across a major version does not auto-start — it stops,
  restores `.prev`, and waits for the operator to restore the pre-upgrade
  dump first, per the
  [upgrade guide's note on this exact fatal](https://forgejo.org/docs/latest/admin/upgrade/#unexpected-database-version).
- **`forgejo dump`'s zip is not a safe database restore for PostgreSQL or
  MySQL.**
  [Forgejo's upgrade guide, "Backup" section](https://forgejo.org/docs/latest/admin/upgrade/#backup),
  says the zip
  "contains a copy of the database [but] has serious long standing open
  bugs that may introduce problems when re-injecting the SQL dump in a new
  database," and says to use `pg_dump`/`mysqldump` instead. For SQLite the
  guide says the opposite: "there is no need to dump SQLite because the
  database itself is included in the zip file already."
  [`cmd/dump.go`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/cmd/dump.go#L199-L229)
  has no flag to skip the database portion — `--skip-repository`,
  `--skip-log`, `--skip-custom-dir`, `--skip-lfs-data`,
  `--skip-attachment-data`, `--skip-package-data`, `--skip-index`, and
  `--skip-repo-archives` exist, a database skip does not — so the zip
  always carries the SQL regardless of
  [`DB_TYPE`](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#database-database).
  The script does not automate a native dump: doing so would add a new
  dependency, need database credentials, and possibly reach a remote
  database host, all inside the window the service is stopped. Instead it
  reads `DB_TYPE` from `[database]` into `FORGEJO_DB_TYPE`, warns before
  stopping anything when the database is not SQLite, gates the
  major-upgrade confirmation on a native dump having been taken, and
  words the rollback hints to match.
- **`cp -p` and `install` drop file capabilities and other extended
  attributes.** Measured today with GNU coreutils 9.7: `cp -p` copies
  mode, owner, timestamps and the POSIX ACL but no other extended
  attribute, so a `security.capability` set with `setcap` (for example
  `cap_net_bind_service` so Forgejo can bind port 443 as `git`) is lost
  from the copy; GNU `install` unlinks the destination and writes a new
  file, so it carries nothing over either.
  [`cp --preserve=all,xattr`](https://www.gnu.org/software/coreutils/manual/html_node/cp-invocation.html#index-_002d_002dpreserve)
  keeps every extended attribute and, on a kernel with SELinux, the
  context; naming `xattr` a second time turns a failed attribute copy
  from a warning into an error. An explicit `--preserve=context` fails
  with "cannot preserve security context without an SELinux-enabled
  kernel" on any other kernel, so it is never used.
  [`cp --attributes-only --preserve=all,xattr --no-preserve=timestamps OLD NEW`](https://www.gnu.org/software/coreutils/manual/html_node/cp-invocation.html#index-_002d_002dattributes_002donly)
  copies those attributes onto an existing file without
  touching its contents or its modification time, and exits 0 when the
  source has no attributes at all. `install_binary` makes `.prev` with
  the first form and applies the second to the freshly installed binary,
  so both the replacement and a later rollback (`mv`, a rename) keep the
  capability, ACL and context the operator set. There is no `getcap` or
  `getfattr` on a minimal host and no new dependency is allowed, so
  `cp`'s exit status is the check; a failed attribute copy is a hard
  stop by design, since the alternative is a binary that silently lost
  the capability it needs to bind its port, and `on_exit` prints the
  `rollback` remedy at that point.
  Also measured with coreutils 9.7: a destination that is a directory is
  treated as a directory to copy or move *into*, so a plain
  `cp SRC DEST.prev` with a directory at `DEST.prev` leaves the backup at
  `DEST.prev/<name>` and `mv -f DEST.prev DEST` with a directory at `DEST`
  puts the previous binary inside it; and `cp` writes *through* a
  destination symlink, overwriting the unrelated file it points at.
  [`-T`](https://www.gnu.org/software/coreutils/manual/html_node/cp-invocation.html#cp--no-target-directory)
  on `cp`, on `install` (there spelled `--no-target-directory` too) and on
  `mv` makes the named path the destination itself, so a directory there
  fails the operation with "cannot overwrite directory ... with
  non-directory" instead,
  and
  [`--remove-destination`](https://www.gnu.org/software/coreutils/manual/html_node/cp-invocation.html#index-_002d_002dremove_002ddestination)
  unlinks whatever entry is at the name first, so a symlink is replaced by
  a regular file and its target is left alone. `install_binary` uses
  `cp -T --remove-destination` for `.prev`, `install -T` for the new
  binary and `cp -T` for the attribute copy; `rollback` uses `mv -fT`.
  Before any of that, `require_prev_slot` refuses a `.prev` that is not a
  plain file and `rollback` refuses a directory at the binary path, both
  before the service is stopped.
- **`curl` reads root's `~/.curlrc` unless `-q` is its first argument.**
  Checked with curl 8.18: a `.curlrc` saying `location` makes
  `curl -s -o /dev/null -w '%{http_code}' http://forgejo.org/` print `200`
  instead of `301`, and `-q` anywhere but first is ignored. The script runs
  as root, so a `.curlrc` there would silently turn a reverse proxy's 302
  into a 200 in `healthz`, and could change how the other calls treat a 404
  or TLS. Every `curl` call therefore starts with `-q`, per
  [curl's manual](https://curl.se/docs/manpage.html).

### Documented install layout

Where the script's user, path, and service defaults come from, per the
stock unit files:
<https://codeberg.org/forgejo/forgejo/raw/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/contrib/systemd/forgejo.service>
and
<https://code.forgejo.org/forgejo/runner/raw/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/contrib/forgejo-runner.service>.

- **Server unit:**
  [`User=git`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/contrib/systemd/forgejo.service#L56),
  binary at `/usr/local/bin/forgejo`, config at `/etc/forgejo/app.ini`,
  [`WorkingDirectory=/var/lib/forgejo`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/contrib/systemd/forgejo.service#L58).
  A unit that sets no `User=` at all runs as root
  ([systemd's own default for a system service](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#User=)),
  so the script resolves `FORGEJO_USER` to `root` for a loaded unit that
  omits it, and falls back to `git` only when the unit is not found at
  all.
- **Runner unit:**
  [`User=runner`](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/contrib/forgejo-runner.service#L11),
  [`WorkingDirectory=/home/runner`](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/contrib/forgejo-runner.service#L12),
  [`ExecStart=... daemon -c /home/runner/runner-config.yml`](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/contrib/forgejo-runner.service#L7),
  so the `.runner` registration file lives in `/home/runner`.
  [`TimeoutStopSec=infinity`](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/contrib/forgejo-runner.service#L15)
  — systemd never gives up waiting on `systemctl stop`; the runner
  itself waits
  [`runner.shutdown_timeout`](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/internal/pkg/config/config.example.yaml#L38-L42)
  (3h in the generated config, zero or unset cancels at once) and then
  [cancels running jobs](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/internal/app/cmd/daemon.go#L93-L100).
  A unit that sets no `WorkingDirectory=` at all runs in `/`
  ([systemd's own default for a system service](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#WorkingDirectory=)),
  so the script resolves `RUNNER_HOME` to `/` for a loaded unit that
  omits it, and falls back to `/home/runner` only when the unit is not
  found at all.
- **[`systemctl show UNIT -p PROP --value`](https://www.freedesktop.org/software/systemd/man/latest/systemctl.html#show%20PATTERN%E2%80%A6%7CJOB%E2%80%A6)
  has two shapes worth knowing.**
  `ExecStart` comes back as one record,
  `{ path=/usr/local/bin/forgejo ; argv[]=/usr/local/bin/forgejo web -c /x ;
  ignore_errors=no ; ... }`, so the program and its arguments have to be
  pulled back out of that record rather than read as separate fields.
  [`Environment`](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#Environment=)
  comes back as one space-separated `KEY=VALUE ...` line. When a loaded
  unit's `ExecStart` does not come back in that `{ path=... }` shape, the
  resolvers do not fall back to the documented binary path: a stale file
  there would be upgraded while the service kept running something else, and
  the run would report success. `settings` warns and shows the default as a
  guess; `forgejo`, `runner` and `rollback` stop before anything is touched
  and ask for `FORGEJO_BIN`/`RUNNER_BIN`.
- **The `argv[]` in that record is not quoted, so it is lossy.** Checked
  on systemd 259: `--setenv` and a spaced argument produce
  `argv[]=/bin/echo -c /path with spaces/app.ini plain`, with nothing to
  say where one argument ends. A path containing a space cannot be read
  back from `systemctl show`; the script reads it truncated and the
  pre-stop checks refuse it, and the operator sets the env var instead.
  `Environment`, by contrast, *is* shell-quoted:
  `FJ_A=plain "FJ_B=has space" "FJ_C=a\"b\$c\\d'e*?"`, so a plain
  `read -a` cuts a quoted entry in two and `env` then runs the second half
  as the command. That is why the script `eval`s that one line into an
  array.
- **`LOCAL_ROOT_URL` does not change which socket Forgejo dials.** With
  `PROTOCOL = http+unix`, Forgejo's own internal client connects to the
  socket in `HTTP_ADDR` no matter what `LOCAL_ROOT_URL` says
  ([`modules/private/internal.go`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/private/internal.go#L56)).
  The script therefore resolves the socket before, and independently of,
  the URL.
- **[`systemctl show`](https://www.freedesktop.org/software/systemd/man/latest/systemctl.html#show%20PATTERN%E2%80%A6%7CJOB%E2%80%A6)
  exits `0` even for a unit that does not exist.** The only signal that
  the unit is real is `LoadState=loaded`; a unit systemd has never heard
  of reports `LoadState=not-found` with the same zero exit status, so the
  exit status cannot be what the script checks.
- **[Forgejo's CLI global flags](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/cmd/main.go#L62-L73)
  — `--config`, `--work-path`, `--custom-path` — go before the
  subcommand, not after**
  (`forgejo --config X dump`, not `forgejo dump --config X`; see also
  the
  [command-line reference](https://forgejo.org/docs/latest/admin/command-line/#forgejo---help)),
  and with none of them given the default work path is the directory
  holding the binary, per the
  [binary installation guide's general hints](https://forgejo.org/docs/latest/admin/installation/binary/#general-hints-for-using-forgejo).
  A CLI call the script makes on the operator's behalf has to pass
  `--work-path` explicitly or inherit `FORGEJO_WORK_DIR` from the unit's
  `Environment=`, or it looks for data next to the binary instead of where
  Forgejo actually keeps it.
- **A relative `--config` resolves against the daemon's current
  directory, not against the work path.** Per `modules/setting/path.go`'s
  `InitWorkPathAndCfgProvider`, a relative path is passed through
  [`filepath.Abs`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/path.go#L170),
  which resolves it there: the unit's `WorkingDirectory=`,
  or `/` when that is unset. With no `--config` at all, the file is
  `<work path>/custom/conf/app.ini`, where the work path is `--work-path`,
  then `FORGEJO_WORK_DIR`/`GITEA_WORK_DIR`, else the directory holding the
  binary —
  [`readFromEnv()` runs first, `readFromArgs()` runs after](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/path.go#L177-L178),
  and the flag's own `Set` call overwrites the environment value it finds
  already there, so the flag wins; `WorkingDirectory=` is never a
  work-path source.
  [`WORK_PATH` in `app.ini` is read only after the config file is located](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/path.go#L189),
  so it cannot move the config — but once
  `app.ini` is read, `WORK_PATH` there replaces the work path taken from
  `Environment=` or `--work-path` for everything else. This also means an
  operator-supplied `--work-path` can never override a `WORK_PATH` already
  set in `app.ini`, which is why the script refuses a `FORGEJO_WORK_PATH`
  that conflicts with `app.ini` rather than pretend the override took
  effect.
  [`cmd/web.go` only `log.Error`s about the mismatch and keeps running](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/cmd/web.go#L171),
  so the script follows `app.ini` too. Checked against the
  current `forgejo` branch source.
- **`LOCAL_ROOT_URL` is what Forgejo itself uses for local requests**, and
  its
  [default depends on `PROTOCOL`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/server.go#L288-L304)
  (see also the
  [cheat sheet](https://forgejo.org/docs/latest/admin/config-cheat-sheet/#server-server))
  — `http://unix/` for `http+unix`. Prefer it over reconstructing a URL
  from `HTTP_ADDR` and `HTTP_PORT` when it is set.
- **Forgejo refuses a relative work path from every source.** Per
  `modules/setting/path.go`, `InitWorkPathAndCfgProvider`, current
  `forgejo` branch, a relative
  [`FORGEJO_WORK_DIR`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/path.go#L124)
  or
  [`GITEA_WORK_DIR`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/path.go#L132)
  in the environment hits
  `log.Fatal("FORGEJO_WORK_DIR (work path) must be absolute path")`, a
  relative `--work-path` hits
  [`log.Fatal("--work-path must be absolute path")`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/path.go#L157),
  and a relative `WORK_PATH` in `app.ini` hits
  [`log.Fatal("WORK_PATH in %q must be absolute path")`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/path.go#L192).
  None of them is ever resolved against the unit's `WorkingDirectory=`,
  unlike `--config`. So the script does not resolve one either:
  `require_abs_work_path` refuses a relative value from any of these
  sources with the matching Forgejo message (a warning in `settings`, a
  hard stop before anything is stopped in `forgejo` and `rollback`).
  Also: Forgejo's own check for a mismatch between the unit's work path
  and `WORK_PATH` in `app.ini` is
  [`os.Stat` on both and `!os.SameFile`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/path.go#L195-L199),
  i.e. the same directory by device and inode, after `filepath.Clean` on
  the `app.ini` value; the script's `same_dir` uses bash's `-ef` for the
  same rule, so a symlink to the same directory is not a conflict, and
  equal strings never are, even for a directory that does not exist on
  this host.
- **The runner's registration file is named by
  [`runner.file`](https://code.forgejo.org/forgejo/runner/src/commit/d86d3195ac851bcfed165e692c76e5c44d47b4a9/internal/pkg/config/config.example.yaml#L23)
  in its own config**, resolved relative to the daemon's working
  directory, not to the config file's own directory. The
  [runner guide's configuration section](https://forgejo.org/docs/latest/admin/actions/installation/binary/#configuration)
  says the runner has no default config location and needs `-c`
  explicitly, which is why `RUNNER_CONFIG` has no fallback; that same
  guide looks the latest version up at `data.forgejo.org`, while the
  script asks `code.forgejo.org` — both answer, so no fallback is added
  there either.
- **No read-only Forgejo command loads `app.ini` without a side effect.**
  Running `dump` with `--help`, or `doctor check` with `--list`, exits 0
  with a nonexistent `--config` — the CLI prints help before the config is
  looked at, so neither proves anything about the config.
  [`doctor check --run paths`](https://forgejo.org/docs/latest/admin/command-line/#doctor-check)
  ([`services/doctor/paths.go`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/services/doctor/paths.go))
  does load `app.ini` and needs no database, but when
  [`[security] INTERNAL_TOKEN`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/security.go#L415-L430)
  or
  [`[oauth2] JWT_SECRET`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/security.go#L128-L135)
  are missing it writes them into `app.ini`,
  [reflows the file, and sets its mode to `0600`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/config_provider.go#L293-L294);
  it also creates
  [`data/tmp/package-upload`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/modules/setting/packages.go#L72-L78)
  under the work path. Checked against forgejo 16.0.5. The pre-stop
  checks therefore prove only that the binary runs as `FORGEJO_USER` and
  that the account can read the config and write `BACKUP_DIR`.

## Shell style

- `#!/usr/bin/env bash` and `set -euo pipefail`. Must pass `shellcheck` with
  no findings. Silence a genuine false positive with a scoped
  `# shellcheck disable=SCxxxx` and a reason, never by lowering severity.
- Quote every expansion.
- **Functions that return a value through stdout must log to stderr.** `log`
  and `warn` write to stderr for this reason. A log line written to stdout
  inside `fetch_and_verify` ends up in the caller's `$(...)` and becomes part
  of a file path.
- **`set -e` does not apply inside `$(...)`.** Bash turns errexit off in a
  command substitution unless `inherit_errexit` is set, and this script does
  not set it — doing so would change every substitution in the resolvers. So
  a function whose value is returned on stdout and read that way
  (`fetch_and_verify`, `latest_tag`, the `installed_*` functions) has to
  check every command it runs itself, with `|| die` or an explicit status
  test. A failure it does not check is silently skipped and the run carries
  on with an empty or half-written file: a failed download used to reach the
  signature check and be reported as an unverifiable signature.
- **Every operation is safe to re-run.** Same version installed means "nothing
  to do", not an error. The key import checks the keyring first.
- **Never leave the service stopped without saying so.** Any exit between
  `systemctl stop` and a successful health check must print the journal and
  the rollback command. `on_exit` does this: set `STOPPED_SVC`,
  `STOPPED_KIND`, and `STOPPED_BIN` right *before* `systemctl stop` (a stop
  that fails or is interrupted may already have taken the unit down),
  `install_binary` sets `BINARY_REPLACED` after `.prev` exists and before
  `install` runs (`install` unlinks and rewrites the destination, so a
  failed copy still needs `.prev`), and `STOPPED_SVC` is cleared only after
  the health check passes. `rollback` sets `BINARY_REPLACED=2` *before* its
  `mv`, not after, because bash runs the `INT`/`TERM` traps between commands
  and a Ctrl-C between the rename and the assignment would have `on_exit`
  call the binary untouched; `on_exit` tells a rename that happened from one
  that did not by whether `.prev` still exists. A new code path between stop
  and health must keep those assignments. `rollback --no-start`, and a
  rollback across a major version, are the one deliberate exception: they
  leave the service stopped on purpose, and they clear `STOPPED_SVC` only
  after both of the restore-then-start instruction lines have printed, so an
  interrupt between those two lines still gets the journal and the remedy from
  `on_exit`, and the stop is never silent even though it is intentional.
- **One run at a time.** `acquire_lock` runs right after the root check in
  `upgrade_forgejo`, `upgrade_runner`, and `rollback`, before anything is
  touched, and is released only by `on_exit`, last, after everything else.
  `check` and `settings` are read-only and never take the lock.
- **`eval` appears exactly once**, to turn the `Environment=` line from
  `systemctl show` back into an array. It is there because systemd emits
  that line as shell-quoted words and nothing else undoes that quoting
  without a new dependency. Do not add a second use.
- **Linux and systemd only.** Do not add macOS, BSD, or non-systemd code
  paths. `install`, `sha256sum`, and `mktemp -d` with a template are GNU
  behaviors and that is fine.
- **The usage text is the script's own header comment**, printed with
  `sed -n '2,35p'`. Adding a line to the header means updating that range.

## Testing

There is no Forgejo install on the development machine, so testing is split.

- **Verification path, tested for real.** Source the definitions (everything
  above the `# --- main` marker) and call `fetch_and_verify` against a current
  release. The runner binary is about 20 MB and is the cheap one to use.
- **Prove the negative half.** After a passing verification, append a byte to
  the downloaded file and confirm the same gpg check rejects it. A signature
  check that has only ever been seen passing guards nothing.
- **`fetch_sha256`, tested alone as well as through `fetch_and_verify`.**
  Call it directly against a real URL that 404s (an existing release path
  with the filename changed) and confirm it returns 1 with no file left
  behind; against an unresolvable host and confirm it dies with the
  transport-error message; and against a URL or stub that answers some
  other status and confirm it dies with the HTTP-status message.
- **A download that cannot succeed, through `fetch_and_verify`.** Call it
  for a version that does not exist (`0.0.0`, say) and confirm it dies with
  the "could not download" message, not with anything about a signature:
  bash drops `set -e` inside the `$(...)` both callers use, so an unchecked
  `curl` failure would fall through to the GPG check and be reported as an
  unverifiable signature.
- **The exec probe, against a `noexec` filesystem.** `unshare -Urm` gives a
  mount namespace without root:
  `unshare -Urm bash -c 'mount --bind D D && mount -o remount,bind,noexec D D
  && ...'` over a directory under `tmp/`. Point `TMPDIR` at it when sourcing
  the definitions and confirm `fetch_and_verify` dies with the `TMPDIR`
  message before it downloads anything; with an ordinary directory the probe
  passes and the download proceeds.
- **The key-refresh path, tested for real.** Point `GNUPGHOME` at a fresh,
  empty directory (`mktemp -d`, `chmod 700`), skip `ensure_key`, and call
  `fetch_and_verify` directly: confirm the log shows "refreshing the pinned
  key", the key gets imported, and the second attempt passes. Then, in
  that same empty `GNUPGHOME`, point `KEYSERVER` at an unresolvable host
  and confirm it dies on the signature error instead of passing.
- **`gpg_verdict`, tested with synthetic status text.** Feed hand-written
  `GPG_STATUS` strings straight to `gpg_verdict`, without running gpg: a
  `VALIDSIG` plus `EXPKEYSIG` (or `EXPSIG`) must print `expired`, a
  `VALIDSIG` plus `REVKEYSIG` must print `revoked`, a `VALIDSIG` ending in
  a different fingerprint must print `other-key`, `BADSIG` must print
  `bad-signature`, `NO_PUBKEY` or `ERRSIG` must print `missing-key`, and
  an empty string must print `unverifiable`. For the expired and revoked
  cases, `gpg_valid_sig`'s own predicate must still fail even though
  `VALIDSIG` is present. The real release's status from the test above,
  with its `KEYEXPIRED` lines for older subkeys, must still pass
  `gpg_valid_sig`, since `KEYEXPIRED` is not one of the rejected records.
- **`ini_get`, tested against a temp ini file.** A key assigned twice must
  return the last value; a third assignment left empty must return
  nothing, the same as unset; and a key that exists only in another
  section must not be returned for the section being queried.
- **`ini_get` interpolation, tested against a temp ini file.**
  `LOCAL_ROOT_URL = %(PROTOCOL)s://%(HTTP_ADDR)s:%(HTTP_PORT)s/` with
  those three keys set must give the assembled URL; a missing name stays
  literal; a name only in the keys before the first section resolves
  from there; a self-reference in `[server]` falls to that default
  section; nested references resolve; a cycle terminates; values without
  `%(` and with a lone `%` are unchanged. The two-key cycle is the case
  that found the first design's depth counter did not terminate in usable
  time; a cap is not a termination proof, run the pathological input. A
  referenced value containing `&` (say `HTTP_ADDR = /run/a&b/forgejo.sock`)
  must come back with the `&` intact; unquoted, bash's
  `patsub_replacement` turns it into the reference again.
- **Version parsers, tested against real output.** Download the binary and
  feed its `--version` output to `installed_forgejo` / `installed_runner`, or
  stub the binary with a one-line script that echoes the real string.
- **Confirm you are testing the edited code.** Sourcing a `defs.sh` extracted
  earlier in the session silently tests the old script. Regenerate it after
  every edit, or source directly from the script.
- **Service orchestration, not testable here.** The stop, backup, install,
  start, and health check sequence runs only on a Forgejo host. Read it
  carefully, keep it simple, and say plainly in the summary that it was not
  executed.
- **Never run `forgejo`, `runner`, or `rollback` on the development
  machine.** They require root and would stop services that do not exist
  here. `check` and the sourced verification functions are the only safe
  invocations locally.
- Run `forgejo-upgrade.sh check` after any change to `latest_tag`; it hits
  the live API.
- **Settings resolution, tested against a stub, not a real unit.** Put a
  fake `systemctl` on `PATH` under `tmp/bin/` that prints the captured real
  `systemctl show` formats (see "Documented install layout" above) for a
  fixed set of units, and run `forgejo-upgrade.sh settings` against that.
  Never point `resolve_forgejo_settings` or `resolve_runner_settings` at a
  real unit on this machine; there isn't one. A fake `app.ini` under
  `tmp/etc/`, reachable through `FORGEJO_CONFIG`, is how the `WORK_PATH`
  precedence and the `--rollback` resolution get exercised: point a stub
  unit's env at it to check that `app.ini` wins over `Environment=`/
  `--work-path` and warns on a mismatch, and call
  `resolve_forgejo_settings --rollback` with `FORGEJO_BIN` pointed at a
  missing file to confirm only the binary check is skipped. Add a stub
  runner unit with no `WorkingDirectory=` and confirm `RUNNER_HOME`
  resolves to `/`; an unknown unit still falls back to `/home/runner`. A
  relative operator override (for example `FORGEJO_CONFIG=tmp/etc/app.ini`,
  `BACKUP_DIR=backups`, or `RUNNER_HOME=runner`) must make `settings` warn
  and every other invocation die with the relative-path message. Add a
  stub Forgejo unit with no `User=` and confirm `FORGEJO_USER` resolves to
  `root`; an unknown unit still resolves to `git`. Add a stub unit whose
  `Environment=` sets `FORGEJO_WORK_DIR` to one directory while its
  `ExecStart=` also carries `--work-path` pointing at another, and confirm
  `FORGEJO_WORK_PATH` resolves to the flag's value. Set `FORGEJO_WORK_PATH`
  in the environment to a path that conflicts with `WORK_PATH` in the stub
  `app.ini` and confirm `settings` only warns while `forgejo` and
  `rollback forgejo` die on the conflict; an equal value passes silently.
  With no units and no binaries — the real `PATH` on the development
  machine — `settings` must print exactly the two "not installed" lines
  and nothing else, and `check` must print "not installed" and "-" for
  both components and exit 0 even when `curl` fails, since an absent
  component is never asked about. Every existing stub unit's output must
  stay byte-identical to what it printed before this change. Add stub
  units with a relative `--work-path` and with a relative
  `FORGEJO_WORK_DIR` in `Environment=`, and a stub `app.ini` with a
  relative `WORK_PATH`, and confirm `settings` warns with Forgejo's own
  "must be absolute path" wording while `forgejo` and `rollback forgejo`
  die on it; an app.ini whose `LOCAL_ROOT_URL` uses `%(...)s` references
  must show the expanded URL in `settings`; `same_dir` on a directory
  and a symlink to it must agree. Add stub units that are loaded but whose
  `ExecStart` comes back empty or in another shape, and confirm `settings`
  warns and marks the binary as a guess while `resolve_forgejo_settings` /
  `resolve_runner_settings` without `--tolerant` die, `--rollback` included.
- **`install_binary`, exercised from the sourced definitions under
  `tmp/`, without root.** Set a `user.*` extended attribute and an ACL
  on a fake old binary with a 2020 modification time, install a fake new
  file over it, and confirm the new file has the new contents, the old
  mode, the attribute and the ACL, and a current modification time, and
  that `.prev` has the old contents with the same attribute and ACL.
  `install -o`/`-g` with your own ids needs no root. This is the one
  part of the install sequence that can run here; the stop, backup,
  start and health check still cannot. Also: a directory at `.prev` must
  make `install_binary` fail with both that directory and the destination
  untouched; a symlink at `.prev` pointing at an unrelated file must end
  with `.prev` a regular file holding the old binary and the link's target
  unchanged; and `require_prev_slot` must pass for an absent or regular
  `.prev` and die for a directory or a symlink, a dangling one included,
  naming the type it found. `rollback`'s refusal of a directory at the
  binary path is reviewed, not run, since `rollback` is never run here, and
  `mv -fT`'s behaviour on a directory and on a symlink was measured by hand
  (see the Facts section).
- **`healthz`, tested against a `curl` stub.** Put a one-line `curl` stub
  on `PATH` under `tmp/badbin/` that prints `302` and confirm `healthz`
  fails; swap in one that prints `200` and confirm it passes. This needs
  no new dependency such as a local HTTP server. Also run it with
  `CURL_HOME` pointing at a directory whose `.curlrc` says `location` and
  `FORGEJO_URL=http://codeberg.org`: the real answer is a 302 to https, and
  `healthz` must fail rather than report the 200 found after the redirect.
- **`rollback_needs_manual_start`, exercised directly from the sourced
  definitions**, since `rollback` itself is never run on this machine. It
  is `[[ $1 == forgejo && -n $2 && ${2%%.*} != "${3%%.*}" ]]`: exit status
  0 ("manual start needed") only for Forgejo with a known current version
  whose major differs from the previous one — including when the previous
  version cannot be read, which counts as differing — and exit status 1
  ("start as usual") for a matching major, an empty current version (the
  binary is too damaged to report one), or the runner. `--no-start` is
  handled by `rollback` itself before the function is ever called, not by
  the function. Feed it these version-pair cases and check the exit
  status each way. `rollback` itself refuses a `.prev` whose version does
  not parse before stopping anything, so the empty-previous case in the
  function is a guard, not a path it reaches.
- **The lock, from the sourced definitions, with `LOCK_DIR` pointed under
  `tmp/`.** A first `acquire_lock` succeeds; a second call, in a subshell so
  it does not exit the test, dies naming the pid recorded by the first as
  still running; overwrite the `pid` file with a pid that is not running
  (for example `999999`) and confirm the message changes to "not running"
  and gives the `rm -r` remedy; confirm the directory is gone once the
  shell that acquired it exits, since `on_exit` releases it. Then, with
  `umask 0777` so that `mkdir` succeeds but the pid write fails, run
  `acquire_lock` in a fresh `bash` and confirm the lock directory is gone
  afterwards: the lock is owned from the moment `mkdir` succeeds, not from
  the pid write. Point `LOCK_DIR` at a path whose parent does not exist, and
  at a plain file, and confirm both die with the "could not create the lock
  directory" message quoting `mkdir`'s own, not the "another run holds the
  lock" one; an existing directory must still give the latter.
- **The recovery command from `on_exit`, from the sourced definitions.** Set
  `STOPPED_SVC`, `STOPPED_KIND=forgejo`, `STOPPED_BIN` and
  `BINARY_REPLACED=1`, with `FORGEJO_SERVICE`, `FORGEJO_BIN` and a
  `BACKUP_DIR` containing a space in the environment when sourcing, put a
  stub `journalctl` on `PATH`, and let the shell exit: the printed
  `rollback` line must start with those three overrides shell-quoted, or
  with `sudo` followed by them when `SUDO_USER` is set in the environment
  when sourcing, and the rollback command must come before any
  `systemctl start`/`status` hint. Repeat with `STOPPED_KIND=runner` and a
  `RUNNER_BIN` override and confirm only the runner overrides appear. Then
  set `BINARY_REPLACED=2` with a file at `STOPPED_BIN.prev` and confirm the
  message says it was not moved back and gives the rollback command; remove
  the file and confirm the back-in-place wording.
- **`FORGEJO_DB_TYPE`, against stub `app.ini` files.** One stub with
  `[database] DB_TYPE = postgres` and one with `sqlite3`; an unreadable
  config must resolve to unknown, not a guess. Since the upgrade prompt and
  backup warning cannot be run here (they need a real stop), print
  `db_is_external`, `backup_note`, and `restore_hint` straight from the
  sourced definitions for each stub, rather than only reading the source.

## Review discipline

Patterns that self-review reliably misses.

- **Nothing is pre-verified.** A rewrite of a function that "does the same
  thing" carries zero coverage until the verification path runs again. The
  script was rewritten once from memory after the original was lost, and was
  re-verified against a real release before being trusted.
- **A reviewer's symptom can be right while its remedy is wrong.** Two
  Copilot findings asked for relative work paths to be resolved against
  `WorkingDirectory=`; Forgejo's `InitWorkPathAndCfgProvider` refuses them
  with `log.Fatal` instead, so the right fix was to refuse too, and the
  "false conflict" half of the finding was real in a different form
  (`os.SameFile`, not string equality). Before implementing a remedy that
  says "Forgejo does X with this value", read the function that consumes
  the value.
- **When fixing one half of a contract, grep for the other half.** Pairs in
  this repo: the shared `parse_forgejo_version` / `parse_runner_version`
  parsers, used by both `installed_*` and the post-download check — a
  change to the sed pattern must be tested against both a real `--version`
  string and the exact-match compare in `upgrade_forgejo` /
  `upgrade_runner`; the defaults block in the script and the variable
  table in `README.md`; the header comment and the `sed` range that prints
  it; the subcommand `case` and the command table in `README.md`; the
  settings tables in `README.md` and the two `resolve_*_settings`
  functions; the header's override list and the README tables.
- **An ad hoc check that matches nothing is broken, not green.** A `grep -q`
  aimed at the wrong string produces a passing-looking result. Make one-off
  checks fail loudly on zero matches.
- **Review the rendered text, not just the changed lines.** The hardening
  section of `README.md` is followed by an operator editing a live server.
  A wrong `app.ini` key or drop-in directive fails silently or locks them
  out. Check every key name against
  [Forgejo's configuration cheat sheet](https://forgejo.org/docs/latest/admin/config-cheat-sheet/).
- **Report outcomes faithfully.** Say which paths ran and which did not.
- **End with a fresh-context review.** Before opening a PR, have the final
  diff read by a reviewer who has seen only the diff, and ask "do these hunks
  agree with each other?", not "is each hunk correct?".
- **If it is wrong, it is wrong.** A sentence the source contradicts is
  corrected in place, in the same change that cites the source. No separate
  "rewordings" section, no hedge, no leaving it because it was there first.

## Out of scope

- Docker, Podman, or package-manager installs of Forgejo. The script assumes
  a single binary under `/usr/local/bin` managed by systemd. Container users
  change an image tag instead.
- Gitea. It shares ancestry and a similar layout, but its release URLs,
  signing key, and version strings differ. Do not add a compatibility mode.
- Major-version migration logic. The script warns and confirms; reading the
  release notes and restoring a dump if needed remain the operator's job.
- Managing `app.ini` or the systemd units. The README explains hardening;
  the script never edits configuration.

## Markdown style

- All markdown must pass VS Code's default markdownlint config.
- `.vscode/settings.json` sets `"markdownlint.config": {"MD024": false}`.
- Wrap prose at 80 columns. A single shell command in a fenced block may run
  longer so it stays one command.
- Cite with inline links, `[text](url)`, where the link text is the words
  of the claim.
- A URL that has to stand alone goes in angle brackets.
- **Every URL is checked by fetching it.** `tmp/verify-links.sh` (gitignored,
  recreate it from the description here if it is gone) extracts every
  `https://` URL from the README, AGENTS.md and the script, requires HTTP
  200, requires a `#fragment` to match an element id on the page, requires
  a `#Lnn` fragment on a pinned source link to exist and to contain the
  phrase the fact quotes, and checks CVE ids through MITRE's API because
  cve.org itself answers 200 for any id. Run it after any change that adds
  or moves a link. Source links are pinned to the commits named in the
  Facts preamble; when a fact is re-verified against a newer commit, move
  the pin and the line numbers together.

## GitHub releases

- Releases are made by version tag, not branch.
- Tags are prefixed with `v`. Release titles exclude the prefix.
- Attach `forgejo-upgrade.sh` to the release so it can be fetched with one
  `curl`.

## Documentation

`README.md` is deliberately the whole manual: usage, configuration, and
hardening for a one-script project. If it grows past those three topics,
move the hardening guide to `docs/hardening.md` and leave the README as an
overview and pointer. Update the docs in the same change as the behavior
they describe.
