#!/usr/bin/env bats
# tests/verify-links.sh itself, offline. The checker had no bats coverage at
# all before this file, which Copilot's review of this branch flagged
# against AGENTS.md's "Every bullet ... has a test" spirit and, more
# specifically, "A new failure message gets its exact wording asserted, not
# just its presence" and "An ad hoc check that matches nothing is broken,
# not green." The LINKS_CACHE and LINKS_FILES overrides documented in the
# script's own header exist for exactly this file: they point the checker at
# an isolated cache directory and a small, offline markdown file instead of
# tmp/linkcache and the real README/AGENTS.md/script list, so the cache
# reuse, refetch-on-failure, and timeout paths run here rather than only
# against the internet via `make links`.

bats_require_minimum_version 1.5.0

setup() {
  load ../helpers
  common_setup
  ROOT=$(dirname "$SCRIPT")
  CHECKER=$ROOT/tests/verify-links.sh
  CACHE=$BATS_TEST_TMPDIR/cache
  LOG=$BATS_TEST_TMPDIR/curl.log
  : > "$LOG"
  export CURL_LOG=$LOG

  local bin=$BATS_TEST_TMPDIR/bin
  mkdir -p "$bin"
  # A stub curl standing in for the real network. It parses -o FILE out of
  # its own argv (the only flag verify-links.sh's fetch() reads back), logs
  # the URL it was asked for to $CURL_LOG so a test can count fetches, and
  # answers by the URL's last path segment:
  #   /ok      -> writes a small page with id="frag", prints 200, exits 0
  #   /missing -> prints 404, exits 0 (fetch() runs curl without -f)
  #   /slow    -> writes a partial body, prints 200, but exits 28 (curl's
  #               own CURLE_OPERATION_TIMEDOUT), so fetch() must not trust
  #               the 200 it already wrote to the .code file
  #   /down    -> prints 000, exits 7 (CURLE_COULDNT_CONNECT)
  cat > "$bin/curl" <<'STUB'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w|-A|--max-time) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
printf '%s\n' "$url" >> "$CURL_LOG"
case "$url" in
  */ok)
    [[ -n $out ]] && printf '<html><h2 id="frag">x</h2></html>' > "$out"
    printf '200'
    exit 0
    ;;
  */missing)
    printf '404'
    exit 0
    ;;
  */slow)
    [[ -n $out ]] && printf '<html>partial' > "$out"
    printf '200'
    exit 28
    ;;
  */down)
    printf '000'
    exit 7
    ;;
  *)
    printf '000'
    exit 1
    ;;
esac
STUB
  chmod +x "$bin/curl"
  stub_path "$bin"

  MD=$BATS_TEST_TMPDIR/links.md
  # example.test, not .example.com: verify-links.sh's own extraction skips
  # any URL containing ".example.com" as a placeholder, not a real link.
  cat > "$MD" <<'EOF'
https://example.test/ok#frag
https://example.test/ok#nope
https://example.test/missing
https://example.test/slow
https://example.test/down
EOF
}

# The same cache key verify-links.sh's own fetch() uses, so a test can look
# for the body file it would or would not have left behind.
cache_key() { printf '%s' "$1" | md5sum | cut -c1-32; }

run_checker() {
  LINKS_CACHE=$CACHE LINKS_FILES=$MD run --separate-stderr "$CHECKER"
}

@test "a 404, a fragment match, a fragment miss, and a timeout are each reported with their exact wording, and the run exits 1" {
  run_checker
  assert_status 1
  assert_output_contains "checking 5 distinct URLs"
  assert_output_contains "id present"
  assert_output_contains 'no element with id "nope"'
  assert_output_contains "HTTP 404"
  assert_output_contains "HTTP 000"
  assert_output_contains "ok=1 fail=4"
}

@test "a timed-out fetch leaves no body file in the cache, only the 000 .code file" {
  run_checker
  assert_status 1
  local key
  key=$CACHE/$(cache_key "https://example.test/slow")
  [[ -e "$key.code" ]] \
    || { printf 'expected %s.code to exist after the run\n' "$key" >&2; return 1; }
  [[ $(cat "$key.code") == 000 ]] \
    || { printf 'expected %s.code to hold 000, got: %s\n' "$key" "$(cat "$key.code")" >&2; return 1; }
  [[ ! -e $key ]] \
    || { printf '%s was left behind for a timed-out fetch\n' "$key" >&2; return 1; }
}

@test "a second run reuses the cached success and refetches every failure" {
  run_checker
  assert_status 1
  run_checker
  assert_status 1

  local ok_fetches
  ok_fetches=$(grep -Fxc "https://example.test/ok" "$LOG" || true)
  [[ $ok_fetches -eq 1 ]] \
    || { printf 'expected https://example.test/ok fetched once across both runs, got %s:\n%s\n' \
           "$ok_fetches" "$(cat "$LOG")" >&2; return 1; }

  local url
  for url in missing slow down; do
    local n
    n=$(grep -Fxc "https://example.test/$url" "$LOG" || true)
    [[ $n -eq 2 ]] \
      || { printf 'expected https://example.test/%s fetched twice across both runs, got %s:\n%s\n' \
             "$url" "$n" "$(cat "$LOG")" >&2; return 1; }
  done
}

@test "a file with no https:// URLs exits 99 with the extraction-broken message" {
  local empty=$BATS_TEST_TMPDIR/empty.md
  printf '# nothing to see here\n\nno links in this file.\n' > "$empty"
  LINKS_CACHE=$CACHE LINKS_FILES=$empty run --separate-stderr "$CHECKER"
  assert_status 99
  assert_output_contains "no URLs found: the extraction is broken"
}

@test "a file with only the good URL exits 0" {
  local good=$BATS_TEST_TMPDIR/good.md
  printf 'https://example.test/ok#frag\n' > "$good"
  LINKS_CACHE=$CACHE LINKS_FILES=$good run --separate-stderr "$CHECKER"
  assert_status 0
  assert_output_contains "ok=1 fail=0"
}
