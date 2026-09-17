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
#   RUNNER_USER      forgejo-runner
#   RUNNER_SERVICE   forgejo-runner
#   RUNNER_HOME      /var/lib/forgejo-runner   (directory holding the .runner registration file)
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
RUNNER_USER=${RUNNER_USER:-forgejo-runner}
RUNNER_SERVICE=${RUNNER_SERVICE:-forgejo-runner}
RUNNER_HOME=${RUNNER_HOME:-/var/lib/forgejo-runner}

RELEASE_KEY=EB114F5E6C0DC2BCDD183550A4B61A2DC5923710
KEYSERVER=hkps://keys.openpgp.org
FORGEJO_REPO=https://code.forgejo.org/forgejo/forgejo
RUNNER_REPO=https://code.forgejo.org/forgejo/runner

WORKDIR=$(mktemp -d /tmp/forgejo-upgrade.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# log/warn go to stderr so command substitution captures only returned values
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

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
  # binary prints "forgejo version 16.0.4+gitea-1.22.0 (release name 16.0.4) ..."
  "$FORGEJO_BIN" --version 2>/dev/null | sed -n 's/^[Ff]orgejo version \([0-9][0-9.]*\).*/\1/p'
}

installed_runner() {
  [[ -x $RUNNER_BIN ]] || { echo none; return; }
  # binary prints "forgejo-runner version v13.1.0"
  "$RUNNER_BIN" --version 2>/dev/null | sed -n 's/.*version v\{0,1\}\([0-9][0-9.]*\).*/\1/p'
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
  if [[ -x $2 ]]; then
    log "Keeping previous binary at $2.prev"
    cp -p "$2" "$2.prev"
  fi
  install -m 755 -o root -g root "$1" "$2"
}

# --- forgejo server ----------------------------------------------------------

upgrade_forgejo() {
  need_root
  local want cur new
  want=$(resolve_version "$1" "$FORGEJO_REPO") || die "could not resolve version"
  [[ -n $want ]] || die "could not determine Forgejo version"
  cur=$(installed_forgejo)
  log "Forgejo: installed $cur, target $want"
  [[ $cur != "$want" ]] || { log "already on $want, nothing to do"; return; }

  if [[ $cur != none && ${cur%%.*} != "${want%%.*}" ]]; then
    warn "major version change ${cur%%.*} -> ${want%%.*}: read the release notes first:"
    warn "  $FORGEJO_REPO/src/branch/forgejo/release-notes-published/$want.md"
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

  log "Starting $FORGEJO_SERVICE"
  systemctl start "$FORGEJO_SERVICE"

  log "Waiting for $FORGEJO_URL/api/healthz"
  local i
  for i in $(seq 1 60); do
    if curl -fs "$FORGEJO_URL/api/healthz" >/dev/null 2>&1; then break; fi
    sleep 1
    [[ $i -lt 60 ]] || { journalctl -u "$FORGEJO_SERVICE" -n 40 --no-pager; die "service did not become healthy; rollback with: $0 rollback forgejo"; }
  done

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
  log "forgejo-runner: installed $cur, target $want"
  [[ $cur != "$want" ]] || { log "already on $want, nothing to do"; return; }

  [[ -f $RUNNER_HOME/.runner ]] \
    || warn "no $RUNNER_HOME/.runner found; set RUNNER_HOME correctly or the runner may need re-registering"

  ensure_key
  new=$(fetch_and_verify "$RUNNER_REPO" "forgejo-runner-$want-linux-$(arch)" "$want")
  "$new" --version | grep -q "$want" \
    || die "downloaded binary does not report version $want"

  # SIGTERM lets the runner finish in-flight jobs; the unit's TimeoutStopSec bounds the wait.
  log "Stopping $RUNNER_SERVICE (waits for running jobs)"
  systemctl stop "$RUNNER_SERVICE"

  install_binary "$new" "$RUNNER_BIN"

  log "Starting $RUNNER_SERVICE"
  systemctl start "$RUNNER_SERVICE"
  sleep 3
  systemctl is-active --quiet "$RUNNER_SERVICE" \
    || { journalctl -u "$RUNNER_SERVICE" -n 40 --no-pager; die "runner failed to start; rollback with: $0 rollback runner"; }

  log "forgejo-runner now: $("$RUNNER_BIN" --version)"
  log "Confirm it shows online under Site Administration > Actions > Runners"
}

# --- rollback / check --------------------------------------------------------

rollback() {
  need_root
  local bin svc
  case "$1" in
    forgejo) bin=$FORGEJO_BIN; svc=$FORGEJO_SERVICE ;;
    runner)  bin=$RUNNER_BIN;  svc=$RUNNER_SERVICE ;;
    *) die "rollback forgejo|runner" ;;
  esac
  [[ -x $bin.prev ]] || die "no $bin.prev to roll back to"
  log "Rolling back $bin to $("$bin.prev" --version)"
  systemctl stop "$svc"
  mv -f "$bin.prev" "$bin"
  systemctl start "$svc"
  log "$svc restarted with $("$bin" --version)"
}

check() {
  printf '%-16s %-12s %-12s\n' component installed latest
  printf '%-16s %-12s %-12s\n' forgejo "$(installed_forgejo)" "$(latest_tag "$FORGEJO_REPO")"
  printf '%-16s %-12s %-12s\n' forgejo-runner "$(installed_runner)" "$(latest_tag "$RUNNER_REPO")"
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
