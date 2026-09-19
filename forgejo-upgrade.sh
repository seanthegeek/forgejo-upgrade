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
#   BACKUP_DIR         /var/backups/forgejo    (must be writable by FORGEJO_USER)
#   SKIP_BACKUP        set to 1 to skip `forgejo dump`
#   RUNNER_SERVICE     forgejo-runner
#   RUNNER_BIN         /usr/local/bin/forgejo-runner
#   RUNNER_HOME        /home/runner            (holds the .runner registration file)
#   RUNNER_CONFIG      unset; read from the -c flag in the unit's ExecStart
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
# The unit's Environment= settings, passed to the binary when the script runs
# it as FORGEJO_USER. Filled in by resolve_forgejo_settings.
FORGEJO_ENV=()
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
RUNNER_SERVICE_SRC=""
RUNNER_BIN_SRC=""; RUNNER_HOME_SRC=""; RUNNER_CONFIG_SRC=""
RUNNER_REG_FILE_SRC=""

RELEASE_KEY=EB114F5E6C0DC2BCDD183550A4B61A2DC5923710
KEYSERVER=hkps://keys.openpgp.org
FORGEJO_REPO=https://code.forgejo.org/forgejo/forgejo
RUNNER_REPO=https://code.forgejo.org/forgejo/runner

WORKDIR=$(mktemp -d /tmp/forgejo-upgrade.XXXXXX)

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

on_exit() {
  local rc=$?
  if [[ -n $STOPPED_SVC ]]; then
    warn "did not finish; $STOPPED_SVC is probably still stopped. Last 40 journal lines:"
    journalctl -u "$STOPPED_SVC" -n 40 --no-pager >&2 \
      || warn "could not read the journal; try it by hand: journalctl -u $STOPPED_SVC -n 40"
    case $BINARY_REPLACED in
      1) warn "a new binary was written to $STOPPED_BIN (the copy may not have completed) and the previous one is kept at $STOPPED_BIN.prev"
         warn "try: systemctl start $STOPPED_SVC"
         warn "if that fails, put the previous binary back with: $0 rollback $STOPPED_KIND" ;;
      # 2 means a rollback already moved the previous binary back over the new
      # one, so no .prev file is left and rolling back again is not possible.
      2) warn "the previous binary is back in place at $STOPPED_BIN and no $STOPPED_BIN.prev remains"
         warn "read the journal above, then start the service with: systemctl start $STOPPED_SVC"
         # on_exit cannot tell for certain that this is the server rather than
         # the runner, so the remedy is offered against what the journal says.
         warn "if the journal says the database is for a newer Forgejo, restore the dump from $BACKUP_DIR first (https://forgejo.org/docs/latest/admin/upgrade/#backup-and-restore), then start" ;;
      *) warn "the binary was not changed. Start the service again with: systemctl start $STOPPED_SVC" ;;
    esac
  fi
  rm -rf "$WORKDIR" || warn "could not remove the temporary directory $WORKDIR; delete it by hand"
  exit "$rc"
}
trap on_exit EXIT
# Ctrl-C and SIGTERM exit instead of killing the shell outright, so the EXIT
# trap above still runs and still reports a service left stopped.
trap 'exit 130' INT
trap 'exit 143' TERM

need_root() { [[ $EUID -eq 0 ]] || die "run as root (sudo)"; }

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
  curl -fsSL "$api/releases/latest" \
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
  # the VALIDSIG match below does that.
  GPG_STATUS=$(gpg --status-fd 1 --verify "$1" "$2" 2>/dev/null || true)
  grep -Eq "^\[GNUPG:\] VALIDSIG .* $RELEASE_KEY$" <<<"$GPG_STATUS"
}

gpg_missing_key() {  # -> 0 when the last gpg_valid_sig failed for want of the key
  # NO_PUBKEY is "the key is not in the keyring"; ERRSIG is gpg's more general
  # "could not check this signature", which is what it prints for an unknown
  # key when it cannot say more. Anything else - a bad signature above all - is
  # not a missing key and must not lead to a retry.
  grep -Eq '^\[GNUPG:\] (NO_PUBKEY|ERRSIG) ' <<<"$GPG_STATUS"
}

fetch_sha256() {  # $1 = url, $2 = file to write -> 0 fetched, 1 not published; dies otherwise
  # Deliberately no -f: without it curl reports the status code instead of one
  # generic failure, and only a 404 means "this release has no .sha256". A DNS
  # failure, a TLS error, a timeout, or a 500 must stop the upgrade rather than
  # pass for "not published" and quietly leave the checksum unverified.
  local code body
  code=$(curl -sSL -o "$2" -w '%{http_code}' "$1") \
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

fetch_and_verify() {  # $1 = repo, $2 = asset filename, $3 = version  -> path
  local base="$1/releases/download/v$3" f="$2"
  log "Downloading $f"
  curl -fL --progress-bar -o "$WORKDIR/$f"     "$base/$f"
  curl -fsSL            -o "$WORKDIR/$f.asc" "$base/$f.asc"

  log "Verifying GPG signature"
  if ! gpg_valid_sig "$WORKDIR/$f.asc" "$WORKDIR/$f"; then
    # A signature this keyring cannot check at all is the one case worth
    # retrying: Forgejo signs each release with a subkey of the pinned primary
    # key, and a subkey issued since the key was imported is not in the keyring
    # yet. Anything else - a bad signature, a signature by another key - stops
    # the upgrade here.
    gpg_missing_key \
      || die "signature on $f is not from $RELEASE_KEY. Expected gpg to report a VALIDSIG line ending in that fingerprint, the Forgejo release key published at https://forgejo.org/download/; it did not. Do not install this file: it is not signed by the key this script trusts"
    log "signature is by a key not in the keyring; refreshing the pinned key $RELEASE_KEY from $KEYSERVER (the same fingerprint, nothing else)"
    # Only the pinned fingerprint is ever fetched, so the trust root does not
    # move: this can add a new subkey of the key already trusted, and nothing
    # else.
    gpg --keyserver "$KEYSERVER" --recv "$RELEASE_KEY" \
      || die "could not refresh the key $RELEASE_KEY from $KEYSERVER; the signature on $f cannot be checked, so the download is not trusted and nothing was installed. Check this host's network access to the keyserver, or import the key by hand from https://forgejo.org/download/, then rerun"
    gpg_valid_sig "$WORKDIR/$f.asc" "$WORKDIR/$f" \
      || die "signature on $f is not from $RELEASE_KEY. The pinned key was refreshed from $KEYSERVER and the signature still does not verify against it, so this release is signed by something other than the Forgejo release key. Do not install it; check the fingerprint published at https://forgejo.org/download/ and report the mismatch"
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

  chmod 755 "$WORKDIR/$f"
  echo "$WORKDIR/$f"
}

install_binary() {  # $1 = new file, $2 = destination
  # Both callers refuse to run when nothing is installed, so the destination
  # always exists and there is always a previous binary worth keeping.
  log "Keeping previous binary at $2.prev"
  cp -p "$2" "$2.prev"
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
  install -m "$(stat -c %a "$2")" -o "$(stat -c %u "$2")" -g "$(stat -c %g "$2")" "$1" "$2"
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

ini_get() {  # $1 = file, $2 = section ("" for the keys before the first one), $3 = key
  # Reads one value out of an ini file with sed, so the script still needs
  # nothing an operator would have to install. Good enough for the handful of
  # [server] keys the health check needs, not a general ini parser.
  local file=$1 section=$2 key=$3 raw
  [[ -r $file ]] || return 0
  if [[ -n $section ]]; then
    # The range runs from the section header to the next one; sed starts
    # looking for the end pattern on the line after the start, so the header
    # itself does not close the range.
    raw=$(sed -n "/^[[:space:]]*\[[[:space:]]*${section}[[:space:]]*\]/I,/^[[:space:]]*\[/ \
                  s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//Ip" "$file")
  else
    raw=$(sed -n "/^[[:space:]]*\[/q; s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//Ip" "$file")
  fi
  raw=${raw%%$'\n'*}   # first match wins, as it does for Forgejo itself
  [[ -n $raw ]] || return 0
  # Drop a trailing " ; comment" or " # comment", then trailing spaces and any
  # surrounding quotes.
  printf '%s\n' "$raw" \
    | sed -e 's/[[:space:]][;#].*$//' -e 's/[[:space:]]*$//' \
          -e 's/^"\(.*\)"$/\1/' -e "s/^'\\(.*\\)'\$/\\1/"
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
    if [[ $quiet -eq 0 ]]; then
      warn "systemd does not know a unit called $unit, so the values below are defaults rather than what this host runs. Set FORGEJO_SERVICE to the unit that runs Forgejo."
    fi
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
  else
    FORGEJO_BIN=/usr/local/bin/forgejo
    FORGEJO_BIN_SRC=$dsrc
  fi

  if [[ -n $FORGEJO_USER ]]; then
    FORGEJO_USER_SRC="env"
  elif [[ -n $user_prop ]]; then
    FORGEJO_USER=$user_prop
    FORGEJO_USER_SRC="unit User"
  else
    FORGEJO_USER=git
    FORGEJO_USER_SRC=$dsrc
  fi

  # The work path is settled before the config, because Forgejo's own default
  # config path sits under the work path. Forgejo's own order
  # (modules/setting/path.go, InitWorkPathAndCfgProvider) is: FORGEJO_WORK_DIR
  # in the environment (GITEA_WORK_DIR on older installs), then --work-path,
  # else the directory holding the binary. Then, once the config file has been
  # read, WORK_PATH in app.ini replaces whatever those gave - which is why the
  # block further down, after the config path is known, can still change the
  # answer. The unit's WorkingDirectory= is never one of Forgejo's sources;
  # systemd only uses it to pick the directory the process starts in, so this
  # script does not read a work path out of it either.
  if [[ -n $FORGEJO_WORK_PATH ]]; then
    FORGEJO_WORK_PATH_SRC="env"
    require_abs FORGEJO_WORK_PATH "$FORGEJO_WORK_PATH" "$tolerant"
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
      else
        wp=$(argv_opt --work-path -w -- ${argv[@]+"${argv[@]}"})
        if [[ -n $wp ]]; then
          FORGEJO_WORK_PATH=$wp
          FORGEJO_WORK_PATH_SRC="unit ExecStart --work-path"
        fi
      fi
    fi
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
  # has been found and it replaces the value the environment or --work-path
  # gave, so it replaces the one found above too. The operator's own
  # FORGEJO_WORK_PATH is the one thing it does not override; an env var set on
  # the command line wins over every source in this script.
  if [[ $FORGEJO_WORK_PATH_SRC != env ]]; then
    wp=$(trim_slash "$(ini_get "$FORGEJO_CONFIG" "" WORK_PATH)")
    if [[ -n $wp ]]; then
      if [[ -n $FORGEJO_WORK_PATH && $wp != "$FORGEJO_WORK_PATH" ]]; then
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
    if [[ $quiet -eq 0 ]]; then
      warn "systemd does not know a unit called $unit, so the values below are defaults rather than what this host runs. Set RUNNER_SERVICE to the unit that runs forgejo-runner."
    fi
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
  else
    RUNNER_BIN=/usr/local/bin/forgejo-runner
    RUNNER_BIN_SRC=$dsrc
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
    fi
    if [[ -n $RUNNER_CONFIG && ! -r $RUNNER_CONFIG ]]; then
      warn "cannot read the runner config at $RUNNER_CONFIG (from: $RUNNER_CONFIG_SRC), so the registration file below is a guess. Set RUNNER_CONFIG if the daemon uses another file."
    fi
  fi
  if [[ $quiet -eq 0 ]]; then
    log "forgejo-runner settings for $unit (override any with the env var):"
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
  local -a cmd
  cmd=(env ${FORGEJO_ENV[@]+"${FORGEJO_ENV[@]}"} "$FORGEJO_BIN" --config "$FORGEJO_CONFIG")
  if [[ -n $FORGEJO_WORK_PATH ]]; then
    cmd+=(--work-path "$FORGEJO_WORK_PATH")
  fi
  cmd+=("$@")
  ( cd "${FORGEJO_WORK_PATH:-/}" && run_as "$FORGEJO_USER" "${cmd[@]}" )
}

# --- health checks -----------------------------------------------------------

healthz() {  # $1 = seconds to allow this one attempt (default 5) -> 0 when the server answers
  # Connection refused is expected while the service is still starting, so only
  # the exit status is used and curl's own message is dropped.
  local -a opts=(-fs --max-time "${1:-5}")
  if [[ -n $FORGEJO_SOCKET ]]; then
    opts+=(--unix-socket "$FORGEJO_SOCKET")
  fi
  curl "${opts[@]}" "$FORGEJO_URL/api/healthz" >/dev/null 2>&1
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
    # There is no way to confirm without a terminal: passing an exact version
    # still lands here, because it is the change of major version that needs
    # a decision, not how the version was chosen.
    [[ -t 0 ]] || die "major version change ${cur%%.*} -> ${want%%.*} needs confirmation and stdin is not a terminal; run this from a terminal so the prompt can be answered"
    read -r -p "Continue? [y/N] " a; [[ $a == [yY] ]] || exit 1
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
      || warn "flush-queues failed, continuing"
  else
    warn "$FORGEJO_SERVICE is not running, so there are no queues to flush and no way to health check it before the upgrade"
  fi

  if [[ $SKIP_BACKUP != 1 ]]; then
    # Make the backup directory now rather than after the stop: creating it is
    # the same work either way, and a failure here costs no downtime.
    # The group is the account's primary group, not a group named after the
    # account: a service user called forgejo may well belong to group git.
    install -d -o "$FORGEJO_USER" -g "$(id -gn "$FORGEJO_USER")" -m 750 "$BACKUP_DIR"
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

  # SIGTERM lets the runner finish in-flight jobs. The stock unit sets
  # TimeoutStopSec=infinity, so the wait is unbounded unless a drop-in sets a finite value.
  log "Stopping $RUNNER_SERVICE (waits for running jobs)"
  # Set before the stop, not after: the wait for jobs is unbounded, and a
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
  local bin svc kind repo restore parse nostart=0 reason="" prev="" cur="" out
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
             restore="If the version you are undoing changed the database schema, restore the dump from $BACKUP_DIR as well, before starting the service" ;;
    runner)  resolve_runner_settings --rollback
             bin=$RUNNER_BIN;  svc=$RUNNER_SERVICE;  kind=runner
             repo=$RUNNER_REPO; parse=parse_runner_version
             restore="There is no dump to restore for the runner, and its registration in $RUNNER_REG_FILE survives a binary swap" ;;
    *) die "rollback forgejo|runner [--no-start]" ;;
  esac
  [[ -x $bin.prev ]] \
    || die "no previous binary at $bin.prev to roll back to, so nothing was changed and $svc was left exactly as it was. This script keeps the binary it replaced at that path only until the next upgrade overwrites it, so there is nothing older to go back to here. To go back by hand: download the release you want from $repo/releases, check its signature, and install it over $bin. $restore"

  # Read both versions before anything is stopped. The previous binary is the
  # one that will be running afterwards, so it has to run at all to be worth
  # putting back, and what it reports decides whether starting it is safe.
  out=$("$bin.prev" --version 2>&1) \
    || die "$bin.prev does not run (exit $?): '${out%%$'\n'*}'. The binary this rollback would put back has to run to be worth restoring, so nothing was changed and $svc was left exactly as it was. Download the release you want from $repo/releases, check its signature, and install it over $bin by hand. $restore"
  prev=$("$parse" "$out")
  # The installed binary, by contrast, is the one a rollback exists to undo: it
  # may be half-written or the wrong architecture. A failure here is expected
  # and leaves the version unknown rather than stopping the rollback.
  if [[ -x $bin ]]; then
    if out=$("$bin" --version 2>&1); then cur=$("$parse" "$out"); fi
  fi
  log "Rolling back $bin from ${cur:-unknown} to ${prev:-unknown}"

  if [[ $nostart -eq 0 ]] && rollback_needs_manual_start "$kind" "$cur" "$prev"; then
    nostart=1
    reason="going from $cur back to ${prev:-an unreadable version} crosses a major version, and Forgejo refuses to start an older release on a database a newer one has already migrated - it would log that the database is for a newer Forgejo and exit at once"
    if [[ -z $prev ]]; then
      reason="$reason (the previous binary's version could not be read, so it is treated as a different major version)"
    fi
  fi

  # Tracked before the stop for the same reason as in the upgrades.
  STOPPED_SVC="$svc"
  STOPPED_KIND="$kind"
  STOPPED_BIN="$bin"
  systemctl stop "$svc"
  mv -f "$bin.prev" "$bin"
  # 2, not 1: the move consumed the .prev file, so if this rollback fails there
  # is no older binary left and on_exit must not suggest rolling back again.
  BINARY_REPLACED=2

  if [[ $nostart -eq 1 ]]; then
    # This service is stopped on purpose and the lines below are the saying so,
    # which is what the tracking exists to make sure of; clearing it here keeps
    # on_exit from repeating it as a failure.
    STOPPED_SVC=""
    log "The previous binary is back in place at $bin, but $svc was left stopped on purpose: $reason"
    if [[ $kind == forgejo ]]; then
      log "Next: restore the newest dump in $BACKUP_DIR (see https://forgejo.org/docs/latest/admin/upgrade/#backup-and-restore), then: systemctl start $svc"
    else
      log "Next: start it with: systemctl start $svc"
    fi
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
  f=$(installed_forgejo)
  r=$(installed_runner)
  # Captured before printing: inside a printf argument list, "$(...)" failing
  # would not fail the printf itself, so a dead API would silently print
  # blank "latest" columns and exit 0 instead of stopping here.
  fl=$(latest_tag "$FORGEJO_REPO") \
    || die "could not fetch the latest Forgejo release from the code.forgejo.org API; check that this host can reach https://code.forgejo.org, then rerun"
  [[ -n $fl ]] \
    || die "the code.forgejo.org API answered but gave no Forgejo release tag; expected a tag_name in the response. Check https://code.forgejo.org/forgejo/forgejo/releases and rerun"
  rl=$(latest_tag "$RUNNER_REPO") \
    || die "could not fetch the latest forgejo-runner release from the code.forgejo.org API; check that this host can reach https://code.forgejo.org, then rerun"
  [[ -n $rl ]] \
    || die "the code.forgejo.org API answered but gave no forgejo-runner release tag; expected a tag_name in the response. Check https://code.forgejo.org/forgejo/runner/releases and rerun"
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
  # means moving the end of this range.
  *) sed -n '2,34p' "$0"; exit 1 ;;
esac
