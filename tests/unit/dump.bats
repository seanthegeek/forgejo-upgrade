#!/usr/bin/env bats
# The forgejo dump archive's 0600 pre-creation (AGENTS.md, "`forgejo dump`
# creates the archive at the umask and only chmods it to 0600 on success").
# Forgejo opens the archive with a plain create, so its mode is whatever the
# umask allows until a dump that finishes chmods it to 0600 afterwards, and
# any fatal in between - or a Ctrl-C - leaves the partial file behind at that
# looser mode, holding app.ini and a copy of the database. This file checks
# the primitive the script relies on (a truncating write into a file already
# at 0600 keeps 0600) and, structurally, that the script actually creates the
# file in that spot: inside upgrade_forgejo, after its systemctl stop and
# immediately before the "as_forgejo dump --file" line. The dump itself is
# never run here - it needs a Forgejo install and a stopped service.

# Snippets handed to in_script are single-quoted on purpose: they must reach
# the child shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

# shellcheck source=tests/helpers.bash
setup() { load ../helpers; common_setup; }

@test "a truncating write into a file pre-created at mode 600 leaves it at mode 600" {
  run --separate-stderr in_script '
    d=$1
    umask 022
    install -m 600 /dev/null "$d/pre.zip"
    printf "archive-contents" > "$d/pre.zip"
    printf "mode=%s content=%s\n" "$(stat -c %a "$d/pre.zip")" "$(cat "$d/pre.zip")"
  ' "$BATS_TEST_TMPDIR"
  assert_status 0
  assert_output_contains "mode=600"
  assert_output_contains "content=archive-contents"
}

@test "control: the same write with no pre-creation gives mode 644 under umask 022" {
  run --separate-stderr in_script '
    d=$1
    umask 022
    printf "archive-contents" > "$d/ctl.zip"
    printf "mode=%s\n" "$(stat -c %a "$d/ctl.zip")"
  ' "$BATS_TEST_TMPDIR"
  assert_status 0
  assert_output_contains "mode=644"
}

@test "a python3 open(f, 'w') into the pre-created file also leaves it at mode 600" {
  skip_unless python3
  run --separate-stderr in_script '
    d=$1
    umask 022
    install -m 600 /dev/null "$d/pre-py.zip"
    python3 -c "open(\"$d/pre-py.zip\", \"w\").write(\"archive-contents\")"
    printf "mode=%s content=%s\n" "$(stat -c %a "$d/pre-py.zip")" "$(cat "$d/pre-py.zip")"
  ' "$BATS_TEST_TMPDIR"
  assert_status 0
  assert_output_contains "mode=600"
  assert_output_contains "content=archive-contents"
}

@test "install -m 600 /dev/null over an existing non-empty file truncates it and keeps mode 600" {
  run --separate-stderr in_script '
    f=$1/existing.zip
    printf "old-contents-that-are-longer-than-the-replacement" > "$f"
    install -m 600 /dev/null "$f"
    printf "mode=%s size=%s\n" "$(stat -c %a "$f")" "$(stat -c %s "$f")"
  ' "$BATS_TEST_TMPDIR"
  assert_status 0
  assert_output_contains "mode=600"
  assert_output_contains "size=0"
}

@test "the dump archive is pre-created after the stop and immediately before the dump" {
  local stop pre dmp pre_text die_text
  stop=$(source_lines '^  systemctl stop "\$FORGEJO_SERVICE"$')
  pre=$(source_lines 'run_as "\$FORGEJO_USER" install -m 600 /dev/null "\$dump"')
  dmp=$(source_lines 'as_forgejo dump --file "\$dump"')

  [[ $pre -gt $stop ]] \
    || { printf 'the pre-creation (line %s) does not come after systemctl stop (line %s)\n' "$pre" "$stop" >&2; return 1; }
  [[ $pre -lt $dmp ]] \
    || { printf 'the pre-creation (line %s) does not come before the dump (line %s)\n' "$pre" "$dmp" >&2; return 1; }

  # "Immediately before": the pre-creation line continues onto its "|| die",
  # and the dump is the very next command after that, with nothing else able
  # to run in between.
  pre_text=$(sed -n "${pre}p" "$SCRIPT")
  [[ $pre_text == *\\ ]] \
    || { printf 'the pre-creation line does not continue onto the next: %s\n' "$pre_text" >&2; return 1; }
  die_text=$(sed -n "$((pre + 1))p" "$SCRIPT")
  [[ $die_text == *'|| die '* ]] \
    || { printf 'the line after the pre-creation is not its || die: %s\n' "$die_text" >&2; return 1; }
  [[ $dmp -eq $((pre + 2)) ]] \
    || { printf 'the dump (line %s) is not the line immediately after the pre-creation'"'"'s || die (line %s)\n' "$dmp" "$((pre + 1))" >&2; return 1; }
}
