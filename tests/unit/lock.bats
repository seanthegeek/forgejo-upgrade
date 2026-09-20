#!/usr/bin/env bats
# acquire_lock and the release half of on_exit: one upgrade at a time on a
# host, because two runs at once would overwrite the .prev copy a rollback
# needs. This file carries the AGENTS.md "The lock" procedure, and in
# particular the two distinctions the message wording turns on: a lock another
# run really holds against a lock directory that could not be created at all
# (a missing parent, a plain file in the way), and a holder that is still
# running against one that is gone. The second run is a genuinely separate
# process in every case here, not a subshell, because the thing being checked
# is that a loser leaves the winner's lock alone.
#
# LOCK_DIR is a plain variable set when the script is sourced, so each snippet
# points it at a path under the per-test directory before calling acquire_lock.

# Every single-quoted string below is a snippet handed to a child bash by
# in_script, so $1, $$ and $LOCK_DIR inside one have to reach that shell
# unexpanded. That is exactly what SC2016 warns about, and exactly what is
# wanted here, so it is turned off for the file rather than repeated at every
# call.
# shellcheck disable=SC2016

# `run --separate-stderr` is a 1.5.0 feature; saying so here turns bats'
# BW02 warning into a version requirement it checks.
bats_require_minimum_version 1.5.0

# shellcheck source=tests/helpers.bash
setup() {
  load ../helpers
  common_setup
  LOCK=$BATS_TEST_TMPDIR/forgejo-upgrade.lock
}

@test "acquire_lock takes the lock and records the pid of the run holding it" {
  run --separate-stderr in_script '
    LOCK_DIR=$1
    acquire_lock
    [[ -d $LOCK_DIR ]] && echo dir-created
    [[ $(cat "$LOCK_DIR/pid") == $$ ]] && echo pid-is-this-run
    echo "held=$LOCK_HELD"
  ' "$LOCK"
  assert_status 0
  assert_output_contains "dir-created"
  assert_output_contains "pid-is-this-run"
  assert_output_contains "held=1"
}

@test "the lock is released when the run that took it exits" {
  run --separate-stderr in_script 'LOCK_DIR=$1; acquire_lock; echo taken' "$LOCK"
  assert_status 0
  assert_output_contains "taken"
  if [[ -d $LOCK ]]; then
    printf 'the lock directory %s outlived the run that took it; on_exit did not release it\n' \
      "$LOCK" >&2
    return 1
  fi
}

@test "a second run dies naming the pid of the run that holds the lock, still running" {
  # The second acquire runs in a separate bash that sources the script itself,
  # which is what a second concurrent run is. It starts while the first is
  # still inside its own snippet, so the lock is genuinely held and nothing
  # here races on a sleep.
  run --separate-stderr in_script '
    LOCK_DIR=$1
    acquire_lock
    printf "first-pid=%s\n" "$$"
    set +e
    bash "$2" "$1"
    printf "second-rc=%s\n" "$?"
    [[ -d $LOCK_DIR ]] && echo still-held
  ' "$LOCK" "$(snippet_file 'source "$0"; LOCK_DIR=$1; acquire_lock; echo SECOND-ACQUIRED')"
  assert_status 0

  local pid=${output#*first-pid=}
  pid=${pid%%$'\n'*}

  assert_output_contains "second-rc=1"
  assert_output_contains "still-held"
  # The sentinel the second run would echo goes to stdout, so stdout is where
  # it has to be refuted: refuting it on stderr passes whether or not the
  # second acquire went through.
  refute_output_contains "SECOND-ACQUIRED"
  assert_stderr_contains "another forgejo-upgrade run holds the lock $LOCK"
  assert_stderr_contains "pid $pid, still running"
  assert_stderr_contains "Two runs at once could overwrite the .prev copy that a rollback needs"
}

@test "a lock left by a process that is gone says so and gives the rm -r remedy" {
  # The pid is written with no final newline on purpose: `read` then returns
  # non-zero although it has filled the value in, and the script must still
  # report that pid rather than fall through to "no pid recorded".
  run --separate-stderr in_script '
    LOCK_DIR=$1
    acquire_lock
    # 4194305 is one above the largest pid_max Linux allows (2^22, per
    # proc(5)), so no process can ever have it; a smaller number such as
    # 999999 would be a real pid on a host whose pid_max was raised.
    printf 4194305 > "$LOCK_DIR/pid"
    set +e
    bash "$2" "$1"
    printf "second-rc=%s\n" "$?"
  ' "$LOCK" "$(snippet_file 'source "$0"; LOCK_DIR=$1; acquire_lock; echo SECOND-ACQUIRED')"
  assert_status 0
  assert_output_contains "second-rc=1"
  refute_output_contains "SECOND-ACQUIRED"
  assert_stderr_contains "pid 4194305, no longer running"
  assert_stderr_contains "remove the stale lock with: rm -r $LOCK"
}

@test "a lock directory with no pid file is still a held lock, with no pid recorded" {
  mkdir -p "$LOCK"
  run --separate-stderr in_script 'LOCK_DIR=$1; acquire_lock; echo ACQUIRED' "$LOCK"
  assert_status 1
  refute_output_contains "ACQUIRED"
  assert_stderr_contains "another forgejo-upgrade run holds the lock $LOCK"
  assert_stderr_contains "no pid recorded"
  # The run that lost must not take the winner's lock away with it.
  if [[ ! -d $LOCK ]]; then
    printf 'the run that failed to take the lock removed %s on its way out\n' "$LOCK" >&2
    return 1
  fi
}

@test "a run that sources the script without taking the lock leaves it alone" {
  mkdir -p "$LOCK"
  printf '%s\n' 4242 > "$LOCK/pid"
  run --separate-stderr in_script 'LOCK_DIR=$1; echo "held=$LOCK_HELD"' "$LOCK"
  assert_status 0
  assert_output_contains "held=0"
  assert_equal "4242" "$(cat "$LOCK/pid")"
}

@test "a lock whose pid file cannot be written is released rather than left behind" {
  # The failure is induced with a mkdir wrapper that puts a directory where the
  # pid file goes, so the write fails with "Is a directory" for any user. An
  # earlier version used umask 0777 to leave the lock directory at mode 000,
  # which does not stop root: the Forgejo CI job runs as root in its container
  # and the write went through there. The lock is owned from the moment the
  # directory exists, so on_exit has to remove it or every later run stops at
  # a lock nobody holds.
  # LC_ALL=C because "Is a directory" is bash's redirection diagnostic, which
  # comes from strerror and is translated under another locale.
  run --separate-stderr in_script '
    export LC_ALL=C
    LOCK_DIR=$1
    mkdir() { command mkdir "$@" && command mkdir "$1/pid"; }
    acquire_lock
    echo UNEXPECTED-RETURNED
  ' "$LOCK"
  if [[ $status -eq 0 ]]; then
    printf 'expected a non-zero exit after the failed pid write, got 0\n' >&2
    return 1
  fi
  refute_output_contains "UNEXPECTED-RETURNED"
  assert_stderr_contains "Is a directory"
  if [[ -d $LOCK ]]; then
    printf 'the lock directory %s was left behind after the pid write failed\n' "$LOCK" >&2
    return 1
  fi
}

@test "a lock directory under a missing parent is a creation failure, not a held lock" {
  # mkdir's own message is quoted back, so the child reads it in the C locale
  # rather than whatever the developer's shell is set to.
  run --separate-stderr in_script 'export LC_ALL=C; LOCK_DIR=$1; acquire_lock' \
    "$BATS_TEST_TMPDIR/no-such-directory/forgejo-upgrade.lock"
  assert_status 1
  assert_stderr_contains "could not create the lock directory"
  assert_stderr_contains "No such file or directory"
  refute_stderr_contains "another forgejo-upgrade run holds the lock"
}

@test "a plain file at the lock path is a creation failure, and is left alone" {
  local file=$BATS_TEST_TMPDIR/lock-is-a-file
  printf 'not a lock\n' > "$file"
  run --separate-stderr in_script 'export LC_ALL=C; LOCK_DIR=$1; acquire_lock' "$file"
  assert_status 1
  assert_stderr_contains "could not create the lock directory"
  assert_stderr_contains "File exists"
  refute_stderr_contains "another forgejo-upgrade run holds the lock"
  assert_equal "not a lock" "$(cat "$file")"
}
