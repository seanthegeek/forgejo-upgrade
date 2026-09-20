#!/usr/bin/env bats
# FORGEJO_DB_TYPE (read from [database] DB_TYPE in app.ini by
# resolve_forgejo_settings) and the three functions built on it -
# db_is_external, backup_note, restore_hint. AGENTS.md, "`forgejo dump`'s zip
# is not a safe database restore for PostgreSQL or MySQL": anything but
# sqlite3 - including a type this script could not read at all - is treated
# as external, and backup_note/restore_hint's wording for that cautious case
# must not drift from the sqlite3 wording's opposite number.

# Snippets handed to in_script are single-quoted on purpose: they must reach
# the child shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

# shellcheck source=tests/helpers.bash
setup() { load ../helpers; common_setup; }

@test "FORGEJO_DB_TYPE reads sqlite3 from app.ini, and db_is_external is false" {
  stub_path "$FIXTURES/bin"
  fake_bin "$BATS_TEST_TMPDIR/bin/forgejo" "forgejo version 16.0.5"
  FORGEJO_SERVICE=fj-sqlite FORGEJO_BIN=$BATS_TEST_TMPDIR/bin/forgejo \
    run --separate-stderr in_script '
      resolve_forgejo_settings --tolerant --quiet
      printf "type=%s src=%s\n" "$FORGEJO_DB_TYPE" "$FORGEJO_DB_TYPE_SRC"
      db_is_external && echo external=0 || echo external=1
    '
  assert_status 0
  assert_output_contains "type=sqlite3"
  assert_output_contains "src=app.ini [database] DB_TYPE"
  assert_output_contains "external=1"
}

@test "FORGEJO_DB_TYPE reads postgres from app.ini, and db_is_external is true" {
  stub_path "$FIXTURES/bin"
  fake_bin "$BATS_TEST_TMPDIR/bin/forgejo" "forgejo version 16.0.5"
  FORGEJO_SERVICE=fj-postgres FORGEJO_BIN=$BATS_TEST_TMPDIR/bin/forgejo \
    run --separate-stderr in_script '
      resolve_forgejo_settings --tolerant --quiet
      printf "type=%s\n" "$FORGEJO_DB_TYPE"
      db_is_external && echo external=0 || echo external=1
    '
  assert_status 0
  assert_output_contains "type=postgres"
  assert_output_contains "external=0"
}

@test "an unreadable FORGEJO_CONFIG leaves FORGEJO_DB_TYPE unknown, not guessed" {
  stub_path "$FIXTURES/bin"
  FORGEJO_CONFIG=$BATS_TEST_TMPDIR/no-such-app.ini \
    run --separate-stderr in_script '
      resolve_forgejo_settings --tolerant --quiet
      printf "type=[%s] src=%s\n" "$FORGEJO_DB_TYPE" "$FORGEJO_DB_TYPE_SRC"
    '
  assert_status 0
  assert_output_contains "type=[]"
  assert_output_contains "src=unknown; cannot read $BATS_TEST_TMPDIR/no-such-app.ini"
}

@test "FORGEJO_DB_TYPE set in the environment wins over app.ini" {
  stub_path "$FIXTURES/bin"
  fake_bin "$BATS_TEST_TMPDIR/bin/forgejo" "forgejo version 16.0.5"
  FORGEJO_SERVICE=fj-sqlite FORGEJO_BIN=$BATS_TEST_TMPDIR/bin/forgejo FORGEJO_DB_TYPE=mysql \
    run --separate-stderr in_script '
      resolve_forgejo_settings --tolerant --quiet
      printf "type=%s src=%s\n" "$FORGEJO_DB_TYPE" "$FORGEJO_DB_TYPE_SRC"
    '
  assert_status 0
  assert_output_contains "type=mysql src=env"
}

@test "backup_note for sqlite3 says the zip is a complete backup" {
  run --separate-stderr in_script '
    FORGEJO_DB_TYPE=sqlite3
    BACKUP_DIR=/var/backups/forgejo
    backup_note
  '
  assert_status 0
  assert_stderr_contains "the database is SQLite, so the dump zip in /var/backups/forgejo will contain the database file itself and is a complete backup"
}

@test "backup_note for postgres warns that the zip's SQL copy is not a safe restore" {
  run --separate-stderr in_script '
    FORGEJO_DB_TYPE=postgres
    BACKUP_DIR=/var/backups/forgejo
    backup_note
  '
  assert_status 0
  assert_stderr_contains "the database is postgres."
  assert_stderr_contains "Taking a native dump (pg_dump, mysqldump) is your job; this script does not run one"
}

@test "backup_note for an unknown database type uses the same cautious wording as an external one" {
  run --separate-stderr in_script '
    FORGEJO_DB_TYPE=""
    BACKUP_DIR=/var/backups/forgejo
    backup_note
  '
  assert_status 0
  assert_stderr_contains "the database is of unknown type."
  assert_stderr_contains "Taking a native dump (pg_dump, mysqldump) is your job; this script does not run one"
}

@test "restore_hint for sqlite3 points at the dump zip alone" {
  run --separate-stderr in_script '
    FORGEJO_DB_TYPE=sqlite3
    BACKUP_DIR=/var/backups/forgejo
    restore_hint
  '
  assert_status 0
  assert_output_contains "restore the newest dump zip in /var/backups/forgejo (it contains the database)"
}

@test "restore_hint for postgres points at the native dump instead" {
  run --separate-stderr in_script '
    FORGEJO_DB_TYPE=postgres
    BACKUP_DIR=/var/backups/forgejo
    restore_hint
  '
  assert_status 0
  assert_output_contains "restore the database from the native dump you took before the upgrade"
  assert_output_contains "for SQLite the zip itself would contain the database"
}

@test "restore_hint for an unknown database type gives the same cautious wording as postgres" {
  run --separate-stderr in_script '
    FORGEJO_DB_TYPE=""
    BACKUP_DIR=/var/backups/forgejo
    restore_hint
  '
  assert_status 0
  assert_output_contains "restore the database from the native dump you took before the upgrade"
}
