#!/usr/bin/env bats
# on_exit and rollback_command: what an operator is told when the run stops
# with a service down. This file carries the AGENTS.md rules "Never leave the
# service stopped without saying so" and "Every failure message must be
# actionable": the journal is printed, the remedy names the exact command, the
# printed rollback carries the overrides this run was given (shell-quoted, and
# after a sudo prefix rather than before it, because sudo strips NAME=value
# words out of the environment it inherits but passes them through from its own
# command line), and the real exit status survives all of it.
#
# Each case runs a child bash that sources the script, sets the state on_exit
# reads, and exits; the EXIT trap the script armed at source time does the
# rest. journalctl is the fixture stub, so no real journal is read.

# Snippets handed to in_script are single-quoted on purpose: they must reach
# the child shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

# shellcheck source=tests/helpers.bash
setup() {
  load ../helpers
  common_setup
  # The fixture stubs: journalctl, which on_exit really runs, and the stub
  # systemctl beside it, which nothing here reaches because on_exit prints
  # the systemctl commands rather than running them.
  stub_path "$FIXTURES/bin"
  BIN=$BATS_TEST_TMPDIR/opt/forgejo
  mkdir -p "${BIN%/*}"
}

# The state install_binary leaves behind when the copy has been made: the
# service is stopped and the new binary is in place.
replaced_1() {
  run --separate-stderr in_script '
    STOPPED_SVC=x.service
    STOPPED_KIND=forgejo
    STOPPED_BIN=$1
    BINARY_REPLACED=1
    exit 3
  ' "$BIN"
}

@test "a run that stopped a service prints the journal before anything else" {
  replaced_1
  assert_status 3
  assert_stderr_contains "did not finish; x.service is probably still stopped. Last 40 journal lines:"
  assert_stderr_contains "stub journal"
  assert_line_before "Last 40 journal lines:" "stub journal"
}

@test "the exit status the run died with survives on_exit" {
  replaced_1
  assert_status 3
}

@test "a Ctrl-C exit status survives on_exit too" {
  # The INT trap turns Ctrl-C into exit 130 so that the EXIT trap still runs;
  # on_exit must hand that 130 back rather than replacing it with its own.
  run --separate-stderr in_script '
    STOPPED_SVC=x.service
    STOPPED_KIND=forgejo
    STOPPED_BIN=$1
    BINARY_REPLACED=1
    exit 130
  ' "$BIN"
  assert_status 130
}

@test "with a binary replaced, the rollback command carries this run's overrides, shell-quoted" {
  # The overrides go in the order the capture loop reads them, and BACKUP_DIR
  # has a space in it on purpose: pasted as printed, the command has to resolve
  # the same install this run did.
  FORGEJO_SERVICE=x.service FORGEJO_BIN="$BIN" BACKUP_DIR='/var/back ups' \
    replaced_1
  assert_status 3
  assert_stderr_contains "a new binary was written to $BIN (the copy may not have completed) and the previous one is kept at $BIN.prev"
  assert_stderr_contains "put the previous binary back with: FORGEJO_SERVICE=x.service FORGEJO_BIN=$BIN BACKUP_DIR=/var/back\\ ups $SCRIPT rollback forgejo"
}

@test "SUDO_USER puts sudo in front of the overrides, not after them" {
  # sudo passes NAME=value words given on its own command line through to the
  # command but strips them from the environment it inherits, so the overrides
  # have to follow the sudo.
  SUDO_USER=sean FORGEJO_SERVICE=x.service FORGEJO_BIN="$BIN" BACKUP_DIR='/var/back ups' \
    replaced_1
  assert_status 3
  assert_stderr_contains "put the previous binary back with: sudo FORGEJO_SERVICE=x.service FORGEJO_BIN=$BIN BACKUP_DIR=/var/back\\ ups $SCRIPT rollback forgejo"
}

@test "with no overrides at all the printed command is the bare script path" {
  replaced_1
  assert_status 3
  assert_stderr_contains "put the previous binary back with: $SCRIPT rollback forgejo"
}

@test "a runner rollback shows only the runner overrides" {
  # Both sets are captured at source time; rollback_command must pick the one
  # that matches the service it is reporting on.
  FORGEJO_SERVICE=x.service FORGEJO_BIN=/opt/fj/forgejo RUNNER_BIN=/opt/r \
    run --separate-stderr in_script '
      STOPPED_SVC=r.service
      STOPPED_KIND=runner
      STOPPED_BIN=/opt/r
      BINARY_REPLACED=1
      exit 1
    '
  assert_status 1
  assert_stderr_contains "put the previous binary back with: RUNNER_BIN=/opt/r $SCRIPT rollback runner"
  refute_stderr_contains "FORGEJO_SERVICE="
  refute_stderr_contains "FORGEJO_BIN="
}

@test "the rollback command is printed before the wait-and-check hint" {
  # Rolling back is the first move; letting a slow migration finish is the
  # exception, so it comes second.
  replaced_1
  assert_status 3
  assert_line_before "rollback forgejo" "systemctl status x.service"
  assert_stderr_contains "if the journal above shows the new binary is still starting up (a database migration can take longer than the health check waits), let it finish and check with: systemctl status x.service"
}

@test "a service stopped with the binary untouched is started again, not rolled back" {
  run --separate-stderr in_script '
    STOPPED_SVC=x.service
    STOPPED_KIND=forgejo
    STOPPED_BIN=$1
    exit 1
  ' "$BIN"
  assert_status 1
  assert_stderr_contains "the binary was not changed. Start the service again with: systemctl start x.service"
  refute_stderr_contains "rollback forgejo"
}

@test "a rollback interrupted before its rename says nothing was moved back" {
  # BINARY_REPLACED=2 is set before the mv, so .prev still being there is what
  # says the rename never ran. Running the rollback again is then safe.
  touch "$BIN.prev"
  run --separate-stderr in_script '
    STOPPED_SVC=x.service
    STOPPED_KIND=forgejo
    STOPPED_BIN=$1
    BINARY_REPLACED=2
    exit 1
  ' "$BIN"
  assert_status 1
  assert_stderr_contains "the previous binary is still at $BIN.prev and was not moved back. Run the rollback again: $SCRIPT rollback forgejo"
  refute_stderr_contains "back in place"
}

@test "a rollback whose rename completed says the previous binary is back in place" {
  # No .prev left, so there is nothing to roll back again: the remedy is to
  # read the journal, put the data back if the database moved on, and start.
  run --separate-stderr in_script '
    STOPPED_SVC=x.service
    STOPPED_KIND=forgejo
    STOPPED_BIN=$1
    BINARY_REPLACED=2
    exit 1
  ' "$BIN"
  assert_status 1
  assert_stderr_contains "the previous binary is back in place at $BIN and no $BIN.prev remains"
  assert_stderr_contains "read the journal above, then start the service with: systemctl start x.service"
  refute_stderr_contains "Run the rollback again"
}

@test "the back-in-place message carries the restore hint for an unknown database" {
  # FORGEJO_DB_TYPE was never resolved here, and anything that is not sqlite3 -
  # an unreadable config included - takes the cautious wording.
  BACKUP_DIR=/var/backups/forgejo run --separate-stderr in_script '
    STOPPED_SVC=x.service
    STOPPED_KIND=forgejo
    STOPPED_BIN=$1
    BINARY_REPLACED=2
    exit 1
  ' "$BIN"
  assert_status 1
  assert_stderr_contains "if the journal says the database is for a newer Forgejo, the data has to go back before that start (see https://forgejo.org/docs/latest/admin/upgrade/#backup): restore the database from the native dump you took before the upgrade (the zip in /var/backups/forgejo holds repositories and files, but its SQL is not a safe restore); for SQLite the zip itself would contain the database"
}

@test "a run that stopped nothing says nothing and still clears its working directory" {
  run --separate-stderr in_script 'printf "%s\n" "$WORKDIR"'
  assert_status 0
  assert_equal "" "$stderr"
  local workdir=$output
  if [[ -z $workdir ]]; then
    printf 'the snippet printed no WORKDIR path\n' >&2
    return 1
  fi
  if [[ -e $workdir ]]; then
    printf 'the working directory %s outlived the run; on_exit did not remove it\n' "$workdir" >&2
    return 1
  fi
}
