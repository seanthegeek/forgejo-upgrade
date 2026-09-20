#!/usr/bin/env bats
# healthz and wait_forgejo_healthy (AGENTS.md, "A health check must require
# exactly HTTP 200": curl's -f treats any 2xx or 3xx as success, and a reverse
# proxy in front of a stopped Forgejo can answer a redirect while Forgejo
# itself is down) and "curl reads root's ~/.curlrc unless -q is its first
# argument" (every curl call in the script has to pass -q first). All offline:
# every curl call here goes through a stub fixture on PATH, never the
# network. The real .curlrc-plus-redirect case lives in tests/live.

# Snippets handed to in_script are single-quoted on purpose: they must reach
# the child shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

# shellcheck source=tests/helpers.bash
setup() {
  load ../helpers
  common_setup
  export FORGEJO_URL=http://127.0.0.1:1
}

@test "healthz passes on a 200" {
  stub_path "$FIXTURES/curl/200"
  run --separate-stderr in_script 'healthz'
  assert_status 0
}

@test "healthz fails on a 302, since a reverse proxy can redirect to a login page while Forgejo is down" {
  stub_path "$FIXTURES/curl/302"
  run --separate-stderr in_script 'healthz'
  [[ $status -ne 0 ]] \
    || { printf 'expected a non-zero status for a 302, got 0\n' >&2; return 1; }
}

@test "healthz fails when the connection is refused, as while the service is still starting" {
  stub_path "$FIXTURES/curl/refused"
  run --separate-stderr in_script 'healthz'
  [[ $status -ne 0 ]] \
    || { printf 'expected a non-zero status for a refused connection, got 0\n' >&2; return 1; }
}

@test "healthz fails when curl itself fails outright" {
  stub_path "$FIXTURES/curl/fail"
  run --separate-stderr in_script 'healthz'
  [[ $status -ne 0 ]] \
    || { printf 'expected a non-zero status when curl fails, got 0\n' >&2; return 1; }
}

@test "healthz adds --unix-socket, with -q still first, when FORGEJO_SOCKET is set" {
  local bin=$BATS_TEST_TMPDIR/argvbin log=$BATS_TEST_TMPDIR/argv.log
  mkdir -p "$bin"
  cat > "$bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_ARGV_LOG"
printf '200'
STUB
  chmod +x "$bin/curl"
  stub_path "$bin"
  CURL_ARGV_LOG=$log FORGEJO_SOCKET=/tmp/forgejo-upgrade-test.sock \
    run --separate-stderr in_script 'healthz'
  assert_status 0
  local argv; argv=$(cat "$log")
  [[ $argv == -q\ * ]] \
    || { printf 'expected -q as the first curl argument, got: %s\n' "$argv" >&2; return 1; }
  [[ $argv == *"--unix-socket /tmp/forgejo-upgrade-test.sock"* ]] \
    || { printf 'expected --unix-socket in the argv: %s\n' "$argv" >&2; return 1; }
  [[ $argv == *"--max-time"* ]] \
    || { printf 'expected --max-time in the argv: %s\n' "$argv" >&2; return 1; }
  [[ $argv == *"-o /dev/null"* ]] \
    || { printf 'expected -o /dev/null in the argv: %s\n' "$argv" >&2; return 1; }
}

@test "healthz has no --unix-socket when FORGEJO_SOCKET is unset" {
  local bin=$BATS_TEST_TMPDIR/argvbin log=$BATS_TEST_TMPDIR/argv.log
  mkdir -p "$bin"
  cat > "$bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_ARGV_LOG"
printf '200'
STUB
  chmod +x "$bin/curl"
  stub_path "$bin"
  CURL_ARGV_LOG=$log run --separate-stderr in_script 'healthz'
  assert_status 0
  local argv; argv=$(cat "$log")
  [[ $argv != *"--unix-socket"* ]] \
    || { printf 'did not expect --unix-socket without FORGEJO_SOCKET: %s\n' "$argv" >&2; return 1; }
}

@test "every curl call in the script has -q as its first argument" {
  # The regex looks for a curl call however it is written - at the start of a
  # line or inside a $( ) - and not for "curl -q", which would only ever find
  # the calls that already pass it and would go green on the day someone adds
  # one that does not.
  local -a numbers=()
  mapfile -t numbers < <(source_lines '(^|\$\()[[:space:]]*curl[[:space:]]')
  if [[ ${#numbers[@]} -eq 0 ]]; then
    printf 'no curl calls found in %s; this check is broken, not green\n' "$SCRIPT" >&2
    return 1
  fi
  local n line rest checked=0
  for n in "${numbers[@]}"; do
    line=$(sed -n "${n}p" "$SCRIPT")
    rest=${line#*curl }
    case $rest in
      '-q '*) checked=$(( checked + 1 )) ;;
      # healthz builds its options in an array, so -q has to be first in the
      # array instead; the declaration is checked in its own right.
      '"${opts[@]}"'*)
        source_lines 'local -a opts=\(-q ' >/dev/null
        checked=$(( checked + 1 )) ;;
      *)
        printf 'line %s calls curl without -q first, so it would read root/.curlrc: %s\n' \
          "$n" "$line" >&2
        return 1 ;;
    esac
  done
  echo "# curl calls audited: $checked (lines ${numbers[*]})" >&3
}

@test "wait_forgejo_healthy is driven by the clock, not by a count of attempts" {
  # A real run of the failure path waits up to 60s for a stub that never
  # answers 200 before it dies, which is correct behaviour but too slow to
  # spend on every test run, and the function has no variable to shrink that
  # limit. So this is a structural check, not a timed one: it confirms the
  # loop bounds itself by comparing SECONDS against a deadline rather than by
  # counting attempts. The 60s wall-clock limit and its die wording are
  # reviewed by reading the function (AGENTS.md, "Service orchestration, not
  # testable here" is the closest analogue for this one).
  source_lines 'left=\$\(\( limit - \(SECONDS - start\) \)\)' >/dev/null
}
