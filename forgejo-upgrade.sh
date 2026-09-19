#!/usr/bin/env bash
#
# forgejo-upgrade.sh - upgrade binary installs of Forgejo and forgejo-runner
#
# Usage:
#   forgejo-upgrade.sh check                  show installed vs latest for both
#   forgejo-upgrade.sh settings               show the settings read from the unit and app.ini
#   forgejo-upgrade.sh forgejo <ver|latest>   upgrade the Forgejo server
#   forgejo-upgrade.sh runner  <ver|latest>   upgrade forgejo-runner
#   forgejo-upgrade.sh rollback forgejo|runner [--no-start]   restore the previous binary
#
# Overrides (each is read from the systemd unit or app.ini when unset):
#   FORGEJO_SERVICE    forgejo
#   FORGEJO_BIN        /usr/local/bin/forgejo
#   FORGEJO_USER       git
#   FORGEJO_CONFIG     /etc/forgejo/app.ini
#   FORGEJO_WORK_PATH  unset; Forgejo then uses the directory holding the binary
#   FORGEJO_URL        http://127.0.0.1:3000   (used for the health check)
#   FORGEJO_SOCKET     unset; read from HTTP_ADDR when PROTOCOL is http+unix
#   FORGEJO_DB_TYPE    unset; read from [database] DB_TYPE in app.ini
#   BACKUP_DIR         /var/backups/forgejo    (must be writable by FORGEJO_USER)
#   SKIP_BACKUP        set to 1 to skip `forgejo dump`
#   RUNNER_SERVICE     forgejo-runner
#   RUNNER_BIN         /usr/local/bin/forgejo-runner
#   RUNNER_HOME        /home/runner            (holds the .runner registration file)
#   RUNNER_CONFIG      unset; read from the -c flag in the unit's ExecStart
#   TMPDIR             /tmp; holds the download, run from there once, not noexec
#
# Run `forgejo-upgrade.sh settings` to see every resolved value and where it
# came from. Nothing is guessed silently: each value is printed with its source
# before an upgrade touches the service.
#
# Both binaries are signed with the Forgejo release key. The fingerprint below
# is from https://forgejo.org/download/ - it is verified on every run.
# Note: "latest" returns the newest tag across all lines; on the v15 LTS line
# pass an explicit version.

set -euo pipefail

# Settings the operator can override. Empty here means "the operator did not
# set it", not "no value": resolve_forgejo_settings and resolve_runner_settings
# fill each one in from the systemd unit and app.ini, falling back to the
# documented default, and print what they found. An environment variable set
# here always wins, so an unusual install can be driven entirely from the
# command line.
FORGEJO_SERVICE=${FORGEJO_SERVICE:-}
FORGEJO_BIN=${FORGEJO_BIN:-}
FORGEJO_USER=${FORGEJO_USER:-}
FORGEJO_CONFIG=${FORGEJO_CONFIG:-}
FORGEJO_WORK_PATH=${FORGEJO_WORK_PATH:-}
FORGEJO_URL=${FORGEJO_URL:-}
# Only used when Forgejo listens on a unix socket. Read from app.ini, where
# HTTP_ADDR holds the socket path when PROTOCOL is http+unix, unless the
# operator sets it here.
FORGEJO_SOCKET=${FORGEJO_SOCKET:-}
# Which database Forgejo keeps its data in: sqlite3, postgres, mysql, mssql.
# Read from [database] DB_TYPE in app.ini unless the operator sets it here. It
# decides what a `forgejo dump` zip is actually worth as a backup, which the
# messages before the stop and around a rollback have to say plainly.
FORGEJO_DB_TYPE=${FORGEJO_DB_TYPE:-}
# The unit's Environment= settings, passed to the binary when the script runs
# it as FORGEJO_USER. Filled in by resolve_forgejo_settings.
FORGEJO_ENV=()

# The operator's own overrides, captured before any default below is applied
# and shell-quoted, so that the recovery command on_exit prints runs rollback
# against the same install this run resolved. Without them, an upgrade driven
# by FORGEJO_SERVICE=... or FORGEJO_BIN=... would print a rollback command that
# reads the stock unit instead and could touch a different install. Each is
# "NAME=value " pairs ready to go in front of a command, or empty.
FORGEJO_OVERRIDES=""
RUNNER_OVERRIDES=""
for _name in FORGEJO_SERVICE FORGEJO_BIN FORGEJO_USER FORGEJO_CONFIG \
             FORGEJO_WORK_PATH FORGEJO_URL FORGEJO_SOCKET FORGEJO_DB_TYPE \
             BACKUP_DIR; do
  if [[ -n ${!_name:-} ]]; then
    FORGEJO_OVERRIDES+="$_name=$(printf '%q' "${!_name}") "
  fi
done
for _name in RUNNER_SERVICE RUNNER_BIN RUNNER_HOME RUNNER_CONFIG; do
  if [[ -n ${!_name:-} ]]; then
    RUNNER_OVERRIDES+="$_name=$(printf '%q' "${!_name}") "
  fi
done
unset _name
# Recorded before the default is applied, since the assignments below would
# otherwise erase whether the operator actually set these, and the settings
# block needs to say "env" or "default" for them like it does for everything
# else.
BACKUP_DIR_SRC=${BACKUP_DIR:+env}; BACKUP_DIR_SRC=${BACKUP_DIR_SRC:-default}
BACKUP_DIR=${BACKUP_DIR:-/var/backups/forgejo}
SKIP_BACKUP_SRC=${SKIP_BACKUP:+env}; SKIP_BACKUP_SRC=${SKIP_BACKUP_SRC:-default}
SKIP_BACKUP=${SKIP_BACKUP:-0}

RUNNER_SERVICE=${RUNNER_SERVICE:-}
RUNNER_BIN=${RUNNER_BIN:-}
RUNNER_HOME=${RUNNER_HOME:-}
RUNNER_CONFIG=${RUNNER_CONFIG:-}
# Where the runner keeps its registration; filled in by
# resolve_runner_settings from the runner config file.
RUNNER_REG_FILE=""

# Where each resolved value came from, for the settings block the resolvers
# print. Kept as plain variables so the block can name a source per setting.
FORGEJO_SERVICE_SRC=""
FORGEJO_BIN_SRC=""; FORGEJO_USER_SRC=""; FORGEJO_CONFIG_SRC=""
FORGEJO_WORK_PATH_SRC=""; FORGEJO_URL_SRC=""; FORGEJO_SOCKET_SRC=""
FORGEJO_DB_TYPE_SRC=""
RUNNER_SERVICE_SRC=""
RUNNER_BIN_SRC=""; RUNNER_HOME_SRC=""; RUNNER_CONFIG_SRC=""
RUNNER_REG_FILE_SRC=""

# Whether each component is installed on this host at all, as the resolvers
# work out: 1 = it is here, 0 = nothing found. Neither is assumed, because a
# runner often runs on a machine of its own and a Forgejo host often has no
# runner. The read-only commands say "not installed" instead of describing an
# install that is not there.
FORGEJO_PRESENT=1
RUNNER_PRESENT=1

RELEASE_KEY=EB114F5E6C0DC2BCDD183550A4B61A2DC5923710
KEYSERVER=hkps://keys.openpgp.org
FORGEJO_REPO=https://code.forgejo.org/forgejo/forgejo
RUNNER_REPO=https://code.forgejo.org/forgejo/runner

# Where the download and its signature are put. The downloaded binary is run
# from here once, to check which version it really is before it is installed,
# so this has to be on a filesystem that allows execution - a /tmp mounted
# noexec does not. TMPDIR is the way to move it, and sudo passes TMPDIR through
# only when it is given on sudo's own command line.
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/forgejo-upgrade.XXXXXX")

# Only one upgrade at a time on this host, held by acquire_lock and released
# by on_exit. /run is a root-only tmpfs that is cleared at boot, so a lock left
# behind by a machine that crashed mid-upgrade does not survive the reboot, and
# mkdir either creates the directory or fails in one step, so the lock needs no
# new dependency.
LOCK_DIR=/run/forgejo-upgrade.lock
LOCK_HELD=0

# log/warn go to stderr so command substitution captures only returned values
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- exit handling -----------------------------------------------------------

# STOPPED_SVC is set just before a service is asked to stop and cleared again
# once it is healthy. If the script exits anywhere in between - including an
# error that "set -e" turns into an exit, a Ctrl-C, or a stop that failed or
# was interrupted after systemd had already begun stopping the unit - on_exit
# runs and tells the operator that the service is probably down, what the
# journal says, and how to get it running.
STOPPED_SVC=""   # systemd unit this script is stopping or has stopped, "" when none
STOPPED_KIND=""  # "forgejo" or "runner", i.e. the argument to `rollback`
STOPPED_BIN=""   # path of the binary for that service
# 0 = binary untouched, 1 = a new binary was written over it (possibly only
# partly, if the copy itself failed) and .prev holds the old one, 2 = rolled back
BINARY_REPLACED=0

# The rollback command for the service on_exit is reporting, with the
# overrides this run was given in front of it and the script path quoted, so
# it can be pasted as it is.
rollback_command() {
  local overrides=$RUNNER_OVERRIDES prefix=""
  if [[ $STOPPED_KIND == forgejo ]]; then overrides=$FORGEJO_OVERRIDES; fi
  # SUDO_USER means this run was started through sudo, the documented way, so
  # the shell the operator pastes this command into is not root and rollback
  # would refuse it. The overrides go after the sudo, not before it: sudo
  # passes NAME=value words given on its own command line through to the
  # command, but strips them out of the environment it inherits.
  if [[ -n ${SUDO_USER:-} ]]; then prefix="sudo "; fi
  printf '%s%s%q rollback %s\n' "$prefix" "$overrides" "$0" "$STOPPED_KIND"
}

on_exit() {
  local rc=$?
  if [[ -n $STOPPED_SVC ]]; then
    warn "did not finish; $STOPPED_SVC is probably still stopped. Last 40 journal lines:"
    journalctl -u "$STOPPED_SVC" -n 40 --no-pager >&2 \
      || warn "could not read the journal; try it by hand: journalctl -u $STOPPED_SVC -n 40"
    case $BINARY_REPLACED in
      1) warn "a new binary was written to $STOPPED_BIN (the copy may not have completed) and the previous one is kept at $STOPPED_BIN.prev"
         warn "put the previous binary back with: $(rollback_command)"
         # The one case where rollback is not the first move: the health check
         # gave up on a new binary that is still starting, most often a
         # database migration on a big instance. The journal shows that, and
         # then the right thing is to let it finish, not to stop it.
         warn "if the journal above shows the new binary is still starting up (a database migration can take longer than the health check waits), let it finish and check with: systemctl status $STOPPED_SVC" ;;
      # 2 means a rollback is moving, or has moved, the previous binary back
      # over the new one, so no .prev file is left and rolling back again is
      # not possible.
      2) if [[ -e $STOPPED_BIN.prev ]]; then
           # rollback marks this state just before its rename, so .prev still
           # being there means the rename never ran: nothing was moved.
           warn "the previous binary is still at $STOPPED_BIN.prev and was not moved back. Run the rollback again: $(rollback_command)"
         else
           warn "the previous binary is back in place at $STOPPED_BIN and no $STOPPED_BIN.prev remains"
           warn "read the journal above, then start the service with: systemctl start $STOPPED_SVC"
           # on_exit cannot tell for certain that this is the server rather than
           # the runner, so the remedy is offered against what the journal says.
           # FORGEJO_DB_TYPE is whatever the resolver found earlier in this
           # run; when it found nothing, restore_hint uses the cautious
           # wording, which covers an unknown database as well as an external
           # one.
           warn "if the journal says the database is for a newer Forgejo, the data has to go back before that start (see https://forgejo.org/docs/latest/admin/upgrade/#backup): $(restore_hint)"
         fi ;;
      *) warn "the binary was not changed. Start the service again with: systemctl start $STOPPED_SVC" ;;
    esac
  fi
  rm -rf "$WORKDIR" || warn "could not remove the temporary directory $WORKDIR; delete it by hand"
  # Released last, and only by the run that took it, so a second run that
  # stopped at the lock never clears the lock of the run still working. A
  # cleanup failure must not replace the real exit status, so it only warns.
  if [[ $LOCK_HELD -eq 1 ]]; then
    rm -rf "$LOCK_DIR" || warn "could not remove the lock $LOCK_DIR; remove it by hand before the next run"
  fi
  exit "$rc"
}
trap on_exit EXIT
# Ctrl-C and SIGTERM exit instead of killing the shell outright, so the EXIT
# trap above still runs and still reports a service left stopped.
trap 'exit 130' INT
trap 'exit 143' TERM

need_root() { [[ $EUID -eq 0 ]] || die "run as root (sudo)"; }

# Taken by every command that changes a binary: forgejo, runner, and rollback.
# check and settings only read, so they never lock.
acquire_lock() {
  local pid="" state err=""
  # mkdir on a directory that already exists fails, and that failure is the
  # whole signal: another run got here first. But mkdir also fails when it
  # cannot create anything - a missing or read-only /run, no space left, a
  # plain file at this path - and then nobody holds a lock and the "wait or
  # rm -r" advice below would be wrong. Its message is kept for that case and
  # a directory at the path is what says "held".
  if ! err=$(mkdir "$LOCK_DIR" 2>&1); then
    [[ -d $LOCK_DIR ]] \
      || die "could not create the lock directory $LOCK_DIR, so no run holds it and this one cannot take it. mkdir said: '$err'. Its parent has to be a writable directory with free space, and nothing but a directory may sit at $LOCK_DIR; fix that, then rerun"
    if [[ -r $LOCK_DIR/pid ]]; then
      # A file with no final newline makes read return non-zero although it
      # has filled pid in, and an empty file leaves pid empty; both cases are
      # covered by the wording below, so the exit status is not what is read
      # here.
      if ! read -r pid < "$LOCK_DIR/pid"; then :; fi
    fi
    if [[ -n $pid ]]; then
      # Only the exit status is used: can that process still be signalled,
      # that is, is it still alive. Nothing is actually sent to it.
      if kill -0 "$pid" 2>/dev/null; then
        state="pid $pid, still running"
      else
        state="pid $pid, no longer running"
      fi
    else
      state="no pid recorded"
    fi
    die "another forgejo-upgrade run holds the lock $LOCK_DIR ($state). Two runs at once could overwrite the .prev copy that a rollback needs. Wait for it to finish; if that process is gone, remove the stale lock with: rm -r $LOCK_DIR, then rerun"
  fi
  # Owned from the moment the directory exists, before the pid is written: if
  # that write fails (a full /run, say), set -e exits, and on_exit must still
  # remove the directory or every later run would stop at a lock nobody holds.
  LOCK_HELD=1
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

arch() {
  case "$(uname -m)" in
    x86_64)  echo amd64 ;;
    aarch64) echo arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

# --- version helpers ---------------------------------------------------------

latest_tag() {  # $1 = repo URL -> prints e.g. 16.0.5
  local api=${1/code.forgejo.org\//code.forgejo.org/api/v1/repos/}
  curl -q -fsSL "$api/releases/latest" \
    | sed -n 's/.*"tag_name":"v\{0,1\}\([^"]*\)".*/\1/p' | head -n1
}

# The two parsers below are the only place that knows what each binary prints.
# Both the "what is installed" reading and the check on a freshly downloaded
# binary go through them, so the two cannot drift apart.

parse_forgejo_version() {  # $1 = output of "forgejo --version" -> the version, empty when there is none
  # The server binary prints "forgejo version 16.0.5+gitea-1.22.0 (release
  # name 16.0.5) ..." in lower case, though the docs show it capitalized, so
  # either case is accepted.
  sed -n 's/^[Ff]orgejo version \([0-9][0-9.]*\).*/\1/p' <<<"$1" | head -n1
}

parse_runner_version() {  # $1 = output of "forgejo-runner --version" -> the version, empty when there is none
  # The runner prints "forgejo-runner version v13.1.0", with a "v" in front of
  # the number that the version this script works with does not have.
  sed -n 's/.*version v\{0,1\}\([0-9][0-9.]*\).*/\1/p' <<<"$1" | head -n1
}

installed_forgejo() {
  [[ -x $FORGEJO_BIN ]] || { echo none; return; }
  local out ver
  out=$("$FORGEJO_BIN" --version 2>&1) \
    || die "$FORGEJO_BIN --version failed (exit $?): '${out%%$'\n'*}'. The binary may be corrupt or built for another architecture; reinstall it, or set FORGEJO_BIN to the binary you want upgraded"
  ver=$(parse_forgejo_version "$out")
  [[ -n $ver ]] || die "could not read a version from '$FORGEJO_BIN --version'. Expected a line like 'forgejo version 16.0.4', got: '${out%%$'\n'*}'"
  echo "$ver"
}

installed_runner() {
  [[ -x $RUNNER_BIN ]] || { echo none; return; }
  local out ver
  out=$("$RUNNER_BIN" --version 2>&1) \
    || die "$RUNNER_BIN --version failed (exit $?): '${out%%$'\n'*}'. The binary may be corrupt or built for another architecture; reinstall it, or set RUNNER_BIN to the binary you want upgraded"
  ver=$(parse_runner_version "$out")
  [[ -n $ver ]] || die "could not read a version from '$RUNNER_BIN --version'. Expected a line like 'forgejo-runner version v13.1.0', got: '${out%%$'\n'*}'"
  echo "$ver"
}

resolve_version() {  # $1 = requested, $2 = repo
  if [[ $1 == latest ]]; then latest_tag "$2"; else echo "${1#v}"; fi
}

# --- download + verify -------------------------------------------------------

ensure_key() {
  if ! gpg --list-keys "$RELEASE_KEY" >/dev/null 2>&1; then
    log "Importing Forgejo release key $RELEASE_KEY"
    gpg --keyserver "$KEYSERVER" --recv "$RELEASE_KEY"
  fi
}

# The status lines gpg printed during the last gpg_valid_sig call. Kept in a
# variable rather than returned on stdout so the two questions asked of them -
# "is this signed by the pinned key" and "was the key simply missing" - can both
# be answered without a second run of gpg.
GPG_STATUS=""

gpg_valid_sig() {  # $1 = signature file, $2 = signed file -> 0 when RELEASE_KEY signed it
  # Releases are signed by a rotating subkey. gpg's VALIDSIG status line lists
  # the signing subkey first and the primary key last, so the fingerprint is
  # matched at the end of the line; matching it straight after VALIDSIG fails
  # on every release.
  #
  # Two deliberate suppressions here. gpg's human-readable output on stderr is
  # dropped because the machine-readable status lines are what is judged. And
  # "|| true" is there because gpg --verify exits non-zero for a signature it
  # cannot check at all - an unknown key gives NO_PUBKEY and a failure exit -
  # and that case is not an error yet: the caller reads the status lines and
  # refreshes the pinned key. Nothing here decides a signature is good; only
  # the two checks below do that, and both have to pass.
  GPG_STATUS=$(gpg --status-fd 1 --verify "$1" "$2" 2>/dev/null || true)
  grep -Eq "^\[GNUPG:\] VALIDSIG .* $RELEASE_KEY$" <<<"$GPG_STATUS" || return 1
  # VALIDSIG on its own says only that the signature is cryptographically
  # valid. gpg prints it alongside EXPSIG (the signature itself has expired),
  # EXPKEYSIG (the key that made it has since expired) and REVKEYSIG (that key
  # was revoked) - see gnupg's doc/DETAILS - so a release could carry a
  # VALIDSIG line for the pinned key and still be one of those three. None of
  # them is good enough to install, so all three are refused here.
  #
  # KEYEXPIRED is deliberately not in that list. gpg prints a KEYEXPIRED line
  # for every expired subkey it sees on the pinned primary key, and the
  # current releases all have some - none of which signed this file. Treating
  # KEYEXPIRED as a failure would reject every current release.
  ! grep -Eq '^\[GNUPG:\] (EXPSIG|EXPKEYSIG|REVKEYSIG) ' <<<"$GPG_STATUS"
}

gpg_verdict() {  # -> one word saying what gpg made of the last gpg_valid_sig
  # Reads GPG_STATUS and prints one of: missing-key, bad-signature, expired,
  # revoked, other-key, unverifiable.
  #
  # The order matters. gpg prints VALIDSIG together with EXPSIG, EXPKEYSIG and
  # REVKEYSIG, so a status holding both has to be reported as expired or
  # revoked - that is the reason the signature was refused - and not as a
  # signature by some other key. NO_PUBKEY is "the key is not in the keyring";
  # ERRSIG is gpg's more general "could not check this signature", which is
  # what it prints for an unknown key when it cannot say more. Those two are
  # the only verdict the caller retries.
  if grep -Eq '^\[GNUPG:\] (NO_PUBKEY|ERRSIG) ' <<<"$GPG_STATUS"; then
    printf 'missing-key\n'
  elif grep -Eq '^\[GNUPG:\] BADSIG ' <<<"$GPG_STATUS"; then
    printf 'bad-signature\n'
  elif grep -Eq '^\[GNUPG:\] (EXPSIG|EXPKEYSIG) ' <<<"$GPG_STATUS"; then
    printf 'expired\n'
  elif grep -Eq '^\[GNUPG:\] REVKEYSIG ' <<<"$GPG_STATUS"; then
    printf 'revoked\n'
  elif grep -Eq '^\[GNUPG:\] VALIDSIG ' <<<"$GPG_STATUS" \
       && ! grep -Eq "^\[GNUPG:\] VALIDSIG .* $RELEASE_KEY$" <<<"$GPG_STATUS"; then
    printf 'other-key\n'
  else
    # Nothing recognizable, or a status this function is not asked about - a
    # good signature by the pinned key lands here too, because the caller only
    # ever asks after gpg_valid_sig has already said no.
    printf 'unverifiable\n'
  fi
}

gpg_status_line() {  # $1 = extended regex -> the first matching status line, empty when none
  # Quoted back to the operator so the message names what gpg actually said.
  # A status with no matching line is possible - an empty status, above all -
  # and then nothing is printed rather than the whole thing failing.
  grep -m1 -E "$1" <<<"$GPG_STATUS" || true
}

die_bad_signature() {  # $1 = asset filename, $2 = the verdict, $3 = when this happened ("" for the first try)
  # One message shape for every way a signature can be refused: what was
  # expected, what gpg reported, and what to do. Changing RELEASE_KEY is never
  # the remedy - it is the fingerprint this script trusts, and a release that
  # does not match it is the thing to question.
  local f=$1 verdict=$2 when=$3 what line
  case "$verdict" in
    bad-signature)
      what="the signature does not match the file, so the download is damaged or has been tampered with"
      line=$(gpg_status_line '^\[GNUPG:\] BADSIG ') ;;
    expired)
      what="the signature or the key that made it has expired"
      line=$(gpg_status_line '^\[GNUPG:\] (EXPSIG|EXPKEYSIG) ') ;;
    revoked)
      what="the key that made the signature has been revoked"
      line=$(gpg_status_line '^\[GNUPG:\] REVKEYSIG ') ;;
    other-key)
      what="the file is signed by some other key"
      line=$(gpg_status_line '^\[GNUPG:\] VALIDSIG ') ;;
    *)
      what="gpg could not check the signature at all"
      line=$(gpg_status_line '^\[GNUPG:\] ') ;;
  esac
  die "signature on $f was refused$when: $what. Expected gpg to report a VALIDSIG line ending in $RELEASE_KEY - the Forgejo release key published at https://forgejo.org/download/ - with no expiry or revocation; gpg reported '$verdict'${line:+, status line: $line}. Do not install this file: check the release and the key fingerprint at https://forgejo.org/download/, and report a mismatch to Forgejo"
}

fetch_sha256() {  # $1 = url, $2 = file to write -> 0 fetched, 1 not published; dies otherwise
  # Deliberately no -f: without it curl reports the status code instead of one
  # generic failure, and only a 404 means "this release has no .sha256". A DNS
  # failure, a TLS error, a timeout, or a 500 must stop the upgrade rather than
  # pass for "not published" and quietly leave the checksum unverified.
  local code body
  code=$(curl -q -sSL -o "$2" -w '%{http_code}' "$1") \
    || die "could not download $1 (curl exit $?). Expected either the release's .sha256 file or a 404 saying there is none; check this host's network access to code.forgejo.org and rerun"
  case "$code" in
    200) return 0 ;;
    # With no -f, curl writes the server's error page into the file, so a 404
    # leaves something behind that is not a checksum. Take it away.
    404) rm -f "$2"; return 1 ;;
    # The file itself is no help to the operator: on_exit deletes the whole
    # working directory on the way out. Quote the start of what the server
    # said instead, capped so an HTML error page cannot flood the terminal.
    *)   body="(nothing)"
         if [[ -s $2 ]]; then body=$(head -c 200 "$2" | head -n1); fi
         die "unexpected HTTP $code fetching $1. Expected 200 with the checksum file, or 404 meaning the release has none; the server answered: '$body'. Rerun, and if it keeps happening check whether code.forgejo.org is having trouble" ;;
  esac
}

require_exec_workdir() {
  # The downloaded binary is run once, from $WORKDIR, to check which version it
  # really is. A /tmp mounted noexec makes that run fail with "Permission
  # denied" and exit 126, which reads as a broken download or the wrong
  # architecture. Find out here, before anything is downloaded, with a two-line
  # shell script of our own.
  local probe="$WORKDIR/.exec-probe" rc=0
  printf '#!/bin/sh\nexit 0\n' > "$probe" \
    || die "could not write to the temporary directory $WORKDIR. Expected a writable directory for the download; set TMPDIR to a directory this host can write to and rerun. Nothing was installed"
  chmod 755 "$probe" \
    || die "could not make $probe executable. Set TMPDIR to a directory on a filesystem that allows execution and rerun. Nothing was installed"
  "$probe" || rc=$?
  # Left in place: on_exit removes the whole working directory anyway, and
  # deleting it here would be one more command to check for no gain.
  [[ $rc -eq 0 ]] \
    || die "cannot run a program from $WORKDIR (exit $rc). The filesystem holding it is most likely mounted noexec, and the downloaded binary has to run from there once so this script can check its version before installing it. Set TMPDIR to a directory on a filesystem that allows execution - /var/tmp or /root, say - and rerun with it on the sudo command line, as in: sudo TMPDIR=/var/tmp $0 forgejo latest. Nothing was installed"
}

fetch_and_verify() {  # $1 = repo, $2 = asset filename, $3 = version  -> path
  local base="$1/releases/download/v$3" f="$2" verdict
  require_exec_workdir
  log "Downloading $f"
  # Each command here is checked by hand rather than left to "set -e". Both
  # callers run this function as new=$(fetch_and_verify ...), and bash turns
  # errexit off inside a command substitution, so a failure that is not checked
  # right here is simply skipped: a curl that could not download anything would
  # carry on to the signature check and the operator would be told the
  # signature could not be verified instead of that the download failed.
  curl -q -fL --progress-bar -o "$WORKDIR/$f"     "$base/$f" \
    || die "could not download $base/$f (curl exit $?). Expected the release asset for v$3; check that $1/releases lists v$3 with a $f asset and that this host can reach code.forgejo.org, then rerun. Nothing was installed"
  curl -q -fsSL            -o "$WORKDIR/$f.asc" "$base/$f.asc" \
    || die "could not download the signature $base/$f.asc (curl exit $?). Without it the downloaded file cannot be verified, and this script never installs a file it has not verified; check that $1/releases lists v$3 with a $f.asc asset and that this host can reach code.forgejo.org, then rerun. Nothing was installed"

  log "Verifying GPG signature"
  if ! gpg_valid_sig "$WORKDIR/$f.asc" "$WORKDIR/$f"; then
    # A signature this keyring cannot check at all is the one case worth
    # retrying: Forgejo signs each release with a subkey of the pinned primary
    # key, and a subkey issued since the key was imported is not in the keyring
    # yet. Every other verdict - a bad signature, an expired or revoked key, a
    # signature by another key - stops the upgrade here, saying which one it
    # was.
    verdict=$(gpg_verdict)
    case "$verdict" in
      missing-key)
        log "signature is by a key not in the keyring; refreshing the pinned key $RELEASE_KEY from $KEYSERVER (the same fingerprint, nothing else)"
        # Only the pinned fingerprint is ever fetched, so the trust root does
        # not move: this can add a new subkey of the key already trusted, and
        # nothing else.
        gpg --keyserver "$KEYSERVER" --recv "$RELEASE_KEY" \
          || die "could not refresh the key $RELEASE_KEY from $KEYSERVER; the signature on $f cannot be checked, so the download is not trusted and nothing was installed. Check this host's network access to the keyserver, or import the key by hand from https://forgejo.org/download/, then rerun"
        # The refresh gave the keyring every chance; whatever gpg says now is
        # final, and the verdict is read again because it may have changed.
        gpg_valid_sig "$WORKDIR/$f.asc" "$WORKDIR/$f" \
          || die_bad_signature "$f" "$(gpg_verdict)" " even after the pinned key was refreshed from $KEYSERVER" ;;
      *) die_bad_signature "$f" "$verdict" "" ;;
    esac
  fi

  # Older releases do not publish a .sha256 at all, which fetch_sha256 reports
  # as a 404 and nothing else.
  if fetch_sha256 "$base/$f.sha256" "$WORKDIR/$f.sha256"; then
    log "Verifying sha256"
    # The .sha256 file names the asset, so the check has to run in the
    # directory holding it.
    (cd "$WORKDIR" && sha256sum -c --quiet "$f.sha256") || die "sha256 mismatch for $f"
  else
    warn "no .sha256 published for $f (HTTP 404); relying on the GPG signature only"
  fi

  chmod 755 "$WORKDIR/$f" \
    || die "could not make the downloaded $WORKDIR/$f executable, so its version cannot be checked and nothing was installed. Rerun, and if it keeps happening set TMPDIR to another directory"
  echo "$WORKDIR/$f"
}

require_prev_slot() {  # $1 = binary path; dies when $1.prev is not a plain file
  # install_binary writes the binary it is replacing to exactly "$1.prev", and
  # rollback reads it back from there. Anything else already sitting at that
  # path changes what those two do: cp copies into a directory that is there,
  # and mv would move the old binary into it. The -T and --remove-destination
  # flags in install_binary make both refuse or replace instead, and this check
  # says so before the service is stopped rather than after.
  if [[ -L $1.prev || ( -e $1.prev && ! -f $1.prev ) ]]; then
    # stat does not follow a symlink unless asked, so a link reports
    # "symbolic link" here rather than the type of whatever it points at.
    die "$1.prev is a $(stat -c %F "$1.prev"), not a plain file. This script keeps the binary it replaces at exactly that path and rollback reads it back from there, so that name cannot be anything else. Move whatever is at $1.prev out of the way and rerun. Nothing has been stopped"
  fi
}

install_binary() {  # $1 = new file, $2 = destination
  # Both callers refuse to run when nothing is installed, so the destination
  # always exists and there is always a previous binary worth keeping.
  log "Keeping previous binary at $2.prev"
  # Not "cp -p": that keeps the mode, the owner, the timestamps and the POSIX
  # ACL, but it drops every other extended attribute - including
  # security.capability, which is where a file capability granted with setcap
  # lives. A Forgejo allowed to bind port 443 with cap_net_bind_service would
  # lose that permission in the copy, so the binary kept for a rollback would
  # no longer be the binary that was working. "all" adds the rest of the
  # extended attributes and, on a kernel that has SELinux, the security
  # context, and skips the context quietly on a kernel that does not. Naming
  # "xattr" a second time makes a failed attribute copy an error instead of a
  # warning. An explicit "context" is never used: on a kernel without SELinux
  # cp refuses outright with "cannot preserve security context without an
  # SELinux-enabled kernel", which would break every non-SELinux host.
  #
  # "-T" makes "$2.prev" the destination itself rather than a directory to copy
  # into: a directory left at that name would otherwise swallow the backup as
  # "$2.prev/<name>", and the rollback would find nothing to put back.
  # "--remove-destination" unlinks whatever is at that name first, so a symlink
  # there is replaced by the backup instead of being written through, which
  # would overwrite the unrelated file it points at. require_prev_slot already
  # refused both before the service was stopped; these two flags mean a name
  # that changed since then fails here rather than doing the wrong thing.
  cp -T --remove-destination --preserve=all,xattr "$2" "$2.prev"
  # Set before install runs, not after it returns: install unlinks the
  # destination and writes a new file, so a failure part way (a full disk, say)
  # leaves a truncated binary behind. From here on the remedy is .prev, and
  # on_exit must say so even if the very next command fails.
  BINARY_REPLACED=1
  # Keep the owner, group, and mode the installed binary already had instead of
  # forcing root:root 755. A hardened install may, for example, let only one
  # group run the binary, and re-creating it as world-executable root:root
  # would quietly undo that during an upgrade. The ids are numeric on purpose:
  # stat prints UNKNOWN for a uid or gid with no passwd or group entry, and
  # "install -o UNKNOWN" would then fail with the service already stopped.
  # "-T" is GNU install's --no-target-directory, for the same reason as on the
  # copy above: the destination is this exact path, never a directory to put
  # the file inside.
  install -T -m "$(stat -c %a "$2")" -o "$(stat -c %u "$2")" -g "$(stat -c %g "$2")" "$1" "$2"
  # install unlinks the destination and writes a new file, so the file now in
  # place has no ACL, no extended attributes and the default security context:
  # the file capability, the ACL and the SELinux label the old binary carried
  # are all gone. This copies them back from .prev, which is that old binary
  # untouched. --attributes-only leaves the new binary's contents alone, and
  # --no-preserve=timestamps leaves the date install just gave it, so the file
  # says when it was installed rather than carrying the old binary's date. A
  # source with no extended attributes at all is not an error; cp exits 0.
  #
  # A failure here stops the upgrade on purpose. There is no getcap or
  # getfattr to check the result with on a minimal host and this script adds
  # no dependency, so cp's exit status is the whole check. The alternative to
  # stopping is a binary that silently lost the capability it needs to bind
  # its port and will not come back up. BINARY_REPLACED is already 1 at this
  # point, so on_exit prints the journal and the rollback command.
  # "-T" again: both names here are exact paths, not directories.
  cp -T --attributes-only --preserve=all,xattr --no-preserve=timestamps "$2.prev" "$2"
}

# --- settings ----------------------------------------------------------------
#
# Everything below answers one question: how is this host actually set up?
# The answer comes from the systemd unit and app.ini rather than from defaults
# copied out of the documentation, because an install that moved its config,
# its work path, or its user is exactly the install a wrong guess would break.

unit_name() {  # $1 = service name -> the same name with .service spelled out
  case "$1" in
    *.*) printf '%s\n' "$1" ;;
    *)   printf '%s.service\n' "$1" ;;
  esac
}

unit_loaded() {  # $1 = unit -> true when systemd knows this unit
  # systemctl show exits 0 for a unit that does not exist, so LoadState, not
  # the exit status, is what says whether the unit is real.
  [[ $(systemctl show "$1" -p LoadState --value) == loaded ]]
}

unit_prop() {  # $1 = unit, $2 = property -> the value alone, empty when unset
  systemctl show "$1" -p "$2" --value
}

# systemctl prints ExecStart as one record per command:
#   { path=/usr/local/bin/forgejo ; argv[]=/usr/local/bin/forgejo web -c /x ;
#     ignore_errors=no ; start_time=[n/a] ; ... }
# The two helpers below pull the program and its arguments back out of that.

unit_exec_path() {  # $1 = unit -> the program systemd runs, empty when none
  local record
  record=$(unit_prop "$1" ExecStart)
  [[ $record == '{ path='* ]] || return 0
  record=${record#'{ path='}
  printf '%s\n' "${record%% ;*}"
}

unit_exec_argv() {  # $1 = unit -> the command line systemd runs, empty when none
  local record
  record=$(unit_prop "$1" ExecStart)
  [[ $record == *'argv[]='* ]] || return 0
  record=${record#*'argv[]='}
  printf '%s\n' "${record%% ; ignore_errors=*}"
}

argv_opt() {  # $1 = --long, $2 = -s (may be ""), then -- then the argv words
  # Prints the value of the first "--long V", "--long=V", "-s V" or "-s=V" in
  # the argument list, or nothing when the option is not there.
  local long=$1 short=$2 word
  shift 2
  if [[ ${1:-} == -- ]]; then shift; fi
  while [[ $# -gt 0 ]]; do
    word=$1
    shift
    if [[ $word == "$long="* ]]; then printf '%s\n' "${word#*=}"; return 0; fi
    if [[ -n $short && $word == "$short="* ]]; then printf '%s\n' "${word#*=}"; return 0; fi
    if [[ $word == "$long" ]] || [[ -n $short && $word == "$short" ]]; then
      if [[ $# -gt 0 ]]; then printf '%s\n' "$1"; return 0; fi
    fi
  done
  return 0
}

ini_get() {  # $1 = file, $2 = section ("" for the keys before the first one), $3 = key, $4 = expansion round (used by ini_get itself)
  # Reads one value out of an ini file with sed, so the script still needs
  # nothing an operator would have to install. Good enough for the handful of
  # [server] keys the health check needs, not a general ini parser.
  #
  # Only the last match is kept, which is what Forgejo does with a key given
  # twice: go-ini overwrites the earlier value, and Forgejo's load options do
  # not turn shadowed keys on (modules/setting/config_provider.go,
  # configProviderLoadOptions). "tail -n 1" rather than cutting the captured
  # text up, because a last match with an empty value - "WORK_PATH =" - has to
  # survive, and command substitution drops the empty line it prints.
  local file=$1 section=$2 key=$3 round=${4:-0} raw val ref name rep
  [[ -r $file ]] || return 0
  if [[ -n $section ]]; then
    # The range runs from the section header to the next one; sed starts
    # looking for the end pattern on the line after the start, so the header
    # itself does not close the range.
    raw=$(sed -n "/^[[:space:]]*\[[[:space:]]*${section}[[:space:]]*\]/I,/^[[:space:]]*\[/ \
                  s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//Ip" "$file" | tail -n 1)
  else
    raw=$(sed -n "/^[[:space:]]*\[/q; s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//Ip" "$file" | tail -n 1)
  fi
  # An empty last value is "set to nothing", which Forgejo reads as unset
  # (it tests configWorkPath != ""), so nothing is returned for it.
  [[ -n $raw ]] || return 0
  # Drop a trailing " ; comment" or " # comment", then trailing spaces and any
  # surrounding quotes.
  val=$(printf '%s\n' "$raw" \
    | sed -e 's/[[:space:]][;#].*$//' -e 's/[[:space:]]*$//' \
          -e 's/^"\(.*\)"$/\1/' -e "s/^'\\(.*\\)'\$/\\1/")

  # Now expand %(NAME)s references, which is what Forgejo sees. Every value it
  # reads goes through go-ini's Key.transformValue (gopkg.in/ini.v1 v1.67.3,
  # the version Forgejo pins), and Forgejo's own configuration cheat sheet
  # documents LOCAL_ROOT_URL = %(PROTOCOL)s://%(HTTP_ADDR)s:%(HTTP_PORT)s/ as
  # the default, so an operator who writes that form is on a documented path.
  # Without this the health check would be handed the literal text.
  #
  # Nothing to expand is the common case and costs nothing to spot.
  if [[ $val != *'%('* ]]; then
    printf '%s\n' "$val"
    return 0
  fi
  # Each round replaces the first reference, the way go-ini does: look the name
  # up in this same section, and in the keys before the first section when it
  # is not there - or when it names the key being read, which go-ini also sends
  # to the default section so that a key cannot expand into itself. Keys are
  # matched here without regard to case, so that comparison ignores case too.
  # The referenced value is read back through ini_get, so it is expanded in its
  # own section on the way, which is what go-ini's nk.String() does.
  #
  # Only a name made of letters, digits, and underscores is expanded: the name
  # is handed back to this function and ends up in a sed pattern, and no real
  # Forgejo key has any other character in it. A reference whose name holds
  # anything else is left exactly as written.
  #
  # The round counter is passed down and stops the expansion at 99, leaving
  # whatever is left as written. It is there for a pathological file - A =
  # %(B)s with B = %(A)s - which would otherwise never settle. go-ini has no
  # such guard and would recurse on that file until it ran out of stack, so
  # Forgejo would not start on it at all; the point here is only that this
  # script must not hang.
  while [[ $round -lt 99 && $val =~ %\(([A-Za-z0-9_]+)\)s ]]; do
    ref=${BASH_REMATCH[0]}
    name=${BASH_REMATCH[1]}
    rep=""
    if [[ -z $section || ${name^^} != "${key^^}" ]]; then
      rep=$(ini_get "$file" "$section" "$name" "$((round + 1))")
    fi
    # This function returns nothing both for a key that is not there and for a
    # key set to nothing, so an empty answer is read as "not in this section"
    # and the keys before the first section are asked next, and an empty answer
    # from there as "nowhere at all", which leaves the reference as written and
    # stops. go-ini tells those two apart and would put an empty string in
    # place of a key that exists but is empty; that is a deliberate
    # approximation here, and it cannot arise for the handful of keys this
    # script reads.
    if [[ -z $rep && -n $section ]]; then
      rep=$(ini_get "$file" "" "$name" "$((round + 1))")
    fi
    [[ -n $rep ]] || break
    # The replacement is quoted on purpose: bash's patsub_replacement option,
    # on by default since 5.2, turns an unquoted "&" in the replacement into
    # the matched text, so a value holding "&" would put the reference back
    # instead of the value and the loop would chase it until the round cap.
    val=${val//"$ref"/"$rep"}
    round=$((round + 1))
    # A replacement that still carries a reference of its own is one the
    # lookup above could not finish - an unknown name, or two keys that name
    # each other - so it is put in place and the expansion stops there rather
    # than trying that same reference again from this section. Without this, a
    # pair of keys referring to each other would fan out into a fresh lookup at
    # every round left, which is work measured in powers of two rather than the
    # ninety-nine steps the counter suggests. A value whose own expansion
    # finished never comes back with a "%(" in it.
    if [[ $rep == *'%('* ]]; then break; fi
  done
  printf '%s\n' "$val"
}

yaml_get() {  # $1 = file, $2 = top-level key, $3 = key indented under it
  # This exists for one line of the runner config, "file:" under "runner:".
  # It is not a YAML parser and must not be used as one.
  local file=$1 section=$2 key=$3 raw
  [[ -r $file ]] || return 0
  raw=$(sed -n "/^$section:/,/^[^[:space:]#]/ \
                s/^[[:space:]]\{1,\}$key:[[:space:]]*//p" "$file")
  raw=${raw%%$'\n'*}
  [[ -n $raw ]] || return 0
  printf '%s\n' "$raw" \
    | sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' \
          -e 's/^"\(.*\)"$/\1/' -e "s/^'\\(.*\\)'\$/\\1/"
}

forgejo_env_value() {  # $1 = variable name -> its value from the unit's Environment=
  local name=$1 item
  for item in ${FORGEJO_ENV[@]+"${FORGEJO_ENV[@]}"}; do
    if [[ $item == "$name="* ]]; then printf '%s\n' "${item#*=}"; return 0; fi
  done
  return 0
}

trim_slash() {  # $1 -> $1 with its trailing slashes off, except that / stays /
  # Every path below is joined as "${dir%/}/rest", so a directory is stored
  # without a trailing slash. The root directory is the exception: "${X%/}"
  # alone would turn / into the empty string, and empty is this script's
  # "nobody set this" sentinel.
  local p=$1
  while [[ $p == */ && $p != / ]]; do p=${p%/}; done
  printf '%s\n' "$p"
}

require_abs() {  # $1 = name, $2 = value, $3 = 1 to warn instead of dying
  # Only for paths the operator set in the environment. Everything read from a
  # unit or a config file is made absolute where it is read, against the
  # directory the daemon itself runs in; an env var has no such directory to be
  # relative to, and the script does not run from one place throughout.
  if [[ -z $2 || $2 == /* ]]; then return 0; fi
  local msg="$1=$2 is a relative path. The checks before the stop run from this directory and the commands after it from the work path, so they would name different files; set $1 to an absolute path"
  if [[ ${3:-0} -eq 0 ]]; then die "$msg"; else warn "$msg"; fi
}

require_abs_work_path() {  # $1 = value, $2 = where it came from, $3 = 1 to warn instead of dying
  # A relative Forgejo work path is refused wherever it came from, because
  # Forgejo refuses it too. InitWorkPathAndCfgProvider
  # (modules/setting/path.go) checks each of its three sources and calls
  # log.Fatal on a relative one - it never resolves it against the unit's
  # WorkingDirectory= or anything else - so a relative value cannot be what
  # the running daemon is using, and the dump and doctor runs this script
  # makes as the Forgejo account would be refused the same way. That is what
  # makes this different from the relative --config handled further down,
  # which Forgejo really does put through filepath.Abs against the directory
  # the daemon runs in.
  if [[ -z $1 || $1 == /* ]]; then return 0; fi
  local said fix
  case "$2" in
    *--work-path*)
      said="--work-path must be absolute path"
      fix="the unit's ExecStart" ;;
    *FORGEJO_WORK_DIR*)
      said="FORGEJO_WORK_DIR (work path) must be absolute path"
      fix="the unit's Environment=" ;;
    *GITEA_WORK_DIR*)
      said="GITEA_WORK_DIR (work path) must be absolute path"
      fix="the unit's Environment=" ;;
    *)
      said="WORK_PATH in \"$FORGEJO_CONFIG\" must be absolute path"
      fix="app.ini" ;;
  esac
  local msg="the Forgejo work path $1 (from: $2) is a relative path. Forgejo itself will not start on one: it exits with '$said'. So this is not the path the running server is using, and the dump and doctor runs this script makes would be refused for the same reason. Make it an absolute path where it is set, in $fix"
  if [[ ${3:-0} -eq 0 ]]; then die "$msg"; else warn "$msg"; fi
}

same_dir() {  # $1, $2 = two paths -> 0 when they are the same directory
  # How Forgejo compares the work path from the unit with WORK_PATH in
  # app.ini: it stats both and asks os.SameFile (modules/setting/path.go),
  # that is "same device and inode", not "same text". A path reached through
  # a symlink or a bind mount is therefore not a mismatch to Forgejo and must
  # not be reported as one here. bash's -ef is that same test.
  #
  # Identical text counts as the same directory even when nothing is there to
  # stat: `settings` is also run on a host where the path does not exist yet,
  # and two identical strings are not a disagreement worth a warning.
  [[ $1 == "$2" ]] || [[ -d $1 && -d $2 && $1 -ef $2 ]]
}

setting_line() {  # $1 = name, $2 = value, $3 = where the value came from
  printf '    %-17s %-31s (%s)\n' "$1" "$2" "$3" >&2
}

die_unknown_unit() {  # $1 = unit, $2 = the variable that names it, $3 = an example unit
  local candidates
  # A best-effort hint. If listing units fails, the real error below still has
  # to print, so the failure is swallowed deliberately.
  candidates=$(systemctl list-units --all --type=service --no-legend --plain \
                 '*forgejo*' '*gitea*' '*runner*') || candidates=""
  [[ -n $candidates ]] || candidates="  (no service with forgejo, gitea, or runner in its name)"
  die "systemd does not know a unit called $1 (its LoadState is not \"loaded\"). Services on this host that look related:
$candidates
Set $2 to the unit name, for example $2=$3 if your unit is $3.service"
}

resolve_forgejo_socket() {  # $1 = 1 to warn instead of dying when the socket is missing, $2 = 1 to stay quiet
  # Only meaningful when PROTOCOL is http+unix. Forgejo then dials the socket
  # named by HTTP_ADDR for its own local requests whatever LOCAL_ROOT_URL
  # says, so the socket is settled here on its own, before and independently
  # of the URL, and applies to whichever URL the health check ends up using.
  local tolerant=$1 quiet=$2 proto addr
  proto=$(ini_get "$FORGEJO_CONFIG" server PROTOCOL)
  [[ $proto == http+unix ]] || return 0
  addr=$(ini_get "$FORGEJO_CONFIG" server HTTP_ADDR)
  if [[ -n $addr ]]; then
    FORGEJO_SOCKET=$addr
    FORGEJO_SOCKET_SRC="app.ini [server] HTTP_ADDR"
    return 0
  fi
  local msg="PROTOCOL is http+unix in $FORGEJO_CONFIG but HTTP_ADDR does not give a socket path, so the health check has nowhere to connect. Set FORGEJO_SOCKET to the socket file"
  if [[ $tolerant -eq 0 ]]; then die "$msg"; elif [[ $quiet -eq 0 ]]; then warn "$msg"; fi
  FORGEJO_SOCKET_SRC="unknown; PROTOCOL=http+unix needs FORGEJO_SOCKET"
}

resolve_forgejo_url() {  # $1 = 1 to warn instead of dying when the URL is unguessable, $2 = 1 to stay quiet
  # Works out the address the health check should ask. LOCAL_ROOT_URL is what
  # Forgejo itself uses for local requests, so it is the first choice.
  local tolerant=$1 quiet=$2 proto addr port host root
  root=$(ini_get "$FORGEJO_CONFIG" server LOCAL_ROOT_URL)
  if [[ -n $root ]]; then
    FORGEJO_URL=$root
    FORGEJO_URL_SRC="app.ini [server] LOCAL_ROOT_URL"
    return 0
  fi
  proto=$(ini_get "$FORGEJO_CONFIG" server PROTOCOL)
  addr=$(ini_get "$FORGEJO_CONFIG" server HTTP_ADDR)
  port=$(ini_get "$FORGEJO_CONFIG" server HTTP_PORT)
  if [[ -z $proto && -z $addr && -z $port ]]; then
    FORGEJO_URL=http://127.0.0.1:3000
    FORGEJO_URL_SRC="default; no [server] address in $FORGEJO_CONFIG"
    return 0
  fi
  case "${proto:-http}" in
    http)
      host=$addr
      # 0.0.0.0 and :: mean "every address"; a health check has to name one.
      if [[ -z $host || $host == 0.0.0.0 || $host == "::" ]]; then host=localhost; fi
      # An IPv6 literal needs square brackets before the port.
      if [[ $host == *:* ]]; then host="[$host]"; fi
      FORGEJO_URL="http://$host:${port:-3000}"
      FORGEJO_URL_SRC="app.ini [server] PROTOCOL, HTTP_ADDR, HTTP_PORT"
      ;;
    http+unix)
      # The host name in the URL is ignored; curl dials FORGEJO_SOCKET, which
      # resolve_forgejo_socket has already settled or complained about.
      FORGEJO_URL="http://unix"
      FORGEJO_URL_SRC="app.ini [server] PROTOCOL=http+unix"
      ;;
    *)
      # https needs a certificate the health check would have to trust, and
      # fcgi speaks a different protocol altogether. Guessing either would
      # fail for a reason that has nothing to do with the upgrade.
      local msg="PROTOCOL is $proto in $FORGEJO_CONFIG, so this script cannot work out an address to health check. Set FORGEJO_URL to a URL that answers /api/healthz, for example your reverse proxy; a guessed https URL would fail on the certificate and misreport a healthy upgrade"
      if [[ $tolerant -eq 0 ]]; then
        die "$msg"
      else
        if [[ $quiet -eq 0 ]]; then warn "$msg"; fi
        FORGEJO_URL=""
        FORGEJO_URL_SRC="unknown; PROTOCOL=$proto needs FORGEJO_URL"
      fi
      ;;
  esac
}

resolve_forgejo_settings() {  # --tolerant: never die, --quiet: do not print the block, --rollback: do not require the installed binary
  local tolerant=0 quiet=0 for_rollback=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tolerant) tolerant=1 ;;
      --quiet)    quiet=1 ;;
      --rollback) for_rollback=1 ;;
      *) die "resolve_forgejo_settings: unknown option $1 (this is a bug in the script)" ;;
    esac
    shift
  done

  local unit loaded=0 dsrc=default
  local exec_path="" argv_line="" user_prop="" workdir_prop="" env_line=""
  local wp="" cfg="" cfgroot="" cfgbase=""
  # A disagreement between app.ini and the unit over the work path, held back
  # so it prints after the settings block rather than before it.
  local wp_clash=""
  # The "systemd does not know that unit" complaint, held back until the
  # binary has been resolved: if nothing else points at an install either,
  # there is no install here to complain about and a plainer line is printed
  # instead.
  local unit_warn=""
  # Same for a unit whose ExecStart could not be read; printed with it.
  local bin_warn=""
  local -a argv=()

  if [[ -z $FORGEJO_SERVICE ]]; then
    FORGEJO_SERVICE=forgejo
    FORGEJO_SERVICE_SRC="default"
  else
    FORGEJO_SERVICE_SRC="env"
  fi
  unit=$(unit_name "$FORGEJO_SERVICE")
  if [[ $BACKUP_DIR_SRC == env ]]; then
    require_abs BACKUP_DIR "$BACKUP_DIR" "$tolerant"
  fi

  if unit_loaded "$FORGEJO_SERVICE"; then
    loaded=1
  elif [[ $tolerant -eq 1 ]]; then
    unit_warn="systemd does not know a unit called $unit, so the values below are defaults rather than what this host runs. Set FORGEJO_SERVICE to the unit that runs Forgejo."
    dsrc="default; $unit not found"
  else
    die_unknown_unit "$unit" FORGEJO_SERVICE gitea
  fi

  if [[ $loaded -eq 1 ]]; then
    exec_path=$(unit_exec_path "$FORGEJO_SERVICE")
    argv_line=$(unit_exec_argv "$FORGEJO_SERVICE")
    user_prop=$(unit_prop "$FORGEJO_SERVICE" User)
    workdir_prop=$(unit_prop "$FORGEJO_SERVICE" WorkingDirectory)
    env_line=$(unit_prop "$FORGEJO_SERVICE" Environment)
    workdir_prop=$(trim_slash "$workdir_prop")
    # argv[] is printed with a plain space between arguments and no quoting
    # at all, so an argument that contains a space cannot be told apart from
    # two arguments (checked against systemd 259). Only whole words - option
    # names and paths - are read back out. A path with a space comes back
    # truncated, and the checks further down then refuse it before anything
    # is stopped, naming the env var to set instead.
    read -r -a argv <<<"$argv_line"
    # Environment= is different: systemctl prints it as shell words, and a
    # value with a space or a shell character is double-quoted and escaped
    # the way a shell expects, e.g. `A=plain "B=has space"`. A plain word
    # split would cut that second entry in two, and env would then try to run
    # the second half as the command. eval on an array assignment undoes the
    # quoting exactly, and is safe here because systemd has already escaped
    # every character the shell could otherwise interpret.
    eval "FORGEJO_ENV=($env_line)"
  fi

  if [[ -n $FORGEJO_BIN ]]; then
    FORGEJO_BIN_SRC="env"
    require_abs FORGEJO_BIN "$FORGEJO_BIN" "$tolerant"
  elif [[ -n $exec_path ]]; then
    FORGEJO_BIN=$exec_path
    FORGEJO_BIN_SRC="unit ExecStart"
  elif [[ $loaded -eq 1 ]]; then
    # systemd knows the unit, so it runs some binary, but ExecStart= did not
    # come back in the shape unit_exec_path reads. The documented default is
    # no answer here: if a stale copy sits at that path, an upgrade would
    # replace a file the service never runs, restart the unchanged service,
    # and report success. So the value is only shown, and the operator is
    # asked for the real path; settings warns, everything else stops here,
    # before anything is touched.
    FORGEJO_BIN=/usr/local/bin/forgejo
    FORGEJO_BIN_SRC="default; $unit's ExecStart could not be read"
    bin_warn="systemd knows $unit but its ExecStart= could not be read back (systemctl show printed: '$(unit_prop "$FORGEJO_SERVICE" ExecStart)'), so the binary it runs is unknown and $FORGEJO_BIN is only a guess. Set FORGEJO_BIN to the binary $unit runs"
    if [[ $tolerant -eq 0 ]]; then die "$bin_warn"; fi
  else
    FORGEJO_BIN=/usr/local/bin/forgejo
    FORGEJO_BIN_SRC=$dsrc
  fi

  # Is Forgejo on this host at all? It is if systemd knows the unit, or the
  # binary is really there, or the operator set FORGEJO_SERVICE or
  # FORGEJO_BIN - naming either one is the operator saying the install is
  # here, so the unit warning above is what they need, not a "not installed"
  # line. With none of the three, there is nothing here to describe: say so
  # once and stop, rather than print a block of defaults for an install that
  # does not exist and warn about paths inside it. Only a --tolerant caller
  # reaches this with no unit; the others died on the unknown unit above.
  if [[ $loaded -eq 0 && ! -x $FORGEJO_BIN \
        && $FORGEJO_SERVICE_SRC != env && $FORGEJO_BIN_SRC != env ]]; then
    FORGEJO_PRESENT=0
    if [[ $quiet -eq 0 ]]; then
      log "Forgejo: not installed on this host (no $unit and no $FORGEJO_BIN). If it is installed under another name, set FORGEJO_SERVICE or FORGEJO_BIN."
    fi
    return 0
  fi
  if [[ -n $unit_warn && $quiet -eq 0 ]]; then
    warn "$unit_warn"
  fi
  if [[ -n $bin_warn && $quiet -eq 0 ]]; then
    warn "$bin_warn"
  fi

  if [[ -n $FORGEJO_USER ]]; then
    FORGEJO_USER_SRC="env"
  elif [[ -n $user_prop ]]; then
    FORGEJO_USER=$user_prop
    FORGEJO_USER_SRC="unit User"
  elif [[ $loaded -eq 1 ]]; then
    # systemd runs a system service whose unit sets no User= as root, so that
    # is the account this install's Forgejo actually runs as, and the backup
    # and doctor runs have to match it. git is the documented install's
    # account, which is only a safe guess when there is no unit to read.
    FORGEJO_USER=root
    FORGEJO_USER_SRC="systemd default; unit sets no User"
  else
    FORGEJO_USER=git
    FORGEJO_USER_SRC=$dsrc
  fi

  # The work path is settled before the config, because Forgejo's own default
  # config path sits under the work path. Forgejo reads the environment first
  # and the command line second, and the flag's Set wins
  # (modules/setting/path.go: readFromEnv() then readFromArgs()), so
  # --work-path is the higher source and is read first here; FORGEJO_WORK_DIR
  # in the environment beats the older GITEA_WORK_DIR; with none of them set,
  # Forgejo uses the directory holding the binary. Then, once the config file
  # has been read, WORK_PATH in app.ini replaces whatever those gave - which is
  # why the block further down, after the config path is known, can still
  # change the answer. The unit's WorkingDirectory= is never one of Forgejo's
  # sources; systemd only uses it to pick the directory the process starts in,
  # so this script does not read a work path out of it either.
  if [[ -n $FORGEJO_WORK_PATH ]]; then
    FORGEJO_WORK_PATH_SRC="env"
    require_abs FORGEJO_WORK_PATH "$FORGEJO_WORK_PATH" "$tolerant"
  else
    wp=$(argv_opt --work-path -w -- ${argv[@]+"${argv[@]}"})
    if [[ -n $wp ]]; then
      FORGEJO_WORK_PATH=$wp
      FORGEJO_WORK_PATH_SRC="unit ExecStart --work-path"
    else
      wp=$(forgejo_env_value FORGEJO_WORK_DIR)
      if [[ -n $wp ]]; then
        FORGEJO_WORK_PATH=$wp
        FORGEJO_WORK_PATH_SRC="unit Environment FORGEJO_WORK_DIR"
      else
        wp=$(forgejo_env_value GITEA_WORK_DIR)
        if [[ -n $wp ]]; then
          FORGEJO_WORK_PATH=$wp
          FORGEJO_WORK_PATH_SRC="unit Environment GITEA_WORK_DIR"
        fi
      fi
    fi
    # Checked here, inside this branch, because the operator's own
    # FORGEJO_WORK_PATH was already put through require_abs above and must not
    # be complained about twice.
    require_abs_work_path "$FORGEJO_WORK_PATH" "$FORGEJO_WORK_PATH_SRC" "$tolerant"
  fi
  FORGEJO_WORK_PATH=$(trim_slash "$FORGEJO_WORK_PATH")

  if [[ -n $FORGEJO_CONFIG ]]; then
    FORGEJO_CONFIG_SRC="env"
    require_abs FORGEJO_CONFIG "$FORGEJO_CONFIG" "$tolerant"
  else
    cfg=$(argv_opt --config -c -- ${argv[@]+"${argv[@]}"})
    if [[ -n $cfg && $cfg == /* ]]; then
      FORGEJO_CONFIG=$cfg
      FORGEJO_CONFIG_SRC="unit ExecStart --config"
    elif [[ -n $cfg ]]; then
      # Forgejo puts a relative --config through filepath.Abs, so it is
      # relative to the directory the daemon runs in: the unit's
      # WorkingDirectory, or / when the unit does not set one, which is what
      # systemd gives a system service. resolve_runner_settings does the same
      # for its -c. workdir_prop has any trailing slashes off already, and
      # stripping one more below is what keeps a WorkingDirectory of / from
      # joining as "//".
      cfgbase=${workdir_prop:-/}
      FORGEJO_CONFIG=${cfgbase%/}/$cfg
      FORGEJO_CONFIG_SRC="unit ExecStart --config, relative to WorkingDirectory"
    elif [[ $loaded -eq 1 ]]; then
      # No --config in ExecStart, so Forgejo works the path out itself
      # (modules/setting/path.go, InitWorkPathAndCfgProvider): the config is
      # custom/conf/app.ini under the work path, and the work path for this
      # purpose is whatever the environment or --work-path gave, else the
      # directory holding the binary - every source the block above reads, and
      # no other. WORK_PATH in app.ini cannot move the config: Forgejo reads
      # it only after it has found the file, which is why the block below runs
      # after this one. FORGEJO_CUSTOM and --custom-path are not read and
      # "custom" is assumed; an install that moved that directory sets
      # FORGEJO_CONFIG. There is deliberately no check that the file exists:
      # falling back to /etc/forgejo/app.ini here would point the backup and
      # the doctor run at a file the daemon is not reading. If it is missing,
      # the "cannot read the Forgejo config" check below says so and names the
      # variable to set.
      if [[ -n $FORGEJO_WORK_PATH ]]; then
        cfgroot=$FORGEJO_WORK_PATH
      else
        # The directory holding the binary. Done with a parameter expansion
        # rather than dirname so the script still needs nothing new; a bare
        # name with no slash in it means the current directory, and a binary
        # directly in / leaves the empty string, which the line below reads
        # as /.
        if [[ $FORGEJO_BIN == */* ]]; then cfgroot=${FORGEJO_BIN%/*}; else cfgroot=.; fi
      fi
      # Never double the slash below; a work path of / leaves the empty string,
      # which is right.
      FORGEJO_CONFIG=${cfgroot%/}/custom/conf/app.ini
      FORGEJO_CONFIG_SRC="Forgejo default; no --config in ExecStart"
    else
      # No unit to read, so there is nothing to work the path out from; the
      # documented install keeps it here.
      FORGEJO_CONFIG=/etc/forgejo/app.ini
      FORGEJO_CONFIG_SRC=$dsrc
    fi
  fi

  # Forgejo's last word on the work path: WORK_PATH in app.ini, which sits in
  # the keys before the first [section]. Forgejo reads it once the config file
  # has been found, and it replaces the value --work-path or the environment
  # gave. It is read here whatever the work path found above came from,
  # because it decides what Forgejo itself will use either way.
  wp=$(trim_slash "$(ini_get "$FORGEJO_CONFIG" "" WORK_PATH)")
  require_abs_work_path "$wp" "app.ini WORK_PATH" "$tolerant"
  if [[ $FORGEJO_WORK_PATH_SRC == env ]]; then
    # An operator override is passed to the CLI as --work-path, and app.ini
    # overrules that flag, so an override that disagrees with app.ini cannot
    # take effect: the dump and the doctor run would quietly use the app.ini
    # value instead of the one asked for. Better to stop and say so than to
    # print one path and use another. The same value in both is no conflict.
    if [[ -n $wp ]] && ! same_dir "$wp" "$FORGEJO_WORK_PATH"; then
      local wp_conflict="FORGEJO_WORK_PATH=$FORGEJO_WORK_PATH but $FORGEJO_CONFIG sets WORK_PATH = $wp. Forgejo follows WORK_PATH in app.ini and ignores --work-path, so this override cannot take effect and the dump and doctor runs would use $wp; either unset FORGEJO_WORK_PATH or change WORK_PATH in app.ini"
      if [[ $tolerant -eq 0 ]]; then
        die "$wp_conflict"
      else
        # Held back like the clash below, so the settings block is read first.
        wp_clash="$wp_conflict"
      fi
    fi
  elif [[ -n $wp ]]; then
    if [[ -n $FORGEJO_WORK_PATH ]] && ! same_dir "$wp" "$FORGEJO_WORK_PATH"; then
      wp_clash="app.ini sets WORK_PATH = $wp but the unit gives $FORGEJO_WORK_PATH (from: $FORGEJO_WORK_PATH_SRC); Forgejo uses the app.ini value and logs an error about the mismatch on every start, so this script uses $wp too. Remove the outdated value from the unit to silence it"
    fi
    FORGEJO_WORK_PATH=$wp
    FORGEJO_WORK_PATH_SRC="app.ini WORK_PATH"
  elif [[ -z $FORGEJO_WORK_PATH ]]; then
    # Nothing anywhere set one, so Forgejo will use the directory holding the
    # binary and this script leaves --work-path off; the warning at the end
    # of the block says so.
    FORGEJO_WORK_PATH_SRC="not set"
  fi

  # The socket comes first and on its own, so that it is found whether the
  # URL is read from app.ini or given by the operator.
  if [[ -n $FORGEJO_SOCKET ]]; then
    FORGEJO_SOCKET_SRC="env"
    require_abs FORGEJO_SOCKET "$FORGEJO_SOCKET" "$tolerant"
  elif [[ -r $FORGEJO_CONFIG ]]; then
    resolve_forgejo_socket "$tolerant" "$quiet"
  fi
  if [[ -n $FORGEJO_URL ]]; then
    FORGEJO_URL_SRC="env"
  elif [[ -r $FORGEJO_CONFIG ]]; then
    resolve_forgejo_url "$tolerant" "$quiet"
  else
    FORGEJO_URL=http://127.0.0.1:3000
    FORGEJO_URL_SRC="default; cannot read $FORGEJO_CONFIG"
  fi
  # So that "$FORGEJO_URL/api/healthz" never doubles the slash.
  FORGEJO_URL=${FORGEJO_URL%/}

  # Which database is behind this install. Not a path, so require_abs does not
  # apply. When the config cannot be read the type stays empty, which
  # db_is_external treats as "assume the cautious case".
  if [[ -n $FORGEJO_DB_TYPE ]]; then
    FORGEJO_DB_TYPE_SRC="env"
  elif [[ -r $FORGEJO_CONFIG ]]; then
    FORGEJO_DB_TYPE=$(ini_get "$FORGEJO_CONFIG" database DB_TYPE)
    if [[ -n $FORGEJO_DB_TYPE ]]; then
      FORGEJO_DB_TYPE_SRC="app.ini [database] DB_TYPE"
    else
      FORGEJO_DB_TYPE_SRC="unknown; no DB_TYPE in $FORGEJO_CONFIG"
    fi
  else
    FORGEJO_DB_TYPE_SRC="unknown; cannot read $FORGEJO_CONFIG"
  fi

  # Everything an upgrade depends on is checked here, while the service is
  # still untouched, so a wrong path cannot surface with Forgejo stopped.
  if [[ $tolerant -eq 0 ]]; then
    # A rollback is run precisely when the installed binary may be missing or
    # half-written, which is what it exists to undo, so it skips this one check
    # and nothing else. What a rollback needs is $FORGEJO_BIN.prev, and
    # rollback checks for that itself.
    if [[ $for_rollback -eq 0 ]]; then
      [[ -x $FORGEJO_BIN ]] \
        || die "no executable at $FORGEJO_BIN (from: $FORGEJO_BIN_SRC). This script upgrades an existing install; install Forgejo first (https://forgejo.org/docs/latest/admin/installation/binary/), or set FORGEJO_BIN to where it lives"
      # Inside this block because resolving with --rollback skips the whole
      # block; rollback calls require_prev_slot itself, right after resolving,
      # and before anything is stopped.
      require_prev_slot "$FORGEJO_BIN"
    fi
    # Only the exit status matters; the "no such user" text is replaced by an
    # actionable message.
    id -u "$FORGEJO_USER" >/dev/null 2>&1 \
      || die "there is no user called $FORGEJO_USER on this host (from: $FORGEJO_USER_SRC), and the backup and doctor runs have to run as the account that owns Forgejo's data. Set FORGEJO_USER to that account"
    [[ -r $FORGEJO_CONFIG ]] \
      || die "cannot read the Forgejo config at $FORGEJO_CONFIG (from: $FORGEJO_CONFIG_SRC). Expected the app.ini the server runs with; set FORGEJO_CONFIG to its path"
    if [[ -n $FORGEJO_WORK_PATH && ! -d $FORGEJO_WORK_PATH ]]; then
      die "the Forgejo work path $FORGEJO_WORK_PATH (from: $FORGEJO_WORK_PATH_SRC) is not a directory. Expected the directory holding Forgejo's data; set FORGEJO_WORK_PATH to it"
    fi
  fi
  if [[ $quiet -eq 0 ]]; then
    log "Forgejo settings for $unit (override any with the env var):"
    setting_line FORGEJO_SERVICE   "$FORGEJO_SERVICE"              "$FORGEJO_SERVICE_SRC"
    setting_line FORGEJO_BIN       "$FORGEJO_BIN"                  "$FORGEJO_BIN_SRC"
    setting_line FORGEJO_USER      "$FORGEJO_USER"                 "$FORGEJO_USER_SRC"
    setting_line FORGEJO_CONFIG    "$FORGEJO_CONFIG"               "$FORGEJO_CONFIG_SRC"
    setting_line FORGEJO_WORK_PATH "${FORGEJO_WORK_PATH:-(none)}"  "$FORGEJO_WORK_PATH_SRC"
    setting_line FORGEJO_URL       "${FORGEJO_URL:-(none)}"        "$FORGEJO_URL_SRC"
    if [[ -n $FORGEJO_SOCKET_SRC ]]; then
      setting_line FORGEJO_SOCKET  "${FORGEJO_SOCKET:-(none)}"     "$FORGEJO_SOCKET_SRC"
    fi
    setting_line FORGEJO_DB_TYPE   "${FORGEJO_DB_TYPE:-(unknown)}" "$FORGEJO_DB_TYPE_SRC"
    setting_line BACKUP_DIR        "$BACKUP_DIR"                   "$BACKUP_DIR_SRC"
    setting_line SKIP_BACKUP       "$SKIP_BACKUP"                  "$SKIP_BACKUP_SRC"
  fi

  # Said after the block, so the operator reads what was found first.
  if [[ -n $wp_clash && $quiet -eq 0 ]]; then
    warn "$wp_clash"
  fi
  if [[ -z $FORGEJO_WORK_PATH && $quiet -eq 0 ]]; then
    warn "no work path found in the unit or in $FORGEJO_CONFIG; Forgejo will fall back to the directory holding $FORGEJO_BIN. If that is not where its data lives, set FORGEJO_WORK_PATH."
  fi
}

# --- what the backup is worth ------------------------------------------------

# Only SQLite's database file travels inside the zip that `forgejo dump`
# writes; for every other database the zip carries an SQL dump instead, and
# anything other than sqlite3 - including a type this script could not read -
# is therefore treated as external, because that SQL is not a safe restore
# (Forgejo's upgrade guide, Backup section:
# https://forgejo.org/docs/latest/admin/upgrade/#backup).
db_is_external() { [[ $FORGEJO_DB_TYPE != sqlite3 ]]; }

# Said before anything is stopped, while the operator can still call the
# upgrade off and take a database dump of their own. It is its own function so
# that the wording can be read back from a sourced copy of these definitions,
# on a machine with no root and no Forgejo.
backup_note() {
  if db_is_external; then
    warn "the database is ${FORGEJO_DB_TYPE:-of unknown type}. The zip that forgejo dump writes does hold an SQL copy of the database, next to the repositories, attachments and the custom directory, but that copy must not be used to restore it (Forgejo's upgrade guide, https://forgejo.org/docs/latest/admin/upgrade/#backup, calls its bugs serious and long standing), so the zip is not a complete backup here. Taking a native dump (pg_dump, mysqldump) is your job; this script does not run one"
  else
    log "the database is SQLite, so the dump zip in $BACKUP_DIR will contain the database file itself and is a complete backup"
  fi
}

# The one sentence that every "put the data back" message is built around, so
# the rollback paths and on_exit cannot drift apart. Printed on stdout because
# the callers fold it into a message of their own.
restore_hint() {
  if db_is_external; then
    printf '%s\n' "restore the database from the native dump you took before the upgrade (the zip in $BACKUP_DIR holds repositories and files, but its SQL is not a safe restore); for SQLite the zip itself would contain the database"
  else
    printf '%s\n' "restore the newest dump zip in $BACKUP_DIR (it contains the database)"
  fi
}

resolve_runner_settings() {  # --tolerant: never die, --quiet: do not print the block, --rollback: do not require the installed binary
  local tolerant=0 quiet=0 for_rollback=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tolerant) tolerant=1 ;;
      --quiet)    quiet=1 ;;
      --rollback) for_rollback=1 ;;
      *) die "resolve_runner_settings: unknown option $1 (this is a bug in the script)" ;;
    esac
    shift
  done

  local unit loaded=0 dsrc=default
  local exec_path="" argv_line="" workdir_prop="" cfg="" regfile=""
  # Held back until the binary has been resolved, for the reason given in
  # resolve_forgejo_settings.
  local unit_warn=""
  # Same for a unit whose ExecStart could not be read; printed with it.
  local bin_warn=""
  local -a argv=()

  if [[ -z $RUNNER_SERVICE ]]; then
    RUNNER_SERVICE=forgejo-runner
    RUNNER_SERVICE_SRC="default"
  else
    RUNNER_SERVICE_SRC="env"
  fi
  unit=$(unit_name "$RUNNER_SERVICE")

  if unit_loaded "$RUNNER_SERVICE"; then
    loaded=1
  elif [[ $tolerant -eq 1 ]]; then
    unit_warn="systemd does not know a unit called $unit, so the values below are defaults rather than what this host runs. Set RUNNER_SERVICE to the unit that runs forgejo-runner."
    dsrc="default; $unit not found"
  else
    die_unknown_unit "$unit" RUNNER_SERVICE act_runner
  fi

  if [[ $loaded -eq 1 ]]; then
    exec_path=$(unit_exec_path "$RUNNER_SERVICE")
    argv_line=$(unit_exec_argv "$RUNNER_SERVICE")
    workdir_prop=$(unit_prop "$RUNNER_SERVICE" WorkingDirectory)
    workdir_prop=$(trim_slash "$workdir_prop")
    # Same lossy argv[] format as for the Forgejo unit, see there. A -c path
    # containing a space comes back truncated and is reported as unreadable.
    read -r -a argv <<<"$argv_line"
  fi

  if [[ -n $RUNNER_BIN ]]; then
    RUNNER_BIN_SRC="env"
    require_abs RUNNER_BIN "$RUNNER_BIN" "$tolerant"
  elif [[ -n $exec_path ]]; then
    RUNNER_BIN=$exec_path
    RUNNER_BIN_SRC="unit ExecStart"
  elif [[ $loaded -eq 1 ]]; then
    # Same rule as for Forgejo's binary, see there.
    RUNNER_BIN=/usr/local/bin/forgejo-runner
    RUNNER_BIN_SRC="default; $unit's ExecStart could not be read"
    bin_warn="systemd knows $unit but its ExecStart= could not be read back (systemctl show printed: '$(unit_prop "$RUNNER_SERVICE" ExecStart)'), so the binary it runs is unknown and $RUNNER_BIN is only a guess. Set RUNNER_BIN to the binary $unit runs"
    if [[ $tolerant -eq 0 ]]; then die "$bin_warn"; fi
  else
    RUNNER_BIN=/usr/local/bin/forgejo-runner
    RUNNER_BIN_SRC=$dsrc
  fi

  # Is the runner on this host at all? Same rule as for Forgejo: the unit is
  # loaded, or the binary is really there, or the operator set RUNNER_SERVICE
  # or RUNNER_BIN. A runner very often lives on a machine of its own, so with
  # none of the three this host simply does not run one, and saying that once
  # is more use than a block of defaults followed by a warning that a
  # registration file nobody has is missing.
  if [[ $loaded -eq 0 && ! -x $RUNNER_BIN \
        && $RUNNER_SERVICE_SRC != env && $RUNNER_BIN_SRC != env ]]; then
    RUNNER_PRESENT=0
    if [[ $quiet -eq 0 ]]; then
      log "forgejo-runner: not installed on this host (no $unit and no $RUNNER_BIN). If it is installed under another name, set RUNNER_SERVICE or RUNNER_BIN."
    fi
    return 0
  fi
  if [[ -n $unit_warn && $quiet -eq 0 ]]; then
    warn "$unit_warn"
  fi
  if [[ -n $bin_warn && $quiet -eq 0 ]]; then
    warn "$bin_warn"
  fi

  if [[ -n $RUNNER_HOME ]]; then
    RUNNER_HOME_SRC="env"
    require_abs RUNNER_HOME "$RUNNER_HOME" "$tolerant"
  elif [[ -n $workdir_prop ]]; then
    RUNNER_HOME=$workdir_prop
    RUNNER_HOME_SRC="unit WorkingDirectory"
  elif [[ $loaded -eq 1 ]]; then
    # systemd starts a system service whose unit sets no WorkingDirectory= in
    # /, so that is where a relative -c and the .runner registration file
    # resolve for this daemon. /home/runner would be a guess about a unit that
    # was read and found to say nothing of the sort.
    RUNNER_HOME=/
    RUNNER_HOME_SRC="systemd default; unit sets no WorkingDirectory"
  else
    # No unit to read at all, so the documented install is the best there is.
    RUNNER_HOME=/home/runner
    RUNNER_HOME_SRC=$dsrc
  fi
  RUNNER_HOME=$(trim_slash "$RUNNER_HOME")

  if [[ -n $RUNNER_CONFIG ]]; then
    RUNNER_CONFIG_SRC="env"
    require_abs RUNNER_CONFIG "$RUNNER_CONFIG" "$tolerant"
  else
    cfg=$(argv_opt --config -c -- ${argv[@]+"${argv[@]}"})
    if [[ -n $cfg ]]; then
      RUNNER_CONFIG=$cfg
      RUNNER_CONFIG_SRC="unit ExecStart -c"
    else
      RUNNER_CONFIG_SRC="not set"
    fi
  fi
  # A relative path in the unit is relative to the directory the daemon runs in.
  # The %/ keeps a RUNNER_HOME of / from joining as "//".
  if [[ -n $RUNNER_CONFIG && $RUNNER_CONFIG != /* ]]; then
    RUNNER_CONFIG=${RUNNER_HOME%/}/$RUNNER_CONFIG
  fi

  # The registration the runner already holds lives in this file; it survives a
  # binary swap, so the upgrade only has to confirm it is there.
  if [[ -n $RUNNER_CONFIG ]]; then
    regfile=$(yaml_get "$RUNNER_CONFIG" runner file)
  fi
  if [[ -n $regfile ]]; then
    RUNNER_REG_FILE_SRC="$RUNNER_CONFIG, runner.file"
  else
    regfile=.runner
    RUNNER_REG_FILE_SRC="default"
  fi
  if [[ $regfile == /* ]]; then
    RUNNER_REG_FILE=$regfile
  else
    # Relative to the directory the daemon runs in, which is RUNNER_HOME.
    RUNNER_REG_FILE=${RUNNER_HOME%/}/$regfile
  fi

  if [[ $tolerant -eq 0 ]]; then
    # Skipped for a rollback, and only this check: the binary a rollback is
    # undoing may be missing or half-written, and what it needs is
    # $RUNNER_BIN.prev, which rollback checks for itself.
    if [[ $for_rollback -eq 0 ]]; then
      [[ -x $RUNNER_BIN ]] \
        || die "no executable at $RUNNER_BIN (from: $RUNNER_BIN_SRC). This script upgrades an existing install; install forgejo-runner first (https://forgejo.org/docs/latest/admin/actions/installation/binary/), or set RUNNER_BIN to where it lives"
      # Inside this block because resolving with --rollback skips the whole
      # block; rollback calls require_prev_slot itself, right after resolving,
      # and before anything is stopped.
      require_prev_slot "$RUNNER_BIN"
    fi
    if [[ -n $RUNNER_CONFIG && ! -r $RUNNER_CONFIG ]]; then
      warn "cannot read the runner config at $RUNNER_CONFIG (from: $RUNNER_CONFIG_SRC), so the registration file below is a guess. Set RUNNER_CONFIG if the daemon uses another file."
    fi
  fi
  if [[ $quiet -eq 0 ]]; then
    log "forgejo-runner settings for $unit (override any with the env var, except RUNNER_REG_FILE, which follows RUNNER_HOME and RUNNER_CONFIG):"
    setting_line RUNNER_SERVICE  "$RUNNER_SERVICE"             "$RUNNER_SERVICE_SRC"
    setting_line RUNNER_BIN      "$RUNNER_BIN"                 "$RUNNER_BIN_SRC"
    setting_line RUNNER_HOME     "$RUNNER_HOME"                "$RUNNER_HOME_SRC"
    setting_line RUNNER_CONFIG   "${RUNNER_CONFIG:-(none)}"    "$RUNNER_CONFIG_SRC"
    setting_line RUNNER_REG_FILE "$RUNNER_REG_FILE"            "$RUNNER_REG_FILE_SRC"
  fi

  # Said after the block, so the operator reads what was found first.
  if [[ ! -f $RUNNER_REG_FILE && $quiet -eq 0 ]]; then
    warn "no registration file at $RUNNER_REG_FILE (from: $RUNNER_REG_FILE_SRC); set RUNNER_HOME or RUNNER_CONFIG correctly, or the runner may need re-registering after the upgrade"
  fi
}

run_as() {  # $1 = user, rest = the command to run as that user
  local user=$1
  shift
  if command -v runuser >/dev/null; then
    runuser -u "$user" -- "$@"
  elif command -v sudo >/dev/null; then
    sudo -u "$user" "$@"
  else
    die "need runuser or sudo to run a command as $user and neither is on PATH. Install util-linux (which provides runuser) or sudo"
  fi
}

as_forgejo() {  # run the Forgejo binary as its own user with the resolved settings
  # Forgejo wants its global flags before the subcommand: "forgejo --config X
  # dump --file Y", not "forgejo dump --config X". The cd is not about the work
  # path - with none given Forgejo falls back to the directory holding the
  # binary, not to the directory it was started in - it is there because
  # run_as has to start in a directory FORGEJO_USER can enter, and the one this
  # script was run from may not be.
  #
  # Both the unit's Environment= and --work-path are passed. Forgejo lets the
  # flag beat the environment, and then app.ini's WORK_PATH beat both, which is
  # the same order resolve_forgejo_settings followed, so the work path the CLI
  # ends up using is the one the settings block printed - and the same one the
  # daemon uses.
  local -a cmd
  cmd=(env ${FORGEJO_ENV[@]+"${FORGEJO_ENV[@]}"} "$FORGEJO_BIN" --config "$FORGEJO_CONFIG")
  if [[ -n $FORGEJO_WORK_PATH ]]; then
    cmd+=(--work-path "$FORGEJO_WORK_PATH")
  fi
  cmd+=("$@")
  ( cd "${FORGEJO_WORK_PATH:-/}" && run_as "$FORGEJO_USER" "${cmd[@]}" )
}

# --- health checks -----------------------------------------------------------

healthz() {  # $1 = seconds to allow this one attempt (default 5) -> 0 when the server answers 200
  # Nothing but a 200 counts as healthy. This used to ask curl with -f, which
  # also passes any 3xx: a reverse proxy in front of a stopped Forgejo answers
  # 302 to a login page, and the upgrade would have been reported as healthy
  # with the server down. So the status code is read instead and compared.
  # Connection refused and a timeout are still expected while the service is
  # starting, and curl's own message is dropped for them; curl failing then
  # makes this function fail, as before.
  # -q goes first because curl only honours it there: it stops curl reading a
  # .curlrc, and the script runs as root, whose .curlrc could say "location"
  # and turn that same 302 into the login page's 200 again. Every curl call in
  # this script passes it for the same reason.
  local code
  local -a opts=(-q -s -o /dev/null -w '%{http_code}' --max-time "${1:-5}")
  if [[ -n $FORGEJO_SOCKET ]]; then
    opts+=(--unix-socket "$FORGEJO_SOCKET")
  fi
  code=$(curl "${opts[@]}" "$FORGEJO_URL/api/healthz" 2>/dev/null) || return 1
  [[ $code == 200 ]]
}

wait_forgejo_healthy() {
  local limit=60 start=$SECONDS left
  log "Waiting up to ${limit}s for $FORGEJO_URL/api/healthz"
  # Driven by the clock, not by a count of attempts: an attempt can take its
  # whole per-request allowance when the server accepts the connection but
  # does not answer, and sixty of those would be six minutes, not one. Each
  # attempt gets at most five seconds and never more than what is left.
  while left=$(( limit - (SECONDS - start) )) && [[ $left -gt 0 ]]; do
    if healthz "$(( left < 5 ? left : 5 ))"; then
      log "Service answered after $(( SECONDS - start ))s"
      return 0
    fi
    sleep 1
  done
  die "service did not answer $FORGEJO_URL/api/healthz within ${limit}s"
}

wait_runner_active() {
  sleep 3
  systemctl is-active --quiet "$RUNNER_SERVICE" \
    || die "runner is not active 3s after start"
}

# --- forgejo server ----------------------------------------------------------

upgrade_forgejo() {
  need_root
  acquire_lock
  # Read the install before anything else: which binary, which user, which
  # config, and which address to health check. This dies on anything that
  # would not work, while the service is still running.
  resolve_forgejo_settings
  local want cur new got out
  want=$(resolve_version "$1" "$FORGEJO_REPO") || die "could not resolve version"
  [[ -n $want ]] || die "could not determine Forgejo version"
  cur=$(installed_forgejo)
  log "Forgejo: installed $cur, target $want"
  [[ $cur != "$want" ]] || { log "already on $want, nothing to do"; return; }

  if [[ ${cur%%.*} != "${want%%.*}" ]]; then
    warn "major version change ${cur%%.*} -> ${want%%.*}: read the release notes first:"
    warn "  $FORGEJO_REPO/src/branch/forgejo/release-notes-published/$want.md"
    # The breaking changes for a major version are written up in the notes for
    # the first release of that line, which is a different file unless that
    # first release is the very version being installed.
    if [[ $want != "${want%%.*}.0.0" ]]; then
      warn "  the breaking changes for ${want%%.*} are listed in the notes for the first release of that line: $FORGEJO_REPO/src/branch/forgejo/release-notes-published/${want%%.*}.0.0.md"
    fi
    warn "  upgrade paths known to cause trouble are listed at https://forgejo.org/docs/latest/admin/upgrade/#when-upgrading-from--known-problematic-versions-or-upgrade-paths"
    local prompt="Continue? [y/N] "
    if db_is_external; then
      # Going back from a major upgrade means putting the database back as
      # well, and for anything but SQLite the zip this script writes cannot
      # do that. Better said now than after the migration has run.
      warn "rolling back a major upgrade needs the database restored, and the dump zip cannot do that for ${FORGEJO_DB_TYPE:-this database}; take a native database dump now if you have not"
      prompt="Release notes read and database backed up. Continue? [y/N] "
    fi
    # There is no way to confirm without a terminal: passing an exact version
    # still lands here, because it is the change of major version that needs
    # a decision, not how the version was chosen.
    [[ -t 0 ]] || die "major version change ${cur%%.*} -> ${want%%.*} needs confirmation and stdin is not a terminal; run this from a terminal so the prompt can be answered"
    read -r -p "$prompt" a; [[ $a == [yY] ]] || exit 1
  fi

  ensure_key
  new=$(fetch_and_verify "$FORGEJO_REPO" "forgejo-$want-linux-$(arch)" "$want")
  # Captured first, so a binary that will not run at all says why instead of
  # being reported as the wrong version. Then compared as a whole string, not
  # grepped: a pattern built from $want treats the dots as wildcards and has no
  # end anchor, so a check for 16.0.5 used to accept a binary reporting 16.0.50.
  out=$("$new" --version 2>&1) \
    || die "$new --version failed (exit $?): '${out%%$'\n'*}'. The downloaded binary does not run on this host; check the architecture reported by uname -m against the asset name, then rerun"
  got=$(parse_forgejo_version "$out")
  [[ $got == "$want" ]] \
    || die "downloaded binary reports version '${got:-none}', expected $want. Its --version output was: '${out%%$'\n'*}'"

  # Prove what can be proved while the service is still up. A health check that
  # cannot pass now will not pass after the restart either, and a backup that
  # cannot run is better found out now than with the service already stopped -
  # the one moment when a surprise is most expensive.
  if systemctl is-active --quiet "$FORGEJO_SERVICE"; then
    healthz \
      || die "$FORGEJO_SERVICE is running but does not answer $FORGEJO_URL/api/healthz (from: $FORGEJO_URL_SRC), so the check after the upgrade would fail for the same reason and report a broken upgrade. Set FORGEJO_URL to the address the server actually listens on"
    log "Flushing queues"
    # The service is up, so a failure here is a real problem with the queues
    # rather than a stopped service; it is still not worth aborting an upgrade.
    as_forgejo manager flush-queues --timeout 2m \
      || warn "flush-queues failed, continuing. Forgejo's upgrade guide says queued data is not guaranteed to be readable by the next version and to rerun the flush with a longer --timeout (https://forgejo.org/docs/latest/admin/upgrade/#preparing-the-forgejo-upgrade); press Ctrl-C now to do that first"
  else
    warn "$FORGEJO_SERVICE is not running, so there are no queues to flush and no way to health check it before the upgrade"
  fi

  if [[ $SKIP_BACKUP != 1 ]]; then
    # What the dump about to be taken is actually worth depends on the
    # database, and this is the last moment at which the operator can stop and
    # take a native dump instead.
    backup_note
    # Make the backup directory now rather than after the stop: creating it is
    # the same work either way, and a failure here costs no downtime.
    # The group is the account's primary group, not a group named after the
    # account: a service user called forgejo may well belong to group git.
    # Only when it is not already there: an existing directory may be centrally
    # managed backup storage, whose owner and mode are somebody's decision and
    # must not be rewritten by an upgrade. Whether it is usable as it stands is
    # settled by the "test -w" run as FORGEJO_USER a few lines below.
    if [[ ! -d $BACKUP_DIR ]]; then
      install -d -o "$FORGEJO_USER" -g "$(id -gn "$FORGEJO_USER")" -m 750 "$BACKUP_DIR"
    fi
    # What the three checks below prove: the binary starts as FORGEJO_USER with
    # the unit's Environment, and that account can read the config and write
    # the dump where the dump is going. What they do not prove: that app.ini
    # parses. Nothing read-only does. "dump --help" prints help and exits
    # before the config is looked at, and "doctor check --run paths" does load
    # app.ini but writes INTERNAL_TOKEN and JWT_SECRET back into it when they
    # are missing, and this script never edits configuration. Both were run
    # against forgejo 16.0.5 to settle it.
    local runcheck
    runcheck=$(as_forgejo --version 2>&1) \
      || die "could not run $FORGEJO_BIN as $FORGEJO_USER, and the backup runs as that account, so it would fail with the service already stopped. It said:
$runcheck
Check FORGEJO_USER and FORGEJO_BIN, or set SKIP_BACKUP=1 to upgrade without a dump"
    run_as "$FORGEJO_USER" test -r "$FORGEJO_CONFIG" \
      || die "$FORGEJO_USER cannot read $FORGEJO_CONFIG (from: $FORGEJO_CONFIG_SRC), and the backup runs as that account, so it would fail with the service already stopped. Let $FORGEJO_USER read the file, or set FORGEJO_CONFIG to the app.ini that account uses"
    run_as "$FORGEJO_USER" test -w "$BACKUP_DIR" \
      || die "$FORGEJO_USER cannot write to $BACKUP_DIR, and the dump is written by that account, so the backup would fail with the service already stopped. Give $BACKUP_DIR to $FORGEJO_USER, or set BACKUP_DIR to a directory that account can write"
  fi

  log "Stopping $FORGEJO_SERVICE"
  # Set before the stop, not after: a stop that fails or is interrupted may
  # already have taken the service down, and on_exit has to know about it.
  # From here until the health check passes, any exit is reported by on_exit.
  STOPPED_SVC="$FORGEJO_SERVICE"
  STOPPED_KIND=forgejo
  STOPPED_BIN="$FORGEJO_BIN"
  systemctl stop "$FORGEJO_SERVICE"

  if [[ $SKIP_BACKUP != 1 ]]; then
    local dump
    dump="$BACKUP_DIR/forgejo-$cur-$(date +%Y%m%d-%H%M%S).zip"
    log "Backing up to $dump"
    as_forgejo dump --file "$dump"
  else
    warn "SKIP_BACKUP=1, no dump taken"
  fi

  install_binary "$new" "$FORGEJO_BIN"

  log "Starting $FORGEJO_SERVICE"
  systemctl start "$FORGEJO_SERVICE"

  wait_forgejo_healthy
  # Healthy again, so on_exit has nothing to report from here on.
  STOPPED_SVC=""

  log "Running doctor"
  as_forgejo doctor check --all \
    || warn "doctor reported problems, review output above"

  log "Forgejo now: $("$FORGEJO_BIN" --version)"
}

# --- runner ------------------------------------------------------------------

upgrade_runner() {
  need_root
  acquire_lock
  # Read the install first: which binary, which directory, and where the
  # registration file is. This dies on anything that would not work, while the
  # runner is still up.
  resolve_runner_settings
  local want cur new got out
  want=$(resolve_version "$1" "$RUNNER_REPO") || die "could not resolve version"
  [[ -n $want ]] || die "could not determine runner version"
  cur=$(installed_runner)
  log "forgejo-runner: installed $cur, target $want"
  [[ $cur != "$want" ]] || { log "already on $want, nothing to do"; return; }

  ensure_key
  new=$(fetch_and_verify "$RUNNER_REPO" "forgejo-runner-$want-linux-$(arch)" "$want")
  # Captured first, so a binary that will not run at all says why instead of
  # being reported as the wrong version. Then compared as a whole string, not
  # grepped: a pattern built from $want treats the dots as wildcards and had no
  # anchors at all here, so a check for 1.2.3 used to accept 11.2.30.
  out=$("$new" --version 2>&1) \
    || die "$new --version failed (exit $?): '${out%%$'\n'*}'. The downloaded binary does not run on this host; check the architecture reported by uname -m against the asset name, then rerun"
  got=$(parse_runner_version "$out")
  [[ $got == "$want" ]] \
    || die "downloaded binary reports version '${got:-none}', expected $want. Its --version output was: '${out%%$'\n'*}'"

  # SIGTERM does not stop the runner at once. It waits for the jobs already
  # running, for as long as its own runner.shutdown_timeout allows - 3h in the
  # config that "forgejo-runner generate-config" writes, while unset or zero
  # cancels them straight away - and then cancels whatever is still going.
  # TimeoutStopSec=infinity in the stock unit only means systemd never kills
  # it first, so this stop can take hours unless a drop-in sets a finite value.
  log "Stopping $RUNNER_SERVICE (waits for running jobs, up to the runner's shutdown_timeout)"
  # Set before the stop, not after: the wait for jobs can be hours, and a
  # Ctrl-C during it still leaves the runner stopping. From here until the
  # runner is active again, any exit is reported by on_exit.
  STOPPED_SVC="$RUNNER_SERVICE"
  STOPPED_KIND=runner
  STOPPED_BIN="$RUNNER_BIN"
  systemctl stop "$RUNNER_SERVICE"

  install_binary "$new" "$RUNNER_BIN"

  log "Starting $RUNNER_SERVICE"
  systemctl start "$RUNNER_SERVICE"

  wait_runner_active
  # Running again, so on_exit has nothing to report from here on.
  STOPPED_SVC=""

  log "forgejo-runner now: $("$RUNNER_BIN" --version)"
  log "Confirm it shows online under Site Administration > Actions > Runners"
}

# --- rollback / check --------------------------------------------------------

rollback_needs_manual_start() {  # $1 = kind, $2 = current version or empty, $3 = previous version -> 0 when the service must not be started again by this script
  # Forgejo will not run on a database a newer release has already migrated: it
  # logs that the database is for a newer Forgejo and exits at once, keeping
  # the data unchanged. Nothing is corrupted, but starting it would leave the
  # operator with a dead service and no hint that the dump has to go back
  # first, so the service is left stopped and the message says what to do.
  # Only across a major version, which is where Forgejo's migrations live; only
  # for the server, since the runner keeps no database; and only when the
  # version being replaced could actually be read, because an unreadable one is
  # evidence of nothing.
  [[ $1 == forgejo && -n $2 && ${2%%.*} != "${3%%.*}" ]]
}

rollback() {
  need_root
  acquire_lock
  local bin svc kind repo restore parse example nostart=0 reason="" prev="" cur="" out
  case "${2:-}" in
    "")         : ;;
    --no-start) nostart=1; reason="--no-start was given" ;;
    *) die "unknown option '$2'. Usage: rollback forgejo|runner [--no-start], where --no-start puts the previous binary back and leaves the service stopped" ;;
  esac
  # Same reading of the unit and config as an upgrade does, so a rollback puts
  # the binary back where this host really keeps it. --rollback drops only the
  # "there is an executable at BIN" check: a rollback is for undoing an upgrade
  # that may have left no usable binary there at all.
  case "$1" in
    forgejo) resolve_forgejo_settings --rollback
             bin=$FORGEJO_BIN; svc=$FORGEJO_SERVICE; kind=forgejo
             repo=$FORGEJO_REPO; parse=parse_forgejo_version
             example='forgejo version 16.0.4'
             restore="If the version you are undoing changed the database schema, put the database back before starting the service: $(restore_hint)" ;;
    runner)  resolve_runner_settings --rollback
             bin=$RUNNER_BIN;  svc=$RUNNER_SERVICE;  kind=runner
             repo=$RUNNER_REPO; parse=parse_runner_version
             example='forgejo-runner version v13.1.0'
             restore="There is no dump to restore for the runner, and its registration in $RUNNER_REG_FILE survives a binary swap" ;;
    *) die "rollback forgejo|runner [--no-start]" ;;
  esac
  # The same plain-file rule an upgrade applies, and for the same reason: the
  # -x check just below follows a symbolic link, so a link at $bin.prev would
  # pass it, and the "mv -fT" further down would then put the link itself in
  # front of the service rather than the binary an upgrade set aside.
  require_prev_slot "$bin"
  [[ -x $bin.prev ]] \
    || die "no previous binary at $bin.prev to roll back to, so nothing was changed and $svc was left exactly as it was. This script keeps the binary it replaced at that path only until the next upgrade overwrites it, so there is nothing older to go back to here. To go back by hand: download the release you want from $repo/releases, check its signature, and install it over $bin. $restore"
  # Checked before anything is stopped: the restore below moves $bin.prev to
  # exactly $bin, and a directory sitting at that name is not something to move
  # a binary onto.
  [[ ! -d $bin ]] \
    || die "$bin is a directory (or a link to one) rather than a file, and the previous binary would be moved to exactly that path. Nothing was changed and $svc was left exactly as it was. Move the directory at $bin out of the way, then rerun this rollback. $restore"

  # Read both versions before anything is stopped. The previous binary is the
  # one that will be running afterwards, so it has to run at all to be worth
  # putting back, and what it reports decides whether starting it is safe.
  out=$("$bin.prev" --version 2>&1) \
    || die "$bin.prev does not run (exit $?): '${out%%$'\n'*}'. The binary this rollback would put back has to run to be worth restoring, so nothing was changed and $svc was left exactly as it was. Download the release you want from $repo/releases, check its signature, and install it over $bin by hand. $restore"
  prev=$("$parse" "$out")
  # A binary that runs but does not say which release it is cannot be the
  # one this script set aside, so it is not put in front of the service.
  # Parsed before the stop, like the run check above, so nothing has changed
  # when this stops.
  [[ -n $prev ]] \
    || die "$bin.prev runs but does not report a version this script recognises: '${out%%$'\n'*}'. Expected a line like '$example', so this is not the binary an upgrade set aside, nothing was changed, and $svc was left exactly as it was. Download the release you want from $repo/releases, check its signature, and install it over $bin by hand. $restore"
  # The installed binary, by contrast, is the one a rollback exists to undo: it
  # may be half-written or the wrong architecture. A failure here is expected
  # and leaves the version unknown rather than stopping the rollback.
  if [[ -x $bin ]]; then
    if out=$("$bin" --version 2>&1); then cur=$("$parse" "$out"); fi
  fi
  log "Rolling back $bin from ${cur:-unknown} to $prev"

  if [[ $nostart -eq 0 ]] && rollback_needs_manual_start "$kind" "$cur" "$prev"; then
    nostart=1
    reason="going from $cur back to $prev crosses a major version, and Forgejo refuses to start an older release on a database a newer one has already migrated - it would log that the database is for a newer Forgejo and exit at once"
  fi

  # Tracked before the stop for the same reason as in the upgrades.
  STOPPED_SVC="$svc"
  STOPPED_KIND="$kind"
  STOPPED_BIN="$bin"
  systemctl stop "$svc"
  # 2, not 1: the move consumes the .prev file, so if this rollback fails there
  # is no older binary left and on_exit must not suggest rolling back again.
  # Set before the move, not after: bash runs the INT and TERM traps between
  # two commands, so a Ctrl-C landing after the rename had happened but before
  # this line would have on_exit say the binary was untouched. The rename is
  # within one directory, so it either happened or it did not, and on_exit
  # tells the two apart by whether .prev is still there.
  #
  # "-T" makes $bin the destination itself: a directory that appeared at that
  # name since the check above fails the move rather than swallowing .prev as
  # $bin/<name>. on_exit then still finds .prev and says the previous binary
  # was not moved back.
  BINARY_REPLACED=2
  mv -fT "$bin.prev" "$bin"

  if [[ $nostart -eq 1 ]]; then
    log "The previous binary is back in place at $bin, but $svc was left stopped on purpose: $reason"
    if [[ $kind == forgejo ]]; then
      log "Next, before it is started again (see https://forgejo.org/docs/latest/admin/upgrade/#backup): $(restore_hint)"
      log "Then: systemctl start $svc"
    else
      log "Next: start it with: systemctl start $svc"
    fi
    # This service is stopped on purpose and the lines above are the saying
    # so, which is what the tracking exists to make sure of. Cleared only once
    # every instruction is out, so an interrupt in between still gets
    # on_exit's journal and remedy.
    STOPPED_SVC=""
    return 0
  fi

  systemctl start "$svc"
  case "$kind" in
    forgejo) wait_forgejo_healthy ;;
    runner)  wait_runner_active ;;
  esac
  STOPPED_SVC=""
  log "$svc is active again with $("$bin" --version)"
}

settings() {
  # Read-only: shows what an upgrade would use and where each value came from.
  # Tolerant, so it still says something useful on a host where the unit or
  # the config is missing, and so it can be run without root.
  resolve_forgejo_settings --tolerant
  resolve_runner_settings --tolerant
}

check() {
  local f r fl rl
  # Tolerant and quiet: check only reports versions, and it is the one command
  # that is expected to work on a half-installed host.
  resolve_forgejo_settings --tolerant --quiet
  resolve_runner_settings --tolerant --quiet
  # A component that is not installed here is reported as "not installed",
  # with a dash for the latest release, and its release API is not asked about
  # at all. A Forgejo host with no runner must not have `check` fail because
  # the runner's releases could not be fetched: it has no stake in them.
  # "none" still means something different - the unit is there but the binary
  # it names is missing - and installed_forgejo/installed_runner say that.
  #
  # Each latest tag is captured before printing: inside a printf argument
  # list, "$(...)" failing would not fail the printf itself, so a dead API
  # would silently print blank "latest" columns and exit 0 instead of stopping
  # here.
  if [[ $FORGEJO_PRESENT -eq 1 ]]; then
    f=$(installed_forgejo)
    fl=$(latest_tag "$FORGEJO_REPO") \
      || die "could not fetch the latest Forgejo release from the code.forgejo.org API; check that this host can reach https://code.forgejo.org, then rerun"
    [[ -n $fl ]] \
      || die "the code.forgejo.org API answered but gave no Forgejo release tag; expected a tag_name in the response. Check https://code.forgejo.org/forgejo/forgejo/releases and rerun"
  else
    f="not installed"
    fl="-"
  fi
  if [[ $RUNNER_PRESENT -eq 1 ]]; then
    r=$(installed_runner)
    rl=$(latest_tag "$RUNNER_REPO") \
      || die "could not fetch the latest forgejo-runner release from the code.forgejo.org API; check that this host can reach https://code.forgejo.org, then rerun"
    [[ -n $rl ]] \
      || die "the code.forgejo.org API answered but gave no forgejo-runner release tag; expected a tag_name in the response. Check https://code.forgejo.org/forgejo/runner/releases and rerun"
  else
    r="not installed"
    rl="-"
  fi
  printf '%-16s %-12s %-12s\n' component installed latest
  printf '%-16s %-12s %-12s\n' forgejo "$f" "$fl"
  printf '%-16s %-12s %-12s\n' forgejo-runner "$r" "$rl"
  echo
  echo "Security announcements: https://codeberg.org/forgejo/security-announcements/issues"
}

# --- main --------------------------------------------------------------------

case "${1:-}" in
  check)    check ;;
  settings) settings ;;
  forgejo)  upgrade_forgejo "${2:?usage: $0 forgejo <version|latest>}" ;;
  runner)   upgrade_runner  "${2:?usage: $0 runner <version|latest>}" ;;
  rollback) rollback "${2:-}" "${3:-}" ;;
  # The usage text is this script's own header comment. Adding a line to it
  # means moving the end of this range, which runs to the last header line.
  *) sed -n '2,36p' "$0"; exit 1 ;;
esac
