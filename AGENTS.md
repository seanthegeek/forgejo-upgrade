# AGENTS.md

## Project overview

One Bash script, `forgejo-upgrade.sh`, that upgrades binary installs of
[Forgejo](https://forgejo.org) and forgejo-runner on a systemd host. It
downloads a release, checks the GPG signature and sha256, backs up, swaps the
binary keeping the old one, restarts the service, and verifies health.
`README.md` is the overview: install and usage for the two services;
`docs/` holds how the script works, configuration, and hardening.

No application code and no database. The deliverable is a script an
operator runs as root on a machine they cannot afford to break, so caution in
the script beats cleverness. It is developed on a machine that does not run
Forgejo and deployed elsewhere by hand. CI on GitHub and Forgejo runs the
linter, the test suites and coverage on every pull request and on every push
to `main`; see "Testing" below.

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
  `User-Agent`. `docs/hardening.md`'s "CVSS 9.9" for the 16.0.4 template
  repository fix was wrongly called unsupported after reading only
  Forgejo's notes.
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
- **`forgejo dump` creates the archive at the umask and only chmods it to
  0600 on success.** The file is made with
  [`os.Create`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/cmd/dump.go#L304),
  so its mode is whatever the process umask allows, commonly 0644;
  [`app.ini` goes into the zip](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/cmd/dump.go#L334-L338)
  next to the database copy; and the
  [`os.Chmod` to `0o600`](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/cmd/dump.go#L419-L421)
  runs only after the archive is finished. Only an archiving error
  [removes the file](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/cmd/dump.go#L414);
  every other `fatal` between the create and the chmod, and any interrupt,
  leaves the partial archive in place at the umask's mode, holding
  `app.ini` and database data in a `BACKUP_DIR` the operator may share.
  There is no refusal for a file that already exists — `os.Create`
  truncates — and the
  [`.zip` suffix is stripped and re-appended](https://codeberg.org/forgejo/forgejo/src/commit/a0ad12ba49c03d56347b95f1b40af0a304746e00/cmd/dump.go#L254-L260),
  so `--file X.zip` opens exactly `X.zip`. So the script creates that
  file itself first, empty, mode 0600, as `FORGEJO_USER`, and Forgejo's
  own open truncates into it: a truncating open never changes an existing
  file's mode, measured under `umask 022` with `install -m 600 /dev/null f`
  (GNU coreutils 9.7, and uutils 0.8.0 which is what `install` happens to
  be on this development machine) followed by a truncating write from the
  shell and from a Python `open(f, 'w')`: the file stayed at 0600, while
  the same write with no pre-creation gave 0644. A umask around the dump
  was not used: it would have to survive `runuser`'s PAM session or
  `sudo`'s sudoers `umask` handling, and this depends on neither.
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
  before the service is stopped. `rollback` runs `require_prev_slot` itself
  as its first check, because resolving with `--rollback` skips the
  resolvers' copy of it and its own `[[ -x $bin.prev ]]` test follows a
  symbolic link: without that check an executable link at `.prev` would
  pass, and the `mv -fT` would install the link itself in front of the
  service rather than the binary an upgrade set aside.
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
  `sed -n '2,37p'`. Adding a line to the header means updating that range.

## Testing

There is no Forgejo install on the development machine, so the suite is
split into an offline half and a live half. `tests/helpers.bash` documents
the helper API (`in_script`, `snippet_file`, `stub_path`, `fake_bin`,
`source_lines`, `skip_unless`, the `assert_*` functions) in its own comments;
read it before writing a new test.

### How to run

Install the dev-only tools once, on Debian or Ubuntu:

```bash
sudo apt install bats kcov attr acl shellcheck
```

The suite needs bats 1.5.0 or later, for `run --separate-stderr`; every
test file says so with `bats_require_minimum_version 1.5.0` and stops with
a clear message on an older one. Debian 12 (1.8), Ubuntu 24.04 (1.10) and
Ubuntu 26.04 (1.13) are fine. Two Ubuntu releases need a detour: 24.04 has
no `kcov` package — it is in 22.04 and again from 25.04 on — so leave
`kcov` out of that line there and let CI measure coverage; and 22.04 ships
bats 1.2.1, so there install everything but `bats` from apt, clone
[bats-core](https://github.com/bats-core/bats-core) somewhere, and point
every target at it with `BATS=/path/to/bats-core/bin/bats`.

This is separate from the script's own dependency list under "No new
dependencies," above, which is unchanged.

- `make lint` — shellcheck over the script, `tests/helpers.bash`, every
  `.bats` file, and the fixture stub binaries.
- `make test` — the offline suite, `tests/unit/`. No network.
- `make test-live` — the suite that talks to the release API and a
  keyserver, `tests/live/`.
- `make coverage` / `make coverage-all` — kcov line coverage of the offline
  suite alone, or of both suites merged.
- `bats tests/unit/lock.bats` — run one file.
- `bats --filter 'process that is gone' tests/unit` — run one test,
  matched against (part of) its `@test` name.
- `make test BATS=/path/to/bats-core/bin/bats` — when `bats` is not on
  `PATH`; every target takes a `BATS`, `KCOV`, or `SHELLCHECK` override the
  same way.

### The one harness rule, and why

Script code runs in a child bash, started by `in_script`, and never in the
bats process itself. Sourcing `forgejo-upgrade.sh` arms `trap on_exit EXIT`,
and bats owns the `EXIT` trap of its own test process, so sourcing the
script there would replace it and bats would lose track of the test. The
script's source guard — `if (return 0 2>/dev/null); then return 0; fi`,
right after `# --- main` and before the command dispatch — is what makes
`source forgejo-upgrade.sh` load the definitions and skip the dispatch.
Everything above the guard still runs: sourcing creates `WORKDIR` and arms
the `EXIT`, `INT` and `TERM` traps, which is what the harness relies on for
cleanup. The guard detects sourcing by whether `return` outside a function
succeeds, not by comparing `$0`, because the test suite deliberately sets
`$0` to the script's own path. That is on purpose: inside `in_script`, `$0`
has to be the real path so that `rollback_command`'s `%q "$0"` and the
usage text's `sed -n '2,37p' "$0"` see it rather than bash's own.

Two facts about that child bash are worth recording. kcov traces a bash
program through a `PS4` that expands `${BASH_SOURCE}`, and a command at the
top level of a `bash -c` string has no `BASH_SOURCE`: once the script's
`set -u` is in force such a snippet dies with an unbound-variable error, so
a bare `bash -c` that sources the script passes under plain bats and fails
under `make coverage`. That is why every snippet is written to a file by
`snippet_file` and run from there. `snippet_file` also sets `$0` through
`BASH_ARGV0`, which needs bash 5.0 or later; CI has 5.2 on trixie and 5.3
on Ubuntu 26.04, so an older bash is the one thing that would break the
harness rather than a test.

### Unit versus live

`tests/unit/` is offline: stub `systemctl`, `curl`, and `journalctl`
binaries and fixture `app.ini`/`runner.yml` files stand in for a real host.
`tests/live/` talks to the real release API, a real keyserver, and
downloads a real runner release.

Run `make test-live` after any change to `fetch_and_verify`, `ensure_key`,
`latest_tag`, `fetch_sha256`, `gpg_valid_sig`/`gpg_verdict`, or either
version parser, and put its output in the change summary — lint or the
offline suite alone is not evidence for these functions. What it proves,
one sentence per file:

- `fetch_and_verify.bats` — a real runner release downloads, verifies, and
  is reported as the version it says it is; one appended byte to a
  verified copy is rejected with the verdict `bad-signature`.
- `fetch_sha256.bats` — a real 404 makes `fetch_sha256` return 1 silently,
  leaving no error page behind; the "not published" wording an operator
  reads belongs to its caller, `fetch_and_verify`, and is checked
  structurally where it is written. A host that does not resolve stops the
  run with the transport-error message.
- `key_refresh.bats` — an empty keyring is rescued by refreshing exactly
  the pinned key, and an unreachable keyserver stops the run with the
  "could not refresh the key" message — `fetch_and_verify`'s own wording,
  not `die_bad_signature`'s.
- `latest_tag.bats` — the release API's `tag_name` reads correctly for
  both repos, and `check` really asks it: on a host whose units systemd
  does not know, a `FORGEJO_BIN` the operator names makes Forgejo present,
  and the table comes back with that binary's version and a live `N.N.N`
  in the latest column, while the unnamed runner stays "not installed"
  with a dash and no call made for it.
- `healthz_curlrc.bats` — `-q` defeats a `.curlrc` saying `location`
  against a real redirecting server. The source audit of the same fact
  needs no network and lives in `tests/unit/healthz.bats`.

The `unshare`-based noexec tests in `exec_probe.bats` skip where a noexec
bind mount cannot be made without root: under Docker's default seccomp
profile, and on GitHub's Ubuntu runner image, where the namespace can be
entered once AppArmor's restriction is lifted with `sysctl` but the mount
inside it is still refused, so both CIs skip them and a developer machine
is where they run. In `install_binary.bats` the ACL
case skips without `setfacl` and `getfacl`, and the extended-attribute case
skips without `setfattr` or `python3`.

### What cannot run anywhere

The stop, backup, install, start, health-check sequence in
`upgrade_forgejo` and `upgrade_runner`, and `rollback` itself, run only on
a Forgejo host. They are reviewed, not executed, and every summary says so
plainly. `check`, `settings`, and the sourced functions are the only safe
invocations on this machine — never run `forgejo-upgrade.sh forgejo`,
`runner`, or `rollback` here.

What the suite does for those paths instead is structural, through
`source_lines` (which fails loudly on zero matches, never a bare
`grep -q`): `rollback.bats` checks that `require_prev_slot` runs before
the `-x` test and before `systemctl stop`, and that `BINARY_REPLACED=2` is
set before the `mv` that consumes `.prev`; `dump.bats` checks that the
dump archive's 0600 pre-creation sits between the stop and the
`dump --file` call.

Some bullets in "Facts about Forgejo release artifacts" have no test at
all, because they describe what Forgejo, its runner, or systemd does
rather than what this script does, or because seeing them needs a running
install. They are listed here so the gap is a decision on the record and
not mistaken for coverage:

- **`latest` is across release lines**, and the major-version confirmation
  it forces: the prompt lives inside `upgrade_forgejo`, which never runs
  here.
- **Forgejo and the runner are versioned independently**: the script never
  compares the two, so there is nothing to assert.
- **`TimeoutStopSec=infinity` and `runner.shutdown_timeout`**: systemd and
  the runner do that waiting, not the script.
- **No read-only Forgejo command loads `app.ini` without a side effect**
  (`doctor check --run paths` writes `INTERNAL_TOKEN` and creates
  directories): it is the reason the pre-stop checks prove only what they
  prove, and confirming it needs a real install.
- **The runner's registration survives a binary swap**: what the script
  does about it — resolve `RUNNER_REG_FILE` and say so when the file is
  missing — is covered in `settings.bats`; that the daemon still accepts
  the registration afterwards is upstream's behaviour.
- **An older Forgejo binary refuses to start on a migrated database**:
  `rollback_needs_manual_start` and the wording around it are tested; the
  `log.Fatal` itself is Forgejo's.
- **`forgejo dump`'s zip is not a safe database restore for PostgreSQL or
  MySQL**: the messages that follow from it are tested in `db_type.bats`
  and `on_exit.bats`; the upstream bug is not ours to reproduce.

The lossy `argv[]` is not on that list: the script's own answer to it —
reading a `-c` path back truncated at the space and refusing it before
anything is stopped — is the `fj-space` case in `settings.bats`.

### Rules for new work

- Every bullet in "Facts about Forgejo release artifacts" has a test that
  names it, in its `@test` sentence or its file's header comment, unless it
  is on the exemption list in "What cannot run anywhere," above. Adding a
  bullet to that list is a decision to write down, not a way out of a test.
- When a fact moves or changes, its test changes in the same commit.
- A new failure message gets its exact wording asserted, not just its
  presence.
- A structural check goes through `source_lines`, never a bare `grep -q`.
- A test that needs a real unit uses the stub at
  `tests/fixtures/bin/systemctl` (it answers for the stock `forgejo` and
  `forgejo-runner` units, plus the `fj-*` and `runner-*` fixture units) or
  `tests/fixtures/nounits/systemctl` for "nothing installed."
- Fixtures live in `tests/fixtures/`, never in `tmp/`.
- kcov's coverage percentage is a trend, not a truth: its notion of an
  executable bash line is a heuristic, and the paths in "What cannot run
  anywhere," above, are why the number will never reach 100.

### What each test file covers

`tests/unit/`

- `guard.bats` — sourcing is silent and exits 0; a bogus subcommand still
  prints usage and exits 1; the usage `sed` range ends on the last header
  line.
- `version.bats` — the version parsers and `installed_forgejo`/
  `installed_runner`, including a failing or unparseable binary.
- `gpg.bats` — `gpg_verdict`/`gpg_valid_sig` over synthetic status text,
  and every `die_bad_signature` wording.
- `fetch_sha256.bats` — the 500, transport-error, and 404 cases, against a
  curl stub.
- `exec_probe.bats` — `require_exec_workdir` and a real noexec bind mount.
- `ini_get.bats` — duplicate keys, last-wins, and the full interpolation
  matrix, including the two-key cycle and the `&` case.
- `yaml_get.bats` — `runner.file` and neighboring keys from a fixture
  runner config.
- `settings.bats` — the whole resolver matrix for both components,
  including the two stock units' blocks asserted line for line, the
  `http+unix` socket, and the `-c` path that `argv[]` truncates.
- `check.bats` — `check` with nothing installed: "not installed," no API
  call, exit 0.
- `install_binary.bats` — attribute, ACL, and mode preservation, and every
  `.prev` shape (absent, file, directory, symlink, dangling symlink).
- `rollback.bats` — `rollback_needs_manual_start`, and the structural
  ordering guarantees inside `rollback`.
- `dump.bats` — the 0600 pre-creation primitive and its placement.
- `healthz.bats` — the stub-curl 200/302/refused cases and the `-q`
  source audit.
- `lock.bats` — `acquire_lock` and its failure and release paths.
- `on_exit.bats` — the printed rollback command, its overrides, the
  `sudo` prefix, and its ordering before the start/status hint.
- `db_type.bats` — `FORGEJO_DB_TYPE` and `db_is_external`/`backup_note`/
  `restore_hint`.
- `docs.bats` — every relative link in `README.md`, `docs/*.md`,
  `AGENTS.md`, `CLAUDE.md` and `CHANGELOG.md` resolves to a real file and,
  if it has one, a real anchor; the checker itself fails on a synthetic
  broken link.
- `release.bats` — `SCRIPT_VERSION`'s shape, that `version`/`--version`
  print it and nothing else, that the header names the subcommand, that
  `CHANGELOG.md`'s first two sections are `[Unreleased]` and the current
  version with a link reference each, and both `make release-check` and
  `make release-notes`, passing and failing, including a tag carrying
  shell metacharacters that must be reported verbatim and never run.

`tests/live/`

- `fetch_and_verify.bats` — the real runner release, verified and parsed,
  and the tampered-file rejection.
- `fetch_sha256.bats` — a real 404 and a real host that does not resolve.
- `healthz_curlrc.bats` — a real redirecting server against `.curlrc`.
- `key_refresh.bats` — a real empty-keyring refresh and a real
  unreachable keyserver.
- `latest_tag.bats` — the real release API for both repos, and `check`.

## Review discipline

Patterns that self-review reliably misses.

- **Nothing is pre-verified.** A rewrite of a function that "does the same
  thing" carries zero coverage until the verification path runs again. The
  script was rewritten once from memory after the original was lost, and was
  re-verified against a real release before being trusted. A rewrite is
  trusted again once `make test` and `make test-live` both pass.
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
  table in `docs/configuration.md`; the header comment and the `sed`
  range that prints it; the subcommand `case` and the command table in
  `README.md`; the settings tables in `docs/configuration.md` and the
  two `resolve_*_settings` functions; the header's override list and the
  tables in `docs/configuration.md`; `SCRIPT_VERSION`, the first released
  section of `CHANGELOG.md`, and the tag `release-check` verifies them
  against.
- **An ad hoc check that matches nothing is broken, not green.** A `grep -q`
  aimed at the wrong string produces a passing-looking result. Make one-off
  checks fail loudly on zero matches.
- **Review the rendered text, not just the changed lines.**
  `docs/hardening.md` is followed by an operator editing a live server.
  A wrong `app.ini` key or drop-in directive fails silently or locks them
  out. Check every key name against
  [Forgejo's configuration cheat sheet](https://forgejo.org/docs/latest/admin/config-cheat-sheet/).
- **Report outcomes faithfully.** Say which paths ran and which did not.
- **End with a fresh-context review.** The reviewer sees only the repo and
  the diff, and its prompt is the verbatim text in "The fresh-context
  review prompt," below; the working agent adds no change-specific
  questions to it, because a checklist written by the author of the change
  points the reviewer at what the author already thought of — anything
  specific the author wants checked goes in the PR description for the
  human reviewer, or is checked by the author directly. The review runs on
  the final diff, and after every round of fixes it runs again, fresh,
  until a pass comes back with nothing required. A Copilot round with zero
  findings on the final commit, suppressed comments included, is part of
  "done."
  [Copilot code review reads AGENTS.md and CLAUDE.md
  too](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/request-a-code-review/use-code-review#customizing-copilots-reviews-with-custom-instructions),
  so it is not unprompted; it is required because it did not write the
  change and sees only the PR, not the session.
- **A value from outside the checkout is untrusted the moment it reaches
  a shell line.** A tag name, a ref, a CI-supplied value, a file name an
  operator or a forge hands in: each one is data, not code, until
  something in the diff proves otherwise. In a Makefile recipe it is read
  as `$${VAR}` from the environment, never expanded as `$(VAR)` into
  recipe text: `TAG` is the one value a forge supplies, and it is the one
  read that way; every `$(VAR)` the recipes expand today (`BATS`, `KCOV`,
  `SHELLCHECK`, `REPORT_DIR`, `CHANGELOG`, and the Makefile's own
  `SCRIPT`, `SCRIPT_VERSION`, `CURDIR`, `MAKE`, `SHELL_SOURCES`) is set by
  the developer's `make` line, the Makefile itself, or the test suite,
  never from workflow event data. In a workflow `run:` step it reaches the
  script through the environment, a `GITHUB_*` default variable or an
  `env:` mapping, never as a `${{ }}` expression pasted into the script.
  Give it a hostile-value test, like the metacharacter-tag case in
  `tests/unit/release.bats`, added in PR #4 after Copilot's review found
  the `$(TAG)` expansion in the Makefile's `release-check` recipe.
- **A command an operator will paste is code.** It gets typed into a root
  shell on a host that cannot afford to break, so review every command in
  `README.md` and `docs/` the way the install command in `README.md`
  already is: safe on failure (`curl -qfsS`, `&&` chaining, no partial
  install left behind), and each flag that changes what happens on failure
  explained once, the first time it appears — those are the ones an
  operator must understand before running the command.
- **If it is wrong, it is wrong.** A sentence the source contradicts is
  corrected in place, in the same change that cites the source. No separate
  "rewordings" section, no hedge, no leaving it because it was there first.

### The fresh-context review prompt

Hand this to the reviewer exactly as written. Before that, commit every
fix (the diff command below compares commits, so an uncommitted fix is
invisible to the reviewer; `git status --porcelain` must print nothing) and
run `git fetch origin`: the command names `origin/main`, the fetched base,
because a fetch never moves the local `main`, and a merge base taken from a
stale local branch would put already-merged commits into the review. The
only additions allowed are the branch base named in the diff command, if it
is not `origin/main`, and a one-line header naming the repository path and
branch. Two things the prompt's "do not change any file" does not forbid:
`tmp/verify-links.sh` and the cache it writes under `tmp/` are gitignored
scratch, so a reviewer in a fresh clone recreates the script from "Markdown
style" and says so; and its three release-URL failures before a version is
tagged are the expected ones "Releases" describes, not findings.

```text
You are reviewing the diff `git diff origin/main...HEAD` of this
repository, and you have seen none of the work that produced it. Read
AGENTS.md from the checkout first, then read every changed file whole,
not just the diff hunks. This is a read-only review: run the linter and
the offline test suite; run `make test-live` when the diff touches any
function AGENTS.md's Testing section names for it; when the diff touches
markdown, run the markdownlint command from `.forgejo/workflows/ci.yml`
and `tmp/verify-links.sh`; and do not change any file.

Your job is to find what is wrong, not to confirm that the change works.
Security comes first, but it is not the whole job: treat every value that
comes from outside the repository as hostile until proven otherwise,
treat every claim in prose or a comment as unverified until you have
checked it against the code or the upstream source it cites, and
remember that every command here is run by root on a host that cannot
afford to break. A review that finds nothing still has to say what it
looked for and could not find; it never just says the diff is fine.

Ask whether the hunks agree with each other, not only whether each hunk
is correct on its own.

Assume the diff contains at least one place where a value from outside
the repository reaches a shell line unescaped, at least one command an
operator would paste that misbehaves on failure, and at least one
sentence in prose or a comment that the code or an upstream source
contradicts. Find them, or say plainly why you could not.

For each finding, give the file and line, what is wrong, why it matters
to an operator, and the concrete fix. Say explicitly what checks out
clean, and list anything you could not verify.

End with a verdict: mergeable as is, mergeable after the listed fixes, or
not mergeable, with the fixes in the order to apply them. Do not fix
anything yourself.
```

## Out of scope

- Docker, Podman, or package-manager installs of Forgejo. The script assumes
  a single binary under `/usr/local/bin` managed by systemd. Container users
  change an image tag instead.
- Gitea. It shares ancestry and a similar layout, but its release URLs,
  signing key, and version strings differ. Do not add a compatibility mode.
- Major-version migration logic. The script warns and confirms; reading the
  release notes and restoring a dump if needed remain the operator's job.
- Managing `app.ini` or the systemd units. `docs/hardening.md` explains
  hardening; the script never edits configuration.

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
  `https://` URL from `README.md`, `docs/*.md`, `AGENTS.md`, `CHANGELOG.md`
  and the script, requires HTTP 200, requires a `#fragment` to match an element
  id on the page, requires a `#Lnn` fragment on a pinned source link to
  exist and to contain the phrase the fact quotes, and checks CVE ids
  through MITRE's API because
  cve.org itself answers 200 for any id. Run it after any change that adds
  or moves a link. Source links are pinned to the commits named in the
  Facts preamble; when a fact is re-verified against a newer commit, move
  the pin and the line numbers together.

## Releases

- Releases are made by version tag, not branch. Tags are prefixed with `v`;
  release titles exclude the prefix.
- The process: bump `SCRIPT_VERSION` in `forgejo-upgrade.sh`; move the
  `Unreleased` bullets in `CHANGELOG.md` under a new
  `## [x.y.z] - YYYY-MM-DD` heading and add its link reference at the
  bottom; merge; tag `vX.Y.Z` on `main` and push the tag. Pushing that tag
  needs the author's explicit push permission, per Conventions, the same
  as pushing a commit to `main`.
- Pushing the tag triggers the release workflows
  (`.github/workflows/release.yml`, `.forgejo/workflows/release.yml`),
  which lint and run the offline test suite, then verify that the tag,
  `SCRIPT_VERSION`, and CHANGELOG.md's first released section all agree
  (`make release-check`), then publish the release with
  `forgejo-upgrade.sh` attached, that section's body as the release notes
  (`make release-notes`), and the tag without its `v` as the title. A tag
  that is not `v<SCRIPT_VERSION>` (a `v0.1.0-rc1`, say) still fires the
  workflows, but fails at the `release-check` step by design, and nothing
  is published.
- Between merge and the tag push, the `[x.y.z]` and `[Unreleased]` links
  at the bottom of `CHANGELOG.md` and the README's
  `releases/latest/download` link all answer 404, since none of them has
  anything to point at yet. The first two point at the tag itself and
  clear as soon as the tag is pushed; the third points at `latest`, which
  needs a published release, not just a tag, so it clears only once the
  release workflow has finished. Run `tmp/verify-links.sh` after the
  release workflow finishes, not merely after the tag is pushed.

## Documentation

`README.md` is deliberately an overview and a pointer, not the whole
manual: the project summary, installation, and usage for a one-script
project. Each page under `docs/` — `how-it-works.md`, `configuration.md`,
`hardening.md` — covers exactly one topic an operator reads start to
finish, linked from the README's "Documentation" index. Update the docs
in the same change as the behavior they describe. A relative link between
`README.md`, `docs/*.md`, `AGENTS.md`, `CLAUDE.md` and `CHANGELOG.md` (a
path, with or without a `#anchor`) is checked by `tests/unit/docs.bats`,
which fails if the target file or heading does not exist; a `https://` URL
in any of them is checked separately, by `tmp/verify-links.sh` (see
"Markdown style", above).
