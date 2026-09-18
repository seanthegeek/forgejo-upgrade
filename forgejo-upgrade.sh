#!/usr/bin/env bash
#
# forgejo-upgrade.sh - upgrade binary installs of Forgejo and forgejo-runner
#
# Usage:
#   forgejo-upgrade.sh check                  show installed vs latest for both
#   forgejo-upgrade.sh settings               show the settings read from the unit and app.ini
#   forgejo-upgrade.sh forgejo <ver|latest>   upgrade the Forgejo server
#   forgejo-upgrade.sh runner  <ver|latest>   upgrade forgejo-runner
#   forgejo-upgrade.sh rollback forgejo|runner   restore the previous binary
#
# Overrides (each is read from the systemd unit or app.ini when unset):
#   FORGEJO_SERVICE    forgejo
#   FORGEJO_BIN        /usr/local/bin/forgejo
#   FORGEJO_USER       git
#   FORGEJO_CONFIG     /etc/forgejo/app.ini
#   FORGEJO_WORK_PATH  unset; Forgejo then uses the directory holding the binary
#   FORGEJO_URL        http://127.0.0.1:3000   (used for the health check)
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
# Only used when Forgejo listens on a unix socket; normally derived from
# app.ini, where HTTP_ADDR holds the socket path when PROTOCOL is http+unix.
FORGEJO_SOCKET=${FORGEJO_SOCKET:-}
# The unit's Environment= settings, passed to the binary when the script runs
# it as FORGEJO_USER. Filled in by resolve_forgejo_settings.
FORGEJO_ENV=()
BACKUP_DIR=${BACKUP_DIR:-/var/backups/forgejo}
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
FORGEJO_BIN_SRC=""; FORGEJO_USER_SRC=""; FORGEJO_CONFIG_SRC=""
FORGEJO_WORK_PATH_SRC=""; FORGEJO_URL_SRC=""
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

# STOPPED_SVC is set once a service has been stopped and cleared again once it
# is healthy. If the script exits anywhere in between - including an error that
# "set -e" turns into an exit, or a Ctrl-C - on_exit runs and tells the operator
# that the service is down, what the journal says, and how to get it running.
STOPPED_SVC=""   # systemd unit currently stopped by this script, "" when none
STOPPED_KIND=""  # "forgejo" or "runner", i.e. the argument to `rollback`
STOPPED_BIN=""   # path of the binary for that service
BINARY_REPLACED=0  # 0 = binary untouched, 1 = new binary in place, 2 = rolled back

on_exit() {
  local rc=$?
  if [[ -n $STOPPED_SVC ]]; then
    warn "did not finish; $STOPPED_SVC is probably still stopped. Last 40 journal lines:"
    journalctl -u "$STOPPED_SVC" -n 40 --no-pager >&2 \
      || warn "could not read the journal; try it by hand: journalctl -u $STOPPED_SVC -n 40"
    case $BINARY_REPLACED in
      1) warn "the new binary is installed and the previous one is kept at $STOPPED_BIN.prev"
         warn "try: systemctl start $STOPPED_SVC"
         warn "if that fails, put the previous binary back with: $0 rollback $STOPPED_KIND" ;;
      # 2 means a rollback already moved the previous binary back over the new
      # one, so no .prev file is left and rolling back again is not possible.
      2) warn "the previous binary is back in place at $STOPPED_BIN and no $STOPPED_BIN.prev remains"
         warn "read the journal above, then start the service with: systemctl start $STOPPED_SVC" ;;
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

installed_forgejo() {
  [[ -x $FORGEJO_BIN ]] || { echo none; return; }
  local out ver
  out=$("$FORGEJO_BIN" --version 2>&1) \
    || die "$FORGEJO_BIN --version failed (exit $?): '${out%%$'\n'*}'. The binary may be corrupt or built for another architecture; reinstall it, or set FORGEJO_BIN to the binary you want upgraded"
  # binary prints "forgejo version 16.0.4+gitea-1.22.0 (release name 16.0.4) ..."
  ver=$(sed -n 's/^[Ff]orgejo version \([0-9][0-9.]*\).*/\1/p' <<<"$out")
  [[ -n $ver ]] || die "could not read a version from '$FORGEJO_BIN --version'. Expected a line like 'forgejo version 16.0.4', got: '${out%%$'\n'*}'"
  echo "$ver"
}

installed_runner() {
  [[ -x $RUNNER_BIN ]] || { echo none; return; }
  local out ver
  out=$("$RUNNER_BIN" --version 2>&1) \
    || die "$RUNNER_BIN --version failed (exit $?): '${out%%$'\n'*}'. The binary may be corrupt or built for another architecture; reinstall it, or set RUNNER_BIN to the binary you want upgraded"
  # binary prints "forgejo-runner version v13.1.0"
  ver=$(sed -n 's/.*version v\{0,1\}\([0-9][0-9.]*\).*/\1/p' <<<"$out")
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

fetch_and_verify() {  # $1 = repo, $2 = asset filename, $3 = version  -> path
  local base="$1/releases/download/v$3" f="$2"
  log "Downloading $f"
  curl -fL --progress-bar -o "$WORKDIR/$f"     "$base/$f"
  curl -fsSL            -o "$WORKDIR/$f.asc" "$base/$f.asc"

  # Releases are signed by a rotating subkey; the primary key fingerprint is
  # the last field of gpg's VALIDSIG status line.
  log "Verifying GPG signature"
  gpg --status-fd 1 --verify "$WORKDIR/$f.asc" "$WORKDIR/$f" 2>/dev/null \
    | grep -Eq "^\[GNUPG:\] VALIDSIG .* $RELEASE_KEY$" \
    || die "signature on $f is not from $RELEASE_KEY"

  if curl -fsSL -o "$WORKDIR/$f.sha256" "$base/$f.sha256" 2>/dev/null; then
    log "Verifying sha256"
    (cd "$WORKDIR" && sha256sum -c --quiet "$f.sha256") || die "sha256 mismatch for $f"
  else
    warn "no .sha256 published for $f; relying on GPG signature only"
  fi

  chmod 755 "$WORKDIR/$f"
  echo "$WORKDIR/$f"
}

install_binary() {  # $1 = new file, $2 = destination
  # Both callers refuse to run when nothing is installed, so the destination
  # always exists and there is always a previous binary worth keeping.
  log "Keeping previous binary at $2.prev"
  cp -p "$2" "$2.prev"
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
      # With http+unix, HTTP_ADDR is the socket path and the host name in the
      # URL is ignored; curl dials the socket instead.
      if [[ -z $addr ]]; then
        local msg="PROTOCOL is http+unix in $FORGEJO_CONFIG but HTTP_ADDR does not give a socket path, so the health check has nowhere to connect. Set FORGEJO_SOCKET to the socket file and FORGEJO_URL to http://unix"
        if [[ $tolerant -eq 0 ]]; then die "$msg"; elif [[ $quiet -eq 0 ]]; then warn "$msg"; fi
      fi
      FORGEJO_SOCKET=$addr
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

resolve_forgejo_settings() {  # --tolerant: never die, --quiet: do not print the block
  local tolerant=0 quiet=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tolerant) tolerant=1 ;;
      --quiet)    quiet=1 ;;
      *) die "resolve_forgejo_settings: unknown option $1 (this is a bug in the script)" ;;
    esac
    shift
  done

  local unit loaded=0 dsrc=default
  local exec_path="" argv_line="" user_prop="" workdir_prop="" env_line=""
  local wp="" cfg=""
  local -a argv=()

  if [[ -z $FORGEJO_SERVICE ]]; then FORGEJO_SERVICE=forgejo; fi
  unit=$(unit_name "$FORGEJO_SERVICE")

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
    workdir_prop=${workdir_prop%/}
    # Split on spaces the way a shell would. systemd quotes a value containing
    # spaces, and such a value would be split here too, which is why only
    # whole words - option names and paths - are read back out.
    read -r -a argv <<<"$argv_line"
    read -r -a FORGEJO_ENV <<<"$env_line"
  fi

  if [[ -n $FORGEJO_BIN ]]; then
    FORGEJO_BIN_SRC="env"
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
  # config path sits under it. Forgejo reads the work path from FORGEJO_WORK_DIR
  # (GITEA_WORK_DIR on older installs), then --work-path, and the unit's
  # WorkingDirectory is what the daemon actually runs in.
  if [[ -n $FORGEJO_WORK_PATH ]]; then
    FORGEJO_WORK_PATH_SRC="env"
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
        elif [[ -n $workdir_prop ]]; then
          FORGEJO_WORK_PATH=$workdir_prop
          FORGEJO_WORK_PATH_SRC="unit WorkingDirectory"
        fi
      fi
    fi
  fi

  if [[ -n $FORGEJO_CONFIG ]]; then
    FORGEJO_CONFIG_SRC="env"
  else
    cfg=$(argv_opt --config -c -- ${argv[@]+"${argv[@]}"})
    if [[ -n $cfg ]]; then
      FORGEJO_CONFIG=$cfg
      FORGEJO_CONFIG_SRC="unit ExecStart --config"
    elif [[ -n $FORGEJO_WORK_PATH && -f $FORGEJO_WORK_PATH/custom/conf/app.ini ]]; then
      # Forgejo's own default when no --config is given.
      FORGEJO_CONFIG=$FORGEJO_WORK_PATH/custom/conf/app.ini
      FORGEJO_CONFIG_SRC="Forgejo default under the work path"
    else
      FORGEJO_CONFIG=/etc/forgejo/app.ini
      FORGEJO_CONFIG_SRC=$dsrc
    fi
  fi

  # Last place to look for a work path: app.ini can set WORK_PATH, and it sits
  # in the keys before the first [section].
  if [[ -z $FORGEJO_WORK_PATH ]]; then
    wp=$(ini_get "$FORGEJO_CONFIG" "" WORK_PATH)
    if [[ -n $wp ]]; then
      FORGEJO_WORK_PATH=$wp
      FORGEJO_WORK_PATH_SRC="app.ini WORK_PATH"
    else
      FORGEJO_WORK_PATH_SRC="not set"
    fi
  fi
  FORGEJO_WORK_PATH=${FORGEJO_WORK_PATH%/}

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
    [[ -x $FORGEJO_BIN ]] \
      || die "no executable at $FORGEJO_BIN (from: $FORGEJO_BIN_SRC). This script upgrades an existing install; install Forgejo first (https://forgejo.org/docs/latest/admin/installation/binary/), or set FORGEJO_BIN to where it lives"
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
    setting_line FORGEJO_BIN       "$FORGEJO_BIN"                  "$FORGEJO_BIN_SRC"
    setting_line FORGEJO_USER      "$FORGEJO_USER"                 "$FORGEJO_USER_SRC"
    setting_line FORGEJO_CONFIG    "$FORGEJO_CONFIG"               "$FORGEJO_CONFIG_SRC"
    setting_line FORGEJO_WORK_PATH "${FORGEJO_WORK_PATH:-(none)}"  "$FORGEJO_WORK_PATH_SRC"
    setting_line FORGEJO_URL       "${FORGEJO_URL:-(none)}"        "$FORGEJO_URL_SRC"
    if [[ -n $FORGEJO_SOCKET ]]; then
      setting_line FORGEJO_SOCKET  "$FORGEJO_SOCKET"               "app.ini [server] HTTP_ADDR"
    fi
  fi

  # Said after the block, so the operator reads what was found first.
  if [[ -z $FORGEJO_WORK_PATH && $quiet -eq 0 ]]; then
    warn "no work path found in the unit or in $FORGEJO_CONFIG; Forgejo will fall back to the directory holding $FORGEJO_BIN. If that is not where its data lives, set FORGEJO_WORK_PATH."
  fi
}

resolve_runner_settings() {  # --tolerant: never die, --quiet: do not print the block
  local tolerant=0 quiet=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tolerant) tolerant=1 ;;
      --quiet)    quiet=1 ;;
      *) die "resolve_runner_settings: unknown option $1 (this is a bug in the script)" ;;
    esac
    shift
  done

  local unit loaded=0 dsrc=default
  local exec_path="" argv_line="" workdir_prop="" cfg="" regfile=""
  local -a argv=()

  if [[ -z $RUNNER_SERVICE ]]; then RUNNER_SERVICE=forgejo-runner; fi
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
    workdir_prop=${workdir_prop%/}
    read -r -a argv <<<"$argv_line"
  fi

  if [[ -n $RUNNER_BIN ]]; then
    RUNNER_BIN_SRC="env"
  elif [[ -n $exec_path ]]; then
    RUNNER_BIN=$exec_path
    RUNNER_BIN_SRC="unit ExecStart"
  else
    RUNNER_BIN=/usr/local/bin/forgejo-runner
    RUNNER_BIN_SRC=$dsrc
  fi

  if [[ -n $RUNNER_HOME ]]; then
    RUNNER_HOME_SRC="env"
  elif [[ -n $workdir_prop ]]; then
    RUNNER_HOME=$workdir_prop
    RUNNER_HOME_SRC="unit WorkingDirectory"
  else
    RUNNER_HOME=/home/runner
    RUNNER_HOME_SRC=$dsrc
  fi
  RUNNER_HOME=${RUNNER_HOME%/}

  if [[ -n $RUNNER_CONFIG ]]; then
    RUNNER_CONFIG_SRC="env"
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
  if [[ -n $RUNNER_CONFIG && $RUNNER_CONFIG != /* ]]; then
    RUNNER_CONFIG=$RUNNER_HOME/$RUNNER_CONFIG
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
    RUNNER_REG_FILE=$RUNNER_HOME/$regfile
  fi

  if [[ $tolerant -eq 0 ]]; then
    [[ -x $RUNNER_BIN ]] \
      || die "no executable at $RUNNER_BIN (from: $RUNNER_BIN_SRC). This script upgrades an existing install; install forgejo-runner first (https://forgejo.org/docs/latest/admin/actions/installation/binary/), or set RUNNER_BIN to where it lives"
    if [[ -n $RUNNER_CONFIG && ! -r $RUNNER_CONFIG ]]; then
      warn "cannot read the runner config at $RUNNER_CONFIG (from: $RUNNER_CONFIG_SRC), so the registration file below is a guess. Set RUNNER_CONFIG if the daemon uses another file."
    fi
  fi
  if [[ $quiet -eq 0 ]]; then
    log "forgejo-runner settings for $unit (override any with the env var):"
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
  # dump --file Y", not "forgejo dump --config X". The cd matters too: with no
  # work path Forgejo falls back to the directory it was started in, and the
  # current directory may be one FORGEJO_USER cannot even enter.
  local -a cmd
  cmd=(env ${FORGEJO_ENV[@]+"${FORGEJO_ENV[@]}"} "$FORGEJO_BIN" --config "$FORGEJO_CONFIG")
  if [[ -n $FORGEJO_WORK_PATH ]]; then
    cmd+=(--work-path "$FORGEJO_WORK_PATH")
  fi
  cmd+=("$@")
  ( cd "${FORGEJO_WORK_PATH:-/}" && run_as "$FORGEJO_USER" "${cmd[@]}" )
}

# --- health checks -----------------------------------------------------------

healthz() {  # one attempt -> 0 when the server answers
  # Connection refused is expected while the service is still starting, so only
  # the exit status is used and curl's own message is dropped.
  local -a opts=(-fs --max-time 5)
  if [[ -n $FORGEJO_SOCKET ]]; then
    opts+=(--unix-socket "$FORGEJO_SOCKET")
  fi
  curl "${opts[@]}" "$FORGEJO_URL/api/healthz" >/dev/null 2>&1
}

wait_forgejo_healthy() {
  log "Waiting for $FORGEJO_URL/api/healthz"
  local i
  for i in $(seq 1 60); do
    if healthz; then
      log "Service answered on attempt $i"
      return 0
    fi
    sleep 1
  done
  die "service did not answer $FORGEJO_URL/api/healthz within 60s"
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
  local want cur new
  want=$(resolve_version "$1" "$FORGEJO_REPO") || die "could not resolve version"
  [[ -n $want ]] || die "could not determine Forgejo version"
  cur=$(installed_forgejo)
  log "Forgejo: installed $cur, target $want"
  [[ $cur != "$want" ]] || { log "already on $want, nothing to do"; return; }

  if [[ ${cur%%.*} != "${want%%.*}" ]]; then
    warn "major version change ${cur%%.*} -> ${want%%.*}: read the release notes first:"
    warn "  $FORGEJO_REPO/src/branch/forgejo/release-notes-published/$want.md"
    [[ -t 0 ]] || die "major version change ${cur%%.*} -> ${want%%.*} needs confirmation; run this from a terminal, or pass the exact version you want on the command line"
    read -r -p "Continue? [y/N] " a; [[ $a == [yY] ]] || exit 1
  fi

  ensure_key
  new=$(fetch_and_verify "$FORGEJO_REPO" "forgejo-$want-linux-$(arch)" "$want")
  "$new" --version | grep -q "^[Ff]orgejo version $want" \
    || die "downloaded binary does not report version $want"

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
    install -d -o "$FORGEJO_USER" -g "$FORGEJO_USER" -m 750 "$BACKUP_DIR"
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
  systemctl stop "$FORGEJO_SERVICE"
  # From here until the health check passes, any exit is reported by on_exit.
  STOPPED_SVC="$FORGEJO_SERVICE"
  STOPPED_KIND=forgejo
  STOPPED_BIN="$FORGEJO_BIN"

  if [[ $SKIP_BACKUP != 1 ]]; then
    local dump
    dump="$BACKUP_DIR/forgejo-$cur-$(date +%Y%m%d-%H%M%S).zip"
    log "Backing up to $dump"
    as_forgejo dump --file "$dump"
  else
    warn "SKIP_BACKUP=1, no dump taken"
  fi

  install_binary "$new" "$FORGEJO_BIN"
  BINARY_REPLACED=1

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
  local want cur new
  want=$(resolve_version "$1" "$RUNNER_REPO") || die "could not resolve version"
  [[ -n $want ]] || die "could not determine runner version"
  cur=$(installed_runner)
  log "forgejo-runner: installed $cur, target $want"
  [[ $cur != "$want" ]] || { log "already on $want, nothing to do"; return; }

  ensure_key
  new=$(fetch_and_verify "$RUNNER_REPO" "forgejo-runner-$want-linux-$(arch)" "$want")
  "$new" --version | grep -q "$want" \
    || die "downloaded binary does not report version $want"

  # SIGTERM lets the runner finish in-flight jobs. The stock unit sets
  # TimeoutStopSec=infinity, so the wait is unbounded unless a drop-in sets a finite value.
  log "Stopping $RUNNER_SERVICE (waits for running jobs)"
  systemctl stop "$RUNNER_SERVICE"
  # From here until the runner is active again, any exit is reported by on_exit.
  STOPPED_SVC="$RUNNER_SERVICE"
  STOPPED_KIND=runner
  STOPPED_BIN="$RUNNER_BIN"

  install_binary "$new" "$RUNNER_BIN"
  BINARY_REPLACED=1

  log "Starting $RUNNER_SERVICE"
  systemctl start "$RUNNER_SERVICE"

  wait_runner_active
  # Running again, so on_exit has nothing to report from here on.
  STOPPED_SVC=""

  log "forgejo-runner now: $("$RUNNER_BIN" --version)"
  log "Confirm it shows online under Site Administration > Actions > Runners"
}

# --- rollback / check --------------------------------------------------------

rollback() {
  need_root
  local bin svc kind
  # Same reading of the unit and config as an upgrade does, so a rollback puts
  # the binary back where this host really keeps it.
  case "$1" in
    forgejo) resolve_forgejo_settings
             bin=$FORGEJO_BIN; svc=$FORGEJO_SERVICE; kind=forgejo ;;
    runner)  resolve_runner_settings
             bin=$RUNNER_BIN;  svc=$RUNNER_SERVICE;  kind=runner  ;;
    *) die "rollback forgejo|runner" ;;
  esac
  [[ -x $bin.prev ]] || die "no $bin.prev to roll back to"
  log "Rolling back $bin to $("$bin.prev" --version)"
  systemctl stop "$svc"
  STOPPED_SVC="$svc"
  STOPPED_KIND="$kind"
  STOPPED_BIN="$bin"
  mv -f "$bin.prev" "$bin"
  # 2, not 1: the move consumed the .prev file, so if this rollback fails there
  # is no older binary left and on_exit must not suggest rolling back again.
  BINARY_REPLACED=2
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
  local f r
  # Tolerant and quiet: check only reports versions, and it is the one command
  # that is expected to work on a half-installed host.
  resolve_forgejo_settings --tolerant --quiet
  resolve_runner_settings --tolerant --quiet
  f=$(installed_forgejo)
  r=$(installed_runner)
  printf '%-16s %-12s %-12s\n' component installed latest
  printf '%-16s %-12s %-12s\n' forgejo "$f" "$(latest_tag "$FORGEJO_REPO")"
  printf '%-16s %-12s %-12s\n' forgejo-runner "$r" "$(latest_tag "$RUNNER_REPO")"
  echo
  echo "Security announcements: https://codeberg.org/forgejo/security-announcements/issues"
}

# --- main --------------------------------------------------------------------

case "${1:-}" in
  check)    check ;;
  settings) settings ;;
  forgejo)  upgrade_forgejo "${2:?usage: $0 forgejo <version|latest>}" ;;
  runner)   upgrade_runner  "${2:?usage: $0 runner <version|latest>}" ;;
  rollback) rollback "${2:-}" ;;
  # The usage text is this script's own header comment. Adding a line to it
  # means moving the end of this range.
  *) sed -n '2,33p' "$0"; exit 1 ;;
esac
