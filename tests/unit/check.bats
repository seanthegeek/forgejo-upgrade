#!/usr/bin/env bats
# `check`, with neither component installed. Guards the AGENTS.md
# "Neither component is assumed present" rule ("Read-only commands (settings,
# check) say 'not installed' once for a component that is absent, and must
# not warn about it or ask the release API for its latest version") and the
# comment in `check` itself: fl/rl are captured before printf so a dead API
# cannot silently print blank columns and exit 0.
#
# The systemctl on PATH is tests/fixtures/nounits/systemctl, which answers
# "not-found" for every unit: the shared tests/fixtures/bin/systemctl answers
# "loaded" for the stock forgejo/forgejo-runner units, which is the wrong
# shape for a "nothing installed" test.

# Snippets handed to in_script are single-quoted on purpose: they must reach
# the child shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

# shellcheck source=tests/helpers.bash
setup() { load ../helpers; common_setup; }

@test "check reports both components not installed, with '-' for latest, and exits 0" {
  stub_path "$FIXTURES/nounits"
  stub_path "$FIXTURES/curl/tripwire"
  run --separate-stderr "$SCRIPT" check
  assert_status 0
  assert_output_contains "forgejo          not installed -"
  assert_output_contains "forgejo-runner   not installed -"
}

@test "check never calls the release API for a component that is not installed" {
  # The tripwire curl stub prints CURL-WAS-CALLED if it is ever invoked, on
  # whichever stream curl itself would write to; check must show neither.
  stub_path "$FIXTURES/nounits"
  stub_path "$FIXTURES/curl/tripwire"
  run --separate-stderr "$SCRIPT" check
  assert_status 0
  refute_output_contains "CURL-WAS-CALLED"
  refute_stderr_contains "CURL-WAS-CALLED"
}

@test "check prints the header line and the security-announcements pointer, and nothing else on stderr" {
  stub_path "$FIXTURES/nounits"
  stub_path "$FIXTURES/curl/tripwire"
  run --separate-stderr "$SCRIPT" check
  assert_status 0
  assert_output_contains "component        installed    latest"
  assert_output_contains "Security announcements: https://codeberg.org/forgejo/security-announcements/issues"
  # --quiet is passed to both resolvers, so neither the "not installed" log
  # line nor any warning should reach stderr.
  assert_equal "" "$stderr"
}
