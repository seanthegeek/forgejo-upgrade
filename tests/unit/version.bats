#!/usr/bin/env bats
# parse_forgejo_version, parse_runner_version, installed_forgejo and
# installed_runner. Guards the AGENTS.md "Facts about Forgejo release
# artifacts" bullets that the server binary prints a lowercase
# "forgejo version 16.0.5+gitea-..." even though third-party write-ups show it
# capitalized (the docs page on obtaining the version shows no string at
# all), and that the runner prints "forgejo-runner version
# v13.1.0" with a "v" the version number itself does not have; and the Shell
# style rule that "$FORGEJO_BIN --version 2>&1" is output capture, not
# suppression, so a failing or unparseable binary's own output ends up in the
# die message rather than being lost.

# Snippets handed to in_script are single-quoted on purpose: they must reach
# the child shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

# shellcheck source=tests/helpers.bash
setup() { load ../helpers; common_setup; }

# --- parse_forgejo_version ---------------------------------------------------

@test "parse_forgejo_version reads the real lowercase string" {
  run --separate-stderr in_script 'parse_forgejo_version "$1"' \
    'forgejo version 16.0.5+gitea-1.22.0 (release name 16.0.5)'
  assert_status 0
  assert_equal "16.0.5" "$output"
}

@test "parse_forgejo_version accepts the capitalized form write-ups show" {
  run --separate-stderr in_script 'parse_forgejo_version "$1"' \
    'Forgejo version 16.0.5+gitea-1.22.0 (release name 16.0.5)'
  assert_status 0
  assert_equal "16.0.5" "$output"
}

@test "parse_forgejo_version gives nothing for text that is not a version line" {
  run --separate-stderr in_script 'parse_forgejo_version "$1"' \
    'bash: /usr/local/bin/forgejo: cannot execute binary file'
  assert_status 0
  assert_equal "" "$output"
}

# --- parse_runner_version ----------------------------------------------------

@test "parse_runner_version reads the real v-prefixed string" {
  run --separate-stderr in_script 'parse_runner_version "$1"' \
    'forgejo-runner version v13.1.0'
  assert_status 0
  assert_equal "13.1.0" "$output"
}

@test "parse_runner_version also accepts the number with no v, per its v{0,1} pattern" {
  run --separate-stderr in_script 'parse_runner_version "$1"' \
    'forgejo-runner version 13.1.0'
  assert_status 0
  assert_equal "13.1.0" "$output"
}

@test "parse_runner_version gives nothing for text that is not a version line" {
  run --separate-stderr in_script 'parse_runner_version "$1"' \
    'exec format error'
  assert_status 0
  assert_equal "" "$output"
}

# --- installed_forgejo -------------------------------------------------------

@test "installed_forgejo prints the version a real-shaped binary reports" {
  fake_bin "$TMPDIR/bin/forgejo" \
    'forgejo version 16.0.5+gitea-1.22.0 (release name 16.0.5)'
  FORGEJO_BIN="$TMPDIR/bin/forgejo" run --separate-stderr in_script 'installed_forgejo'
  assert_status 0
  assert_equal "16.0.5" "$output"
}

@test "installed_forgejo prints none when FORGEJO_BIN is not executable" {
  FORGEJO_BIN="$TMPDIR/no-such-binary" run --separate-stderr in_script 'installed_forgejo'
  assert_status 0
  assert_equal "none" "$output"
}

@test "installed_forgejo dies showing the binary's own output when it exits non-zero" {
  fake_bin "$TMPDIR/bin/forgejo" 'boom: cannot execute' 1
  FORGEJO_BIN="$TMPDIR/bin/forgejo" run --separate-stderr in_script 'installed_forgejo'
  assert_status 1
  assert_stderr_contains "$TMPDIR/bin/forgejo --version failed (exit 1)"
  assert_stderr_contains "boom: cannot execute"
  assert_stderr_contains "may be corrupt"
}

@test "installed_forgejo dies naming the unparseable output when the binary exits 0 with no version" {
  fake_bin "$TMPDIR/bin/forgejo" 'this is not a version string'
  FORGEJO_BIN="$TMPDIR/bin/forgejo" run --separate-stderr in_script 'installed_forgejo'
  assert_status 1
  assert_stderr_contains "could not read a version from '$TMPDIR/bin/forgejo --version'"
  assert_stderr_contains "this is not a version string"
}

# --- installed_runner --------------------------------------------------------

@test "installed_runner prints the version a real-shaped binary reports" {
  fake_bin "$TMPDIR/bin/forgejo-runner" 'forgejo-runner version v13.1.0'
  RUNNER_BIN="$TMPDIR/bin/forgejo-runner" run --separate-stderr in_script 'installed_runner'
  assert_status 0
  assert_equal "13.1.0" "$output"
}

@test "installed_runner prints none when RUNNER_BIN is not executable" {
  RUNNER_BIN="$TMPDIR/no-such-binary" run --separate-stderr in_script 'installed_runner'
  assert_status 0
  assert_equal "none" "$output"
}

@test "installed_runner dies showing the binary's own output when it exits non-zero" {
  fake_bin "$TMPDIR/bin/forgejo-runner" 'boom: exec format error' 1
  RUNNER_BIN="$TMPDIR/bin/forgejo-runner" run --separate-stderr in_script 'installed_runner'
  assert_status 1
  assert_stderr_contains "$TMPDIR/bin/forgejo-runner --version failed (exit 1)"
  assert_stderr_contains "boom: exec format error"
  assert_stderr_contains "may be corrupt"
}

@test "installed_runner dies naming the unparseable output when the binary exits 0 with no version" {
  fake_bin "$TMPDIR/bin/forgejo-runner" 'nothing version-shaped here'
  RUNNER_BIN="$TMPDIR/bin/forgejo-runner" run --separate-stderr in_script 'installed_runner'
  assert_status 1
  assert_stderr_contains "could not read a version from '$TMPDIR/bin/forgejo-runner --version'"
  assert_stderr_contains "nothing version-shaped here"
}
