#!/usr/bin/env bats
# fetch_sha256, offline half (AGENTS.md, "fetch_sha256 runs curl without -f
# and reads the HTTP status itself; only a 404 is treated as 'not published'
# ... A transport error or any other status stops the upgrade. There is no
# 2>/dev/null here."). Every curl call here goes through a stub fixture,
# never the network; the real 404 and unresolvable-host cases live in
# tests/live.

# Snippets handed to in_script are single-quoted on purpose: they must reach
# the child shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

# shellcheck source=tests/helpers.bash
setup() { load ../helpers; common_setup; }

@test "fetch_sha256 dies naming the HTTP status on a 500" {
  stub_path "$FIXTURES/curl/500"
  run --separate-stderr in_script 'fetch_sha256 "$1" "$2"' \
    "http://example.test/f.sha256" "$BATS_TEST_TMPDIR/out.sha256"
  assert_status 1
  assert_stderr_contains "unexpected HTTP 500 fetching http://example.test/f.sha256"
  assert_stderr_contains "the server answered: '<html>500 Internal Server Error</html>'"
}

@test "fetch_sha256 dies with the transport-error message when curl cannot connect" {
  stub_path "$FIXTURES/curl/refused"
  run --separate-stderr in_script 'fetch_sha256 "$1" "$2"' \
    "http://example.test/f.sha256" "$BATS_TEST_TMPDIR/out.sha256"
  assert_status 1
  assert_stderr_contains "could not download http://example.test/f.sha256 (curl exit 7)"
}

@test "fetch_sha256 returns 1 and leaves no file behind on a 404" {
  # fetch_sha256 itself only returns 1 here; the "not published" wording that
  # AGENTS.md quotes is printed by its caller, fetch_and_verify (around the
  # "warn ... relying on the GPG signature only" line), not by this function -
  # confirmed by reading fetch_sha256's own source, which has no warn call at
  # all. So this test checks the function's own contract: 1, and no leftover
  # file, not the wording of a message it never prints.
  local out=$BATS_TEST_TMPDIR/out.sha256
  stub_path "$FIXTURES/curl/404"
  run --separate-stderr in_script 'fetch_sha256 "$1" "$2"' \
    "http://example.test/f.sha256" "$out"
  assert_status 1
  [[ ! -e $out ]] \
    || { printf '%s was left behind after a 404, holding: %s\n' "$out" "$(cat "$out")" >&2; return 1; }
}

@test "fetch_sha256 returns 0 on a 200" {
  stub_path "$FIXTURES/curl/200"
  run --separate-stderr in_script 'fetch_sha256 "$1" "$2"' \
    "http://example.test/f.sha256" "$BATS_TEST_TMPDIR/out.sha256"
  assert_status 0
}
