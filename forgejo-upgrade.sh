#!/usr/bin/env bash
#
# forgejo-upgrade.sh - upgrade binary installs of Forgejo and forgejo-runner
#
# Usage:
#   forgejo-upgrade.sh check                  show installed vs latest for both
#   forgejo-upgrade.sh forgejo <ver|latest>   upgrade the Forgejo server
#   forgejo-upgrade.sh runner  <ver|latest>   upgrade forgejo-runner
#   forgejo-upgrade.sh rollback forgejo|runner   restore the previous binary
#
# Environment overrides (defaults match the Forgejo docs layout):
#   FORGEJO_BIN      /usr/local/bin/forgejo
#   FORGEJO_USER     git
#   FORGEJO_SERVICE  forgejo
#   FORGEJO_CONFIG   /etc/forgejo/app.ini
#   FORGEJO_URL      http://127.0.0.1:3000     (used for the post-start health check)
#   BACKUP_DIR       /var/backups/forgejo     (must be writable by FORGEJO_USER)
#   SKIP_BACKUP      set to 1 to skip `forgejo dump`
#   RUNNER_BIN       /usr/local/bin/forgejo-runner
#   RUNNER_USER      runner
#   RUNNER_SERVICE   forgejo-runner
#   RUNNER_HOME      /home/runner              (directory holding the .runner registration file)
#
# Both binaries are signed with the Forgejo release key. The fingerprint below
# is from https://forgejo.org/download/ - it is verified on every run.
# Note: "latest" returns the newest tag across all lines; on the v15 LTS line
# pass an explicit version.

set -euo pipefail

FORGEJO_BIN=${FORGEJO_BIN:-/usr/local/bin/forgejo}
FORGEJO_USER=${FORGEJO_USER:-git}
FORGEJO_SERVICE=${FORGEJO_SERVICE:-forgejo}
FORGEJO_CONFIG=${FORGEJO_CONFIG:-/etc/forgejo/app.ini}
FORGEJO_URL=${FORGEJO_URL:-http://127.0.0.1:3000}
BACKUP_DIR=${BACKUP_DIR:-/var/backups/forgejo}
SKIP_BACKUP=${SKIP_BACKUP:-0}

RUNNER_BIN=${RUNNER_BIN:-/usr/local/bin/forgejo-runner}
RUNNER_USER=${RUNNER_USER:-runner}
RUNNER_SERVICE=${RUNNER_SERVICE:-forgejo-runner}
RUNNER_HOME=${RUNNER_HOME:-/home/runner}

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
  install -m 755 -o root -g root "$1" "$2"
}

# --- health checks -----------------------------------------------------------

wait_forgejo_healthy() {
  log "Waiting for $FORGEJO_URL/api/healthz"
  local i
  for i in $(seq 1 60); do
    # Connection refused is expected while the service is still starting.
    if curl -fs --max-time 5 "$FORGEJO_URL/api/healthz" >/dev/null 2>&1; then
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
  local want cur new
  want=$(resolve_version "$1" "$FORGEJO_REPO") || die "could not resolve version"
  [[ -n $want ]] || die "could not determine Forgejo version"
  cur=$(installed_forgejo)
  [[ $cur != none ]] || die "no executable at $FORGEJO_BIN. This script upgrades an existing install; install Forgejo first (https://forgejo.org/docs/latest/admin/installation/binary/), or set FORGEJO_BIN to where it lives"
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

  log "Flushing queues"
  sudo -u "$FORGEJO_USER" "$FORGEJO_BIN" manager flush-queues --config "$FORGEJO_CONFIG" --timeout 2m \
    || warn "flush-queues failed (service not running?), continuing"

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
    install -d -o "$FORGEJO_USER" -g "$FORGEJO_USER" -m 750 "$BACKUP_DIR"
    (cd "$BACKUP_DIR" && sudo -u "$FORGEJO_USER" "$FORGEJO_BIN" dump --config "$FORGEJO_CONFIG" --file "$dump")
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
  sudo -u "$FORGEJO_USER" "$FORGEJO_BIN" doctor check --all --config "$FORGEJO_CONFIG" \
    || warn "doctor reported problems, review output above"

  log "Forgejo now: $("$FORGEJO_BIN" --version)"
}

# --- runner ------------------------------------------------------------------

upgrade_runner() {
  need_root
  local want cur new
  want=$(resolve_version "$1" "$RUNNER_REPO") || die "could not resolve version"
  [[ -n $want ]] || die "could not determine runner version"
  cur=$(installed_runner)
  [[ $cur != none ]] || die "no executable at $RUNNER_BIN. This script upgrades an existing install; install forgejo-runner first (https://forgejo.org/docs/latest/admin/actions/installation/binary/), or set RUNNER_BIN to where it lives"
  log "forgejo-runner: installed $cur, target $want"
  [[ $cur != "$want" ]] || { log "already on $want, nothing to do"; return; }

  [[ -f $RUNNER_HOME/.runner ]] \
    || warn "no $RUNNER_HOME/.runner found; set RUNNER_HOME correctly or the runner may need re-registering"

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
  case "$1" in
    forgejo) bin=$FORGEJO_BIN; svc=$FORGEJO_SERVICE; kind=forgejo ;;
    runner)  bin=$RUNNER_BIN;  svc=$RUNNER_SERVICE;  kind=runner  ;;
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

check() {
  local f r
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
  forgejo)  upgrade_forgejo "${2:?usage: $0 forgejo <version|latest>}" ;;
  runner)   upgrade_runner  "${2:?usage: $0 runner <version|latest>}" ;;
  rollback) rollback "${2:-}" ;;
  *) sed -n '2,27p' "$0"; exit 1 ;;
esac
