#!/usr/bin/env bats
# The resolver matrix: resolve_forgejo_settings and resolve_runner_settings,
# exercised both through `settings` (tolerant, warns) and directly (strict,
# dies), against the stub systemctl and the fixture ini files. One @test per
# AGENTS.md "Settings resolution" sub-case. This is where the "Documented
# install layout" and the work-path precedence facts (readFromEnv() then
# readFromArgs(), then WORK_PATH in app.ini last) are guarded.

# Snippets handed to in_script are single-quoted on purpose: they must reach
# the child shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

# shellcheck source=tests/helpers.bash
setup() { load ../helpers; common_setup; }

# --- work path precedence ----------------------------------------------------

@test "fj-both: --work-path in ExecStart beats Environment FORGEJO_WORK_DIR" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-both run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "    FORGEJO_WORK_PATH /srv/flag                       (unit ExecStart --work-path)"
}

@test "fj-env: work path comes from Environment FORGEJO_WORK_DIR, and the quoted spaced entry does not break parsing" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-env run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "    FORGEJO_WORK_PATH /srv/env                        (unit Environment FORGEJO_WORK_DIR)"
}

@test "fj-wp: app.ini's WORK_PATH wins over the unit's Environment, with a mismatch warning naming both" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-wp run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "    FORGEJO_WORK_PATH /srv/data                       (app.ini WORK_PATH)"
  assert_stderr_contains "app.ini sets WORK_PATH = /srv/data but the unit gives /srv/env (from: unit Environment FORGEJO_WORK_DIR)"
  assert_stderr_contains "Remove the outdated value from the unit to silence it"
}

@test "an operator FORGEJO_WORK_PATH that conflicts with app.ini's WORK_PATH: settings warns" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-wp FORGEJO_WORK_PATH=/elsewhere run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "FORGEJO_WORK_PATH=/elsewhere but $FIXTURES/ini/wp.ini sets WORK_PATH = /srv/data"
  assert_stderr_contains "either unset FORGEJO_WORK_PATH or change WORK_PATH in app.ini"
}

@test "the same conflict dies through resolve_forgejo_settings (strict, no --tolerant)" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-wp FORGEJO_WORK_PATH=/elsewhere \
    run --separate-stderr in_script 'resolve_forgejo_settings --quiet'
  assert_status 1
  assert_stderr_contains "cannot take effect"
}

@test "the same conflict dies through resolve_forgejo_settings --rollback too" {
  # AGENTS.md: --rollback skips only the "current binary must be executable"
  # check. This conflict die happens before that check is ever reached.
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-wp FORGEJO_WORK_PATH=/elsewhere \
    run --separate-stderr in_script 'resolve_forgejo_settings --quiet --rollback'
  assert_status 1
  assert_stderr_contains "cannot take effect"
}

@test "an operator FORGEJO_WORK_PATH equal to app.ini's WORK_PATH passes silently" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-wp FORGEJO_WORK_PATH=/srv/data run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "    FORGEJO_WORK_PATH /srv/data                       (env)"
  refute_stderr_contains "cannot take effect"
  refute_stderr_contains "Forgejo follows WORK_PATH"
}

# --- same_dir ------------------------------------------------------------------

@test "same_dir agrees a directory and a symlink to it are the same directory" {
  mkdir -p "$TMPDIR/samedir/real" "$TMPDIR/samedir/other"
  ln -s real "$TMPDIR/samedir/link"
  run --separate-stderr in_script '
    same_dir "$1" "$2" && echo SAME || echo DIFFERENT
  ' "$TMPDIR/samedir/real" "$TMPDIR/samedir/link"
  assert_status 0
  assert_output_contains "SAME"
}

@test "same_dir disagrees on two different directories, and agrees on two equal strings that do not exist" {
  mkdir -p "$TMPDIR/samedir/real" "$TMPDIR/samedir/other"
  run --separate-stderr in_script '
    same_dir "$1" "$2" && echo SAME || echo DIFFERENT
  ' "$TMPDIR/samedir/real" "$TMPDIR/samedir/other"
  assert_status 0
  assert_output_contains "DIFFERENT"
  run --separate-stderr in_script '
    same_dir "$1" "$2" && echo SAME || echo DIFFERENT
  ' "/no/such/dir" "/no/such/dir"
  assert_status 0
  assert_output_contains "SAME"
}

# --- relative operator overrides ---------------------------------------------

@test "a relative FORGEJO_CONFIG makes settings warn with the relative-path message" {
  stub_path "$FIXTURES/bin"
  FORGEJO_CONFIG=tmp/x.ini run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "FORGEJO_CONFIG=tmp/x.ini is a relative path"
  assert_stderr_contains "set FORGEJO_CONFIG to an absolute path"
}

@test "a relative FORGEJO_CONFIG makes resolve_forgejo_settings die" {
  stub_path "$FIXTURES/bin"
  FORGEJO_CONFIG=tmp/x.ini run --separate-stderr in_script 'resolve_forgejo_settings --quiet'
  assert_status 1
  assert_stderr_contains "FORGEJO_CONFIG=tmp/x.ini is a relative path"
}

@test "a relative BACKUP_DIR makes settings warn with the relative-path message" {
  stub_path "$FIXTURES/bin"
  BACKUP_DIR=backups run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "BACKUP_DIR=backups is a relative path"
  assert_stderr_contains "set BACKUP_DIR to an absolute path"
}

@test "a relative BACKUP_DIR makes resolve_forgejo_settings die" {
  stub_path "$FIXTURES/bin"
  BACKUP_DIR=backups run --separate-stderr in_script 'resolve_forgejo_settings --quiet'
  assert_status 1
  assert_stderr_contains "BACKUP_DIR=backups is a relative path"
}

@test "a relative RUNNER_HOME makes settings warn with the relative-path message" {
  stub_path "$FIXTURES/bin"
  RUNNER_HOME=runner run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "RUNNER_HOME=runner is a relative path"
  assert_stderr_contains "set RUNNER_HOME to an absolute path"
}

@test "a relative RUNNER_HOME makes resolve_runner_settings die" {
  stub_path "$FIXTURES/bin"
  RUNNER_HOME=runner run --separate-stderr in_script 'resolve_runner_settings --quiet'
  assert_status 1
  assert_stderr_contains "RUNNER_HOME=runner is a relative path"
}

# --- relative Forgejo work path from each of the three sources ---------------

@test "fj-rel: a relative --work-path warns with Forgejo's own wording in settings" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-rel run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "the Forgejo work path data (from: unit ExecStart --work-path) is a relative path"
  assert_stderr_contains "it exits with '--work-path must be absolute path'"
}

@test "fj-rel: resolve_forgejo_settings dies on the relative --work-path" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-rel run --separate-stderr in_script 'resolve_forgejo_settings --quiet'
  assert_status 1
  assert_stderr_contains "--work-path must be absolute path"
}

@test "fj-relenv: a relative FORGEJO_WORK_DIR warns with Forgejo's own wording in settings" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-relenv run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "the Forgejo work path data (from: unit Environment FORGEJO_WORK_DIR) is a relative path"
  assert_stderr_contains "it exits with 'FORGEJO_WORK_DIR (work path) must be absolute path'"
}

@test "fj-relenv: resolve_forgejo_settings dies on the relative FORGEJO_WORK_DIR" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-relenv run --separate-stderr in_script 'resolve_forgejo_settings --quiet'
  assert_status 1
  assert_stderr_contains "FORGEJO_WORK_DIR (work path) must be absolute path"
}

@test "fj-relwp: a relative WORK_PATH in app.ini warns with Forgejo's own wording in settings" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-relwp run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "app.ini WORK_PATH) is a relative path"
  assert_stderr_contains "WORK_PATH in \"$FIXTURES/ini/relwp.ini\" must be absolute path"
}

@test "fj-relwp: resolve_forgejo_settings dies on the relative app.ini WORK_PATH" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-relwp run --separate-stderr in_script 'resolve_forgejo_settings --quiet'
  assert_status 1
  assert_stderr_contains "WORK_PATH in \"$FIXTURES/ini/relwp.ini\" must be absolute path"
}

@test "an absolute work path passes with no relative-path warning at all" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-env run --separate-stderr "$SCRIPT" settings
  assert_status 0
  refute_stderr_contains "is a relative path"
}

# --- the user Forgejo runs as -------------------------------------------------

@test "fj-nouser: a loaded unit with no User= resolves to root, systemd's own default" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-nouser run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "    FORGEJO_USER      root                            (systemd default; unit sets no User)"
}

@test "an unknown Forgejo unit still resolves FORGEJO_USER to the documented default, git" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=nope-unit-xyz run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "    FORGEJO_USER      git                             (default; nope-unit-xyz.service not found)"
  assert_stderr_contains "    FORGEJO_BIN       /usr/local/bin/forgejo          (default; nope-unit-xyz.service not found)"
  assert_stderr_contains "systemd does not know a unit called nope-unit-xyz.service"
}

# --- the runner's home directory ----------------------------------------------

@test "runner-nowd: a loaded unit with no WorkingDirectory= resolves RUNNER_HOME to /" {
  stub_path "$FIXTURES/bin"
  RUNNER_SERVICE=runner-nowd run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "    RUNNER_HOME       /                               (systemd default; unit sets no WorkingDirectory)"
}

@test "an unknown runner unit still resolves RUNNER_HOME to the documented default, /home/runner" {
  stub_path "$FIXTURES/bin"
  RUNNER_SERVICE=nope-runner-xyz run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "    RUNNER_HOME       /home/runner                    (default; nope-runner-xyz.service not found)"
  assert_stderr_contains "systemd does not know a unit called nope-runner-xyz.service"
}

@test "runner-c: RUNNER_CONFIG is the fixture yml and RUNNER_REG_FILE resolves under its WorkingDirectory and exists" {
  stub_path "$FIXTURES/bin"
  RUNNER_SERVICE=runner-c run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "    RUNNER_CONFIG     $FIXTURES/runner.yml"
  assert_stderr_contains "    RUNNER_REG_FILE   $FIXTURES/runnerhome/.runner"
  refute_stderr_contains "no registration file at"
  [[ -f "$FIXTURES/runnerhome/.runner" ]]
}

# --- ExecStart that cannot be read back ---------------------------------------

@test "fj-empty-exec: settings warns 'could not be read back' and marks FORGEJO_BIN a guess" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-empty-exec run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "its ExecStart= could not be read back (systemctl show printed: '')"
  assert_stderr_contains "is only a guess"
  assert_stderr_contains "    FORGEJO_BIN       /usr/local/bin/forgejo          (default; fj-empty-exec.service's ExecStart could not be read)"
}

@test "fj-odd-exec: settings warns 'could not be read back', quoting the odd record, and marks FORGEJO_BIN a guess" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-odd-exec run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "its ExecStart= could not be read back (systemctl show printed: 'ExecStart=/opt/runner daemon')"
  assert_stderr_contains "is only a guess"
}

@test "fj-empty-exec: resolve_forgejo_settings dies without --tolerant, and dies with --rollback too" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-empty-exec run --separate-stderr in_script 'resolve_forgejo_settings --quiet'
  assert_status 1
  assert_stderr_contains "Set FORGEJO_BIN to the binary fj-empty-exec.service runs"
  FORGEJO_SERVICE=fj-empty-exec run --separate-stderr in_script 'resolve_forgejo_settings --quiet --rollback'
  assert_status 1
  assert_stderr_contains "Set FORGEJO_BIN to the binary fj-empty-exec.service runs"
}

@test "fj-odd-exec: resolve_forgejo_settings dies without --tolerant, and dies with --rollback too" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-odd-exec run --separate-stderr in_script 'resolve_forgejo_settings --quiet'
  assert_status 1
  assert_stderr_contains "Set FORGEJO_BIN to the binary fj-odd-exec.service runs"
  FORGEJO_SERVICE=fj-odd-exec run --separate-stderr in_script 'resolve_forgejo_settings --quiet --rollback'
  assert_status 1
  assert_stderr_contains "Set FORGEJO_BIN to the binary fj-odd-exec.service runs"
}

# --- the interpolated LOCAL_ROOT_URL -------------------------------------------

@test "fj-localroot: FORGEJO_URL shows the expanded LOCAL_ROOT_URL, sourced from app.ini" {
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-localroot run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "    FORGEJO_URL       http://127.0.0.1:3000           (app.ini [server] LOCAL_ROOT_URL)"
  refute_stderr_contains "%(PROTOCOL)s"
}

# --- --rollback skips only the executable-binary check ------------------------

@test "resolve_forgejo_settings --rollback succeeds with a missing FORGEJO_BIN; without --rollback it dies" {
  stub_path "$FIXTURES/bin"
  local bin=$TMPDIR/no-such-forgejo
  FORGEJO_SERVICE=forgejo FORGEJO_BIN=$bin FORGEJO_USER=$(id -un) \
    run --separate-stderr in_script 'resolve_forgejo_settings --quiet --rollback'
  assert_status 0
  FORGEJO_SERVICE=forgejo FORGEJO_BIN=$bin FORGEJO_USER=$(id -un) \
    run --separate-stderr in_script 'resolve_forgejo_settings --quiet'
  assert_status 1
  assert_stderr_contains "no executable at $bin"
  assert_stderr_contains "install Forgejo first"
}

@test "resolve_runner_settings --rollback succeeds with a missing RUNNER_BIN; without --rollback it dies" {
  stub_path "$FIXTURES/bin"
  local bin=$TMPDIR/no-such-runner
  RUNNER_SERVICE=forgejo-runner RUNNER_BIN=$bin \
    run --separate-stderr in_script 'resolve_runner_settings --quiet --rollback'
  assert_status 0
  RUNNER_SERVICE=forgejo-runner RUNNER_BIN=$bin \
    run --separate-stderr in_script 'resolve_runner_settings --quiet'
  assert_status 1
  assert_stderr_contains "no executable at $bin"
  assert_stderr_contains "install forgejo-runner first"
}

# --- nothing installed at all --------------------------------------------------

@test "with no units and no binaries, settings prints exactly the two not-installed lines" {
  # The nounits systemctl answers not-found for every unit, and PATH holds no
  # forgejo binary, so this is the "nothing installed" host from AGENTS.md
  # whichever machine runs the suite: the development machine, a GitHub
  # runner with a real systemctl, or a container without one.
  stub_path "$FIXTURES/nounits"
  run --separate-stderr "$SCRIPT" settings
  assert_status 0
  local lines
  lines=$(printf '%s\n' "$stderr" | grep -c 'not installed')
  assert_equal "2" "$lines"
  local total
  total=$(printf '%s\n' "$stderr" | grep -c .)
  assert_equal "2" "$total"
}

# --- the two stock units, printed whole ---------------------------------------
#
# The tests above each assert one line of the block. These two assert every
# line of it, for the units the shipped unit files describe, so that a change
# to any value, source, or column the operator reads has to be made here as
# well. `settings` prints the Forgejo block and then the runner block, so each
# test picks its own out of stderr and compares the whole thing.

# The lines of a captured stderr from the one containing $2 up to, but not
# including, the line that starts the next block. The stderr is passed in
# rather than read from the enclosing test, which shellcheck reads as a
# subshell.
settings_block() {  # $1 = the captured stderr, $2 = text identifying the block's first line
  printf '%s\n' "$1" | awk -v start="$2" '
    index($0, start) { inblock = 1 }
    inblock && !index($0, start) && /settings for/ { exit }
    inblock { print }'
}

@test "the stock forgejo unit resolves to exactly the documented block, line for line" {
  # No FORGEJO_BIN or FORGEJO_USER is set: `settings` is tolerant, so it never
  # runs the binary and never looks the account up, and every value below
  # comes from the stub unit and the fixture app.ini. There is no
  # FORGEJO_SOCKET line because PROTOCOL is http, so the socket is never
  # resolved and the resolver leaves that line out; fj-unix below is the case
  # where it appears. The warning after the block is part of the answer: this
  # app.ini sets no WORK_PATH and the unit passes no --work-path, so Forgejo
  # would fall back to the directory holding the binary.
  stub_path "$FIXTURES/bin"
  run --separate-stderr "$SCRIPT" settings
  assert_status 0
  local -a want=(
    $'\033[1;34m==>\033[0m Forgejo settings for forgejo.service (override any with the env var):'
    '    FORGEJO_SERVICE   forgejo                         (default)'
    '    FORGEJO_BIN       /usr/local/bin/forgejo          (unit ExecStart)'
    '    FORGEJO_USER      git                             (unit User)'
    # The config path is longer than the 31-column value field, so it simply
    # pushes its source over instead of being padded to it.
    "    FORGEJO_CONFIG    $FIXTURES/ini/app.ini (unit ExecStart --config)"
    '    FORGEJO_WORK_PATH (none)                          (not set)'
    '    FORGEJO_URL       http://127.0.0.1:3000           (app.ini [server] PROTOCOL, HTTP_ADDR, HTTP_PORT)'
    '    FORGEJO_DB_TYPE   sqlite3                         (app.ini [database] DB_TYPE)'
    '    BACKUP_DIR        /var/backups/forgejo            (default)'
    '    SKIP_BACKUP       0                               (default)'
    $'\033[1;33mWARN:\033[0m '"no work path found in the unit or in $FIXTURES/ini/app.ini; Forgejo will fall back to the directory holding /usr/local/bin/forgejo. If that is not where its data lives, set FORGEJO_WORK_PATH."
  )
  assert_equal "$(printf '%s\n' "${want[@]}")" "$(settings_block "$stderr" 'Forgejo settings for')"
}

@test "the stock forgejo-runner unit resolves to exactly the documented block, line for line" {
  # RUNNER_REG_FILE is the one value the operator cannot override: it follows
  # RUNNER_HOME and the runner.file key in the config, which is why the header
  # line says so. The warning after the block is about that file being absent.
  if [[ -f /home/runner/.runner ]]; then
    skip "this host really has /home/runner/.runner, so the missing-registration warning would not print"
  fi
  stub_path "$FIXTURES/bin"
  run --separate-stderr "$SCRIPT" settings
  assert_status 0
  local -a want=(
    $'\033[1;34m==>\033[0m forgejo-runner settings for forgejo-runner.service (override any with the env var, except RUNNER_REG_FILE, which follows RUNNER_HOME and RUNNER_CONFIG):'
    '    RUNNER_SERVICE    forgejo-runner                  (default)'
    '    RUNNER_BIN        /usr/local/bin/forgejo-runner   (unit ExecStart)'
    '    RUNNER_HOME       /home/runner                    (unit WorkingDirectory)'
    "    RUNNER_CONFIG     $FIXTURES/runner.yml (unit ExecStart -c)"
    "    RUNNER_REG_FILE   /home/runner/.runner            ($FIXTURES/runner.yml, runner.file)"
    $'\033[1;33mWARN:\033[0m '"no registration file at /home/runner/.runner (from: $FIXTURES/runner.yml, runner.file); set RUNNER_HOME or RUNNER_CONFIG correctly, or the runner may need re-registering after the upgrade"
  )
  assert_equal "$(printf '%s\n' "${want[@]}")" "$(settings_block "$stderr" 'forgejo-runner settings for')"
}

# --- an install listening on a unix socket ------------------------------------
#
# With PROTOCOL = http+unix the health check has to dial a socket file rather
# than a host and port. The script never stats that file - nothing in it
# checks the socket exists, because the service it belongs to is stopped for
# most of an upgrade - so what is tested here is where the path comes from and
# what happens when nothing names one.

@test "fj-unix: FORGEJO_SOCKET is the HTTP_ADDR socket path, and FORGEJO_URL is Forgejo's own http+unix default" {
  # LOCAL_ROOT_URL is unset in this app.ini, so resolve_forgejo_url falls
  # through to the PROTOCOL case and uses http://unix, which is Forgejo's own
  # default for http+unix; the host name in it is ignored, since curl dials
  # the socket.
  stub_path "$FIXTURES/bin"
  FORGEJO_SERVICE=fj-unix run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "    FORGEJO_SOCKET    /run/forgejo/forgejo.sock       (app.ini [server] HTTP_ADDR)"
  assert_stderr_contains "    FORGEJO_URL       http://unix                     (app.ini [server] PROTOCOL=http+unix)"
}

@test "an http+unix app.ini with no HTTP_ADDR: settings warns that the health check has nowhere to connect" {
  stub_path "$FIXTURES/bin"
  FORGEJO_CONFIG=$FIXTURES/ini/unix-nosock.ini run --separate-stderr "$SCRIPT" settings
  assert_status 0
  assert_stderr_contains "PROTOCOL is http+unix in $FIXTURES/ini/unix-nosock.ini but HTTP_ADDR does not give a socket path, so the health check has nowhere to connect. Set FORGEJO_SOCKET to the socket file"
  assert_stderr_contains "    FORGEJO_SOCKET    (none)                          (unknown; PROTOCOL=http+unix needs FORGEJO_SOCKET)"
}

@test "the same app.ini dies through resolve_forgejo_settings, before the binary is even looked at" {
  # The socket is resolved ahead of the strict checks, so this dies on the
  # missing socket path rather than on the binary this development machine
  # does not have.
  stub_path "$FIXTURES/bin"
  FORGEJO_CONFIG=$FIXTURES/ini/unix-nosock.ini \
    run --separate-stderr in_script 'resolve_forgejo_settings --quiet'
  assert_status 1
  assert_stderr_contains "PROTOCOL is http+unix in $FIXTURES/ini/unix-nosock.ini but HTTP_ADDR does not give a socket path"
  refute_stderr_contains "no executable at"
}

# --- an ExecStart argv[] that cannot be read back faithfully -------------------

@test "fj-space: a -c path containing a space comes back truncated and is refused before anything is stopped" {
  # systemctl prints argv[] with a plain space between arguments and no
  # quoting, so "-c /x/has space/app.ini" reads back as two words and the
  # config path is truncated at the space. The real path cannot be recovered,
  # so the strict resolver refuses it by name instead of guessing - and it
  # does so among the pre-stop checks, while the service is still running.
  # FORGEJO_BIN and FORGEJO_USER are only set so that the checks ahead of the
  # config one pass on a machine with no Forgejo install.
  stub_path "$FIXTURES/bin"
  local bin=$BATS_TEST_TMPDIR/forgejo
  fake_bin "$bin" 'forgejo version 16.0.5+gitea-1.22.0 (release name 16.0.5)'
  FORGEJO_SERVICE=fj-space FORGEJO_BIN=$bin FORGEJO_USER=$(id -un) \
    run --separate-stderr in_script 'resolve_forgejo_settings --quiet'
  assert_status 1
  assert_stderr_contains "cannot read the Forgejo config at $FIXTURES/ini/has (from: unit ExecStart --config)"
  assert_stderr_contains "set FORGEJO_CONFIG to its path"
}
