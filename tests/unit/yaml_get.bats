#!/usr/bin/env bats
# yaml_get, the sed-based reader for one line of the runner config. AGENTS.md
# is explicit that this "is not a YAML parser and must not be used as one" -
# these tests hold it to exactly the shape it claims to read: a key indented
# under a top-level key, per the "runner.file" fact (the registration file
# named there is resolved against the daemon's working directory, not this
# function's business, but yaml_get is what hands that name back).

# Snippets handed to in_script are single-quoted on purpose: they must reach
# the child shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

# shellcheck source=tests/helpers.bash
setup() { load ../helpers; common_setup; }

@test "yaml_get reads runner.file from the fixture runner config" {
  run --separate-stderr in_script 'yaml_get "$1" runner file' "$FIXTURES/runner.yml"
  assert_status 0
  assert_equal ".runner" "$output"
}

@test "yaml_get reads another key under the same top-level key" {
  run --separate-stderr in_script 'yaml_get "$1" runner capacity' "$FIXTURES/runner.yml"
  assert_status 0
  assert_equal "1" "$output"
}

@test "yaml_get gives empty output, exit 0, for a key that is not under that top-level key" {
  run --separate-stderr in_script 'yaml_get "$1" runner level' "$FIXTURES/runner.yml"
  assert_status 0
  assert_equal "" "$output"
}

@test "yaml_get does not return a key that only exists under a different top-level key" {
  # "level" is under "log:", not "runner:".
  run --separate-stderr in_script 'yaml_get "$1" log foo' "$FIXTURES/runner.yml"
  assert_status 0
  assert_equal "" "$output"
  run --separate-stderr in_script 'yaml_get "$1" runner level' "$FIXTURES/runner.yml"
  assert_status 0
  assert_equal "" "$output"
}

@test "yaml_get gives empty output, exit 0, for a top-level key that is not in the file at all" {
  run --separate-stderr in_script 'yaml_get "$1" nosuchsection file' "$FIXTURES/runner.yml"
  assert_status 0
  assert_equal "" "$output"
}

@test "yaml_get strips a trailing comment and surrounding quotes, the same way ini_get does" {
  local yaml=$TMPDIR/quoted.yml
  cat > "$yaml" <<'YAML'
runner:
  file: ".runner"  # where the registration lives
  capacity: 1
YAML
  run --separate-stderr in_script 'yaml_get "$1" runner file' "$yaml"
  assert_status 0
  assert_equal ".runner" "$output"
}

@test "yaml_get reads a real registration file's name that exists on disk" {
  run --separate-stderr in_script '
    home=$1
    reg=$(yaml_get "$2" runner file)
    [[ -f $home/$reg ]] && echo "reg-file-exists: $reg"
  ' "$FIXTURES/runnerhome" "$FIXTURES/runner.yml"
  assert_status 0
  assert_output_contains "reg-file-exists: .runner"
}
