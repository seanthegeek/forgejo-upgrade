#!/usr/bin/env bats
# latest_tag against the live code.forgejo.org release API, for both repos, and
# `check` on this host. latest_tag reads tag_name out of the JSON with sed
# because the script is allowed no new dependency such as jq, so the shape of
# the answer is something only a live call can confirm. `check` is the only
# subcommand safe to run on a development machine: it reads, it never takes the
# lock, and on a host with neither component installed it asks the release API
# nothing at all. This file needs the network.

# Snippets handed to in_script are single-quoted on purpose: they must reach
# the child shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

# shellcheck source=tests/helpers.bash
setup() { load ../helpers; common_setup; }

@test "latest_tag prints one bare version for the Forgejo repo" {
  run --separate-stderr in_script 'latest_tag "$FORGEJO_REPO"'
  assert_status 0
  echo "# latest Forgejo release: $output" >&3
  assert_equal "1" "${#lines[@]}"
  # A bare N.N.N: the "v" the tag carries is stripped by the sed, because the
  # rest of the script compares this against what the binary prints.
  if [[ ! $output =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'expected a bare N.N.N version, got: %s\n' "$output" >&2
    return 1
  fi
}

@test "latest_tag prints one bare version for the runner repo" {
  run --separate-stderr in_script 'latest_tag "$RUNNER_REPO"'
  assert_status 0
  echo "# latest forgejo-runner release: $output" >&3
  assert_equal "1" "${#lines[@]}"
  if [[ ! $output =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'expected a bare N.N.N version, got: %s\n' "$output" >&2
    return 1
  fi
}

@test "check on a host with neither component installed says so and exits 0" {
  # No in_script here: this is the real subcommand, run the way an operator
  # runs it. With no unit and no binary at either documented path, both
  # components are absent and neither release API is asked about - a Forgejo host with no runner must not have check fail
  # because the runner's releases could not be fetched.
  # The nounits systemctl knows no unit, so the components are absent whatever
  # the host running the suite has installed.
  stub_path "$FIXTURES/nounits"
  run --separate-stderr "$SCRIPT" check
  assert_status 0
  assert_output_contains "component        installed    latest"
  assert_output_contains "forgejo          not installed -"
  assert_output_contains "forgejo-runner   not installed -"
  assert_output_contains "Security announcements: https://codeberg.org/forgejo/security-announcements/issues"
  # An absent component is reported once, in the table, and not warned about.
  refute_stderr_contains "WARN:"
  refute_stderr_contains "ERROR:"
}

@test "check asks the release API for a component that is installed, and exits 0" {
  # The two tests above call latest_tag directly, and the one below runs check
  # on a host where nothing is installed and nothing is asked. This is the
  # case in between, and the only one that proves `check` itself reaches the
  # API: the nounits systemctl knows no unit, so naming FORGEJO_BIN is what
  # says Forgejo is here (AGENTS.md, "Neither component is assumed present":
  # the operator setting the binary variable counts as present). The runner is
  # left unnamed, so it stays absent and its releases are not fetched.
  stub_path "$FIXTURES/nounits"
  local bin=$BATS_TEST_TMPDIR/forgejo
  fake_bin "$bin" 'forgejo version 16.0.5+gitea-1.22.0 (release name 16.0.5)'
  FORGEJO_BIN=$bin run --separate-stderr "$SCRIPT" check
  assert_status 0
  assert_output_contains "component        installed    latest"
  local row
  row=$(printf '%s\n' "$output" | grep '^forgejo  ')
  echo "# $row" >&3
  # The installed column is what the fake binary printed, parsed; the latest
  # column is whatever the API answered today, so only its shape can be
  # asserted - a bare N.N.N, never the dash an absent component gets.
  if [[ ! $row =~ ^forgejo[[:space:]]+16\.0\.5[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$ ]]; then
    printf 'expected "forgejo 16.0.5 <N.N.N>" in the table, got: %s\n' "$row" >&2
    return 1
  fi
  assert_output_contains "forgejo-runner   not installed -"
  # --quiet is passed to both resolvers, so an installed component is reported
  # in the table and nowhere else.
  assert_equal "" "$stderr"
}
