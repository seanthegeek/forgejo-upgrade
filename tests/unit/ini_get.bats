#!/usr/bin/env bats
# ini_get, the sed-based app.ini reader. Guards two AGENTS.md "Facts" bullets:
# that a duplicated key uses the last assignment, not the first (go-ini's
# Section.NewKey, no AllowShadows), including that an empty last assignment
# reads as unset the same way Forgejo's own configWorkPath != "" check does;
# and the whole %(NAME)s interpolation bullet (go-ini's Key.transformValue),
# including the two-key cycle that has to terminate and the "&" case that
# proves the replacement is quoted against bash's patsub_replacement.

# Snippets handed to in_script are single-quoted on purpose: they must reach
# the child shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

# shellcheck source=tests/helpers.bash
setup() { load ../helpers; common_setup; }

# --- duplicate keys -----------------------------------------------------------

@test "ini_get returns the last of two duplicate assignments before the first section" {
  run --separate-stderr in_script 'ini_get "$1" "" WORK_PATH' "$FIXTURES/ini/dup.ini"
  assert_status 0
  assert_equal "/b" "$output"
}

@test "ini_get returns the last of two duplicate assignments inside a section" {
  run --separate-stderr in_script 'ini_get "$1" server HTTP_PORT' "$FIXTURES/ini/dup.ini"
  assert_status 0
  assert_equal "3001" "$output"
}

@test "ini_get returns nothing for a key that exists only in another section" {
  run --separate-stderr in_script 'ini_get "$1" "" HTTP_PORT' "$FIXTURES/ini/dup.ini"
  assert_status 0
  assert_equal "" "$output"
  run --separate-stderr in_script 'ini_get "$1" server WORK_PATH' "$FIXTURES/ini/dup.ini"
  assert_status 0
  assert_equal "" "$output"
}

@test "a third, empty assignment reads as unset, the same as Forgejo's configWorkPath check" {
  run --separate-stderr in_script 'ini_get "$1" "" WORK_PATH' "$FIXTURES/ini/dup-empty.ini"
  assert_status 0
  assert_equal "" "$output"
}

# --- %(NAME)s interpolation, against interp.ini -------------------------------

@test "LOCAL_ROOT_URL assembles from PROTOCOL, HTTP_ADDR and HTTP_PORT" {
  run --separate-stderr in_script 'ini_get "$1" server LOCAL_ROOT_URL' "$FIXTURES/ini/interp.ini"
  assert_status 0
  assert_equal "http://127.0.0.1:3000/" "$output"
}

@test "a reference to a name that is nowhere at all stays literal" {
  run --separate-stderr in_script 'ini_get "$1" server MISSING_REF' "$FIXTURES/ini/interp.ini"
  assert_status 0
  assert_equal "%(NOSUCHKEY)s/tail" "$output"
}

@test "a name only in the keys before the first section resolves from there" {
  run --separate-stderr in_script 'ini_get "$1" server FROM_TOP' "$FIXTURES/ini/interp.ini"
  assert_status 0
  assert_equal "[toptext]" "$output"
}

@test "a self-reference in [server] falls to the default section's key of the same name" {
  run --separate-stderr in_script 'ini_get "$1" server X' "$FIXTURES/ini/interp.ini"
  assert_status 0
  assert_equal "top" "$output"
}

@test "nested references resolve through every hop" {
  run --separate-stderr in_script 'ini_get "$1" server A' "$FIXTURES/ini/interp.ini"
  assert_status 0
  assert_equal "z" "$output"
}

@test "the two-key cycle terminates instead of hanging" {
  # timeout 20 is the proof that matters here: a hang would be a test that
  # never finishes rather than one that fails fast.
  run --separate-stderr timeout 20 \
    bash "$(snippet_file 'source "$0"; ini_get "$1" server CYCLE1')" "$FIXTURES/ini/interp.ini"
  assert_status 0
  assert_output_contains "%("
}

@test "plain text with no references is unchanged" {
  run --separate-stderr in_script 'ini_get "$1" server PLAIN' "$FIXTURES/ini/interp.ini"
  assert_status 0
  assert_equal "just text" "$output"
}

@test "a lone % with no %(NAME)s in it is unchanged" {
  run --separate-stderr in_script 'ini_get "$1" server PERCENT' "$FIXTURES/ini/interp.ini"
  assert_status 0
  assert_equal "100% done" "$output"
}

@test "a reference whose name has a dot is left exactly as written" {
  run --separate-stderr in_script 'ini_get "$1" server DOTTED' "$FIXTURES/ini/interp.ini"
  assert_status 0
  assert_equal "%(a.b)s stays" "$output"
}

@test "a value with spaces, a backslash and glob characters comes back intact" {
  run --separate-stderr in_script 'ini_get "$1" server USE_SPACED' "$FIXTURES/ini/interp.ini"
  assert_status 0
  assert_equal '[a b\c *?]' "$output"
}

@test "WORK_PATH in the default section expands a reference to another default-section key" {
  run --separate-stderr in_script 'ini_get "$1" "" WORK_PATH' "$FIXTURES/ini/interp.ini"
  assert_status 0
  assert_equal "/srv/data" "$output"
}

# --- the "&" case, against amp.ini --------------------------------------------

@test "a referenced value containing & comes back intact, not re-expanded" {
  # Unquoted, bash's patsub_replacement (on by default since 5.2) would turn
  # the & in the replacement back into the matched %(HTTP_ADDR)s reference.
  run --separate-stderr in_script 'ini_get "$1" server LOCAL_ROOT_URL' "$FIXTURES/ini/amp.ini"
  assert_status 0
  assert_equal "http://unix/run/a&b/forgejo.sock/" "$output"
}
