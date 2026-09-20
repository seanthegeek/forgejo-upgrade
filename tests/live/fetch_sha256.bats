#!/usr/bin/env bats
# fetch_sha256 against the live release server, called on its own rather than
# through fetch_and_verify. It is the one curl call in the script that runs
# without -f and reads the HTTP status itself, so the two answers that decide
# an upgrade have to be told apart for real: a 404, which means this release
# published no checksum and the upgrade carries on with the GPG signature
# alone, and a transport failure, which stops the upgrade. The 500-and-other
# statuses half is in tests/unit/fetch_sha256.bats, against a curl stub.
# This file needs the network; it fetches nothing larger than an error page.

# Snippets handed to in_script are single-quoted on purpose: they must reach
# the child shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

# One small API call for the whole file: the 404 is asked for under a real
# release path with the filename changed, so the host, the path and the TLS
# are all real and only the file is missing.
setup_file() {
  load ../helpers
  SCRIPT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/forgejo-upgrade.sh
  export SCRIPT
  export TMPDIR=$BATS_FILE_TMPDIR
  local ver
  ver=$(in_script 'latest_tag "$RUNNER_REPO"')
  if [[ ! $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'setup_file: latest_tag gave no usable runner version: %s\n' "$ver" >&2
    return 1
  fi
  printf '%s\n' "$ver" > "$BATS_FILE_TMPDIR/ver"
}

# shellcheck source=tests/helpers.bash
setup() {
  load ../helpers
  common_setup
  VER=$(cat "$BATS_FILE_TMPDIR/ver")
}

@test "a .sha256 that is not published is reported as a 404 and leaves no file behind" {
  # Without -f, curl writes the server's error page into the output file, so
  # the 404 branch has to take it away again: a leftover HTML page at that
  # path would be handed to sha256sum -c by a later caller.
  local url=https://code.forgejo.org/forgejo/runner/releases/download/v$VER/forgejo-runner-$VER-linux-amd64.nope.sha256
  local out=$BATS_TEST_TMPDIR/nope.sha256
  run --separate-stderr in_script '
    rc=0
    fetch_sha256 "$1" "$2" || rc=$?
    printf "rc=%s\n" "$rc"
    if [[ -e $2 ]]; then printf "file-left=%s\n" "$(wc -c <"$2")"; else echo no-file; fi
  ' "$url" "$out"
  assert_status 0
  assert_output_contains "rc=1"
  assert_output_contains "no-file"
  # A 404 is a normal answer here, not an error: nothing is said about it at
  # this level.
  refute_stderr_contains "ERROR:"
  if [[ -e $out ]]; then
    printf 'the error page was left behind at %s\n' "$out" >&2
    return 1
  fi
}

@test "the warning that a release has no .sha256 is the caller's, and still says so" {
  # fetch_sha256 itself returns 1 and stays quiet; the "not published" wording
  # the operator reads lives in fetch_and_verify's else branch, which cannot be
  # reached without a release that publishes no checksum. This is the other
  # half of that contract, checked where it is written. source_lines fails
  # loudly when it matches nothing.
  local hits
  hits=$(source_lines 'no \.sha256 published for .* \(HTTP 404\); relying on the GPG signature only')
  echo "# the warning is at line(s): $hits" >&3
}

@test "a host that does not resolve stops the upgrade with the transport-error message" {
  # The distinction this function exists for: a DNS failure, a TLS error or a
  # timeout must never pass for "this release has no checksum".
  run --separate-stderr in_script \
    'fetch_sha256 https://no-such-host.invalid/x.sha256 "$1"' "$BATS_TEST_TMPDIR/b.sha256"
  assert_status 1
  assert_stderr_contains "could not download https://no-such-host.invalid/x.sha256 (curl exit"
  assert_stderr_contains "Expected either the release's .sha256 file or a 404 saying there is none"
  assert_stderr_contains "check this host's network access to code.forgejo.org and rerun"
}
