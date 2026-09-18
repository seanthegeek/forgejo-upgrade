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
- **Never weaken verification to make a download succeed.** No skipping the
  signature check, no `--insecure`, no falling back to an unverified file, no
  accepting a signature from a key other than the one pinned in
  `RELEASE_KEY`. A failed verification stops the upgrade and says why.
- **The pinned fingerprint is the trust root. Changing it is a security
  decision, not a fix.** If a signature check starts failing, first check
  whether the release moved to a new subkey of the same primary key, which
  the current check already tolerates. Only change `RELEASE_KEY` after
  confirming the new fingerprint on <https://forgejo.org/download/> and name
  that source in the commit message.
- **Every failure message must be actionable.** Name what was expected, what
  was observed, and the remedy. Any exit that leaves a service stopped or
  unhealthy must print the journal and the exact command to recover, which is
  `systemctl start` when the binary was not replaced and `rollback` when it
  was.
- **Do not suppress errors blanketly.** `|| true`, `|| warn`, and
  `2>/dev/null` are for a specific failure you have decided is acceptable and
  can say why. In the script:
  - `on_exit`: `journalctl ... || warn` — the journal may be unreadable; the
    remedy must still print, and the exit status must be preserved either
    way.
  - `on_exit`: `rm -rf "$WORKDIR" || warn` — a cleanup failure must not
    replace the real exit status.
  - `ensure_key`: `gpg --list-keys "$RELEASE_KEY" >/dev/null 2>&1` — only the
    exit status ("is the key present") is used.
  - `fetch_and_verify`: `gpg --verify ... 2>/dev/null` — the status-fd
    `VALIDSIG` line is what is checked, not the human-readable output.
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
  - `healthz`: `curl ... >/dev/null 2>&1` — connection refused is expected
    while the service is still starting. Each attempt is capped with
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
  pointers, not evidence. One write-up claimed the 16.0.4 template
  repository bug needed no account. Forgejo's release notes say it needs a
  malicious template repository, which needs an account. The docs showed a
  capitalized version string the binary does not print. Check the artifact.
- **Read official documentation in full before changing behavior that
  depends on it.** The upgrade guide, the binary installation guide, and the
  runner installation guide are short. Read the page, not the heading.
- **No new dependencies.** The script needs `bash`, `curl`, `gpg`, `runuser`
  (util-linux) or `sudo`, `sed`, `grep`, GNU coreutils (`install`,
  `sha256sum`, `mktemp`, `cp`, `date`, `stat`), and systemd
  (`systemctl`, `journalctl`). Do not add `jq`, Python, or anything else an
  operator would have to install on a server first. The `tag_name` parser
  uses `sed` for exactly this reason.

## Facts about Forgejo release artifacts

Each of these was learned by running the script against a real release and
having it fail. Do not change the code that depends on them without
re-checking against a current release.

- **Releases are signed by a rotating subkey, not the primary key.** gpg's
  `VALIDSIG` status line lists the signing subkey fingerprint first and the
  primary key fingerprint last. The check matches the primary fingerprint at
  the end of the line, so subkey rotation does not break it. Matching the
  primary fingerprint right after `VALIDSIG` fails on every release.
- **The primary key fingerprint is
  `EB114F5E6C0DC2BCDD183550A4B61A2DC5923710`** per
  <https://forgejo.org/download/>. The same key signs the runner.
- **The server binary prints a lowercase `forgejo version 16.0.5+gitea-...`**
  even though the docs show it capitalized (re-confirmed against the 16.0.5
  binary today). The version parsers accept either case.
- **The runner prints `forgejo-runner version v13.1.0`** with a `v` prefix.
- **Asset names** are `forgejo-<ver>-linux-<arch>` and
  `forgejo-runner-<ver>-linux-<arch>` under
  `https://code.forgejo.org/forgejo/<repo>/releases/download/v<ver>/`, each
  with `.asc` and `.sha256` siblings. The `.sha256` file is standard
  `sha256sum` format naming the asset, so `sha256sum -c` must run in the
  directory holding the asset.
- **The release API's `latest` is across all lines.** On an LTS line it
  returns the newer stable line's version. That is why the script confirms
  before a major version change.
- **Forgejo and the runner are versioned independently.** Server 16.x pairs
  with runner 13.x. The server release notes state the compatible runner
  range.
- **The runner's registration survives a binary swap.** It lives in the
  `.runner` file next to the config. No re-registration after an upgrade.

### Documented install layout

Where the script's user, path, and service defaults come from, per the
stock unit files:
<https://code.forgejo.org/forgejo/forgejo/raw/branch/forgejo/contrib/systemd/forgejo.service>
and
<https://code.forgejo.org/forgejo/runner/raw/branch/main/contrib/forgejo-runner.service>.

- **Server unit:** `User=git`, binary at `/usr/local/bin/forgejo`, config at
  `/etc/forgejo/app.ini`, `WorkingDirectory=/var/lib/forgejo`.
- **Runner unit:** `User=runner`, `WorkingDirectory=/home/runner`,
  `ExecStart=... daemon -c /home/runner/runner-config.yml`, so the `.runner`
  registration file lives in `/home/runner`. `TimeoutStopSec=infinity` — the
  stock unit never gives up waiting for in-flight jobs on `systemctl stop`.
- **`systemctl show UNIT -p PROP --value` has two shapes worth knowing.**
  `ExecStart` comes back as one record,
  `{ path=/usr/local/bin/forgejo ; argv[]=/usr/local/bin/forgejo web -c /x ;
  ignore_errors=no ; ... }`, so the program and its arguments have to be
  pulled back out of that record rather than read as separate fields.
  `Environment` comes back as one space-separated `KEY=VALUE ...` line.
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
  (`modules/private/internal.go`). The script therefore resolves the
  socket before, and independently of, the URL.
- **`systemctl show` exits `0` even for a unit that does not exist.** The
  only signal that the unit is real is `LoadState=loaded`; a unit systemd
  has never heard of reports `LoadState=not-found` with the same zero exit
  status, so the exit status cannot be what the script checks.
- **Forgejo's CLI global flags — `--config`, `--work-path`,
  `--custom-path` — go before the subcommand, not after**
  (`forgejo --config X dump`, not `forgejo dump --config X`), and with none
  of them given the default work path is the directory holding the binary.
  A CLI call the script makes on the operator's behalf has to pass
  `--work-path` explicitly or inherit `FORGEJO_WORK_DIR` from the unit's
  `Environment=`, or it looks for data next to the binary instead of where
  Forgejo actually keeps it.
- **A relative `--config` resolves against the daemon's current
  directory, not against the work path.** Per `modules/setting/path.go`'s
  `InitWorkPathAndCfgProvider`, a relative path is passed through
  `filepath.Abs`, which resolves it there: the unit's `WorkingDirectory=`,
  or `/` when that is unset. With no `--config` at all, the file is
  `<work path>/custom/conf/app.ini`, where the work path is
  `FORGEJO_WORK_DIR`/`GITEA_WORK_DIR`, then `--work-path`, else the
  directory holding the binary; `WorkingDirectory=` is never a work-path
  source. `WORK_PATH` in `app.ini` is read only after the config file is
  located, so it cannot move the config — but once `app.ini` is read,
  `WORK_PATH` there replaces the work path taken from `Environment=` or
  `--work-path` for everything else. `cmd/web.go` only `log.Error`s about
  the mismatch and keeps running, so the script follows `app.ini` too.
  Checked against the current `forgejo` branch source.
- **`LOCAL_ROOT_URL` is what Forgejo itself uses for local requests**, and
  its default depends on `PROTOCOL` — `http://unix/` for `http+unix`.
  Prefer it over reconstructing a URL from `HTTP_ADDR` and `HTTP_PORT` when
  it is set.
- **The runner's registration file is named by `runner.file` in its own
  config**, resolved relative to the daemon's working directory, not to the
  config file's own directory.
- **No read-only Forgejo command loads `app.ini` without a side effect.**
  Running `dump` with `--help`, or `doctor check` with `--list`, exits 0
  with a nonexistent `--config` — the CLI prints help before the config is
  looked at, so neither proves anything about the config. `doctor check
  --run paths` does load `app.ini` and needs no database, but when
  `[security] INTERNAL_TOKEN` or `[oauth2] JWT_SECRET` are missing it
  writes them into `app.ini`, reflows the file, and sets its mode to
  `0600`; it also creates `data/tmp/package-upload` under the work path.
  Checked against forgejo 16.0.5. The pre-stop checks therefore prove only
  that the binary runs as `FORGEJO_USER` and that the account can read the
  config and write `BACKUP_DIR`.

## Shell style

- `#!/usr/bin/env bash` and `set -euo pipefail`. Must pass `shellcheck` with
  no findings. Silence a genuine false positive with a scoped
  `# shellcheck disable=SCxxxx` and a reason, never by lowering severity.
- Quote every expansion.
- **Functions that return a value through stdout must log to stderr.** `log`
  and `warn` write to stderr for this reason. A log line written to stdout
  inside `fetch_and_verify` ends up in the caller's `$(...)` and becomes part
  of a file path.
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
  the health check passes. A new code path between stop and health must
  keep those assignments.
- **`eval` appears exactly once**, to turn the `Environment=` line from
  `systemctl show` back into an array. It is there because systemd emits
  that line as shell-quoted words and nothing else undoes that quoting
  without a new dependency. Do not add a second use.
- **Linux and systemd only.** Do not add macOS, BSD, or non-systemd code
  paths. `install`, `sha256sum`, and `mktemp -d` with a template are GNU
  behaviors and that is fine.
- **The usage text is the script's own header comment**, printed with
  `sed -n '2,34p'`. Adding a line to the header means updating that range.

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
  missing file to confirm only the binary check is skipped.

## Review discipline

Patterns that self-review reliably misses.

- **Nothing is pre-verified.** A rewrite of a function that "does the same
  thing" carries zero coverage until the verification path runs again. The
  script was rewritten once from memory after the original was lost, and was
  re-verified against a real release before being trusted.
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
  out. Check every key name against Forgejo's configuration cheat sheet.
- **Report outcomes faithfully.** Say which paths ran and which did not.
- **End with a fresh-context review.** Before opening a PR, have the final
  diff read by a reviewer who has seen only the diff, and ask "do these hunks
  agree with each other?", not "is each hunk correct?".

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
- Bare URLs go in angle brackets.

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
