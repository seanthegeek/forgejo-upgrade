#!/usr/bin/env bats
# healthz against a live redirect, with a .curlrc that says "location". curl
# reads root's ~/.curlrc unless -q is its first argument, and the script runs as
# root: a .curlrc saying "location" would turn a reverse proxy's 302 to a login
# page into that page's 200 and report a stopped Forgejo as healthy. The live
# half points healthz at http://codeberg.org, which really answers a 302 to
# https, and proves the same .curlrc does change plain curl's answer, so the
# test cannot pass by the redirect having gone away. The source audit of the
# same fact - every curl call in the script starts with -q - needs no network
# and lives in tests/unit/healthz.bats.
# This file needs the network.

# Snippets handed to in_script are single-quoted on purpose: they must reach
# the child shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

# shellcheck source=tests/helpers.bash
setup() { load ../helpers; common_setup; }

@test "healthz fails on a real 302 although the .curlrc in CURL_HOME says location" {
  local followed direct
  # The control first: this same .curlrc, with curl invoked the way healthz
  # invokes it but without the -q, follows the redirect and reports the 200
  # that healthz must not report.
  followed=$(CURL_HOME=$FIXTURES/curlrc \
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://codeberg.org/api/healthz)
  direct=$(curl -q -s -o /dev/null -w '%{http_code}' --max-time 15 http://codeberg.org/api/healthz)
  echo "# http://codeberg.org/api/healthz answers $direct; under that .curlrc plain curl reports $followed" >&3
  if [[ $direct != 3?? || $followed != 200 ]]; then
    printf 'the premise no longer holds: expected a 3xx direct (got "%s") that the .curlrc turns into 200 (got "%s"). Re-check the fact before trusting this test.\n' \
      "$direct" "$followed" >&2
    return 1
  fi

  CURL_HOME=$FIXTURES/curlrc FORGEJO_URL=http://codeberg.org \
    run --separate-stderr in_script 'healthz 15'
  if [[ $status -eq 0 ]]; then
    printf 'healthz followed the redirect and called a %s healthy\n' "$direct" >&2
    return 1
  fi
}

@test "healthz passes when the answer really is 200" {
  # The positive control for the test above: without it, a healthz that fails
  # for some unrelated reason would look like the redirect being refused.
  stub_path "$FIXTURES/curl/200"
  FORGEJO_URL=http://forgejo.invalid run --separate-stderr in_script 'healthz'
  assert_status 0
}
