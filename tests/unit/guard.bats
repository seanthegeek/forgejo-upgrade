#!/usr/bin/env bats
# The source guard and the usage text. The guard is what lets the whole suite
# source forgejo-upgrade.sh instead of extracting its definitions into a
# scratch copy, so if it breaks, every other file here tests nothing: sourcing
# must load every definition, print nothing, dispatch no command and exit 0.
# What runs above the guard still runs - WORKDIR is created and the traps are
# armed - and that is not what these tests check; on_exit.bats does. The
# usage half guards the AGENTS.md pairing "the header comment and the `sed`
# range that prints it": the range is read back out of the script rather than
# written here twice, so moving the end of the header without moving the range
# fails.
#
# `check` on a host with neither component installed belongs with the rest of
# that command, in check.bats.

# The single-quoted strings below are snippets handed to a child bash, and a
# regex matched against the script's own text; the "$0" in each has to survive
# unexpanded. That is exactly what SC2016 warns about, and exactly what is
# wanted here, so it is turned off for the file rather than repeated at every
# call.
# shellcheck disable=SC2016

# `run --separate-stderr` is a 1.5.0 feature; saying so here turns bats'
# BW02 warning into a version requirement it checks.
bats_require_minimum_version 1.5.0

# shellcheck source=tests/helpers.bash
setup() { load ../helpers; common_setup; }

@test "sourcing the script prints nothing and exits 0" {
  run --separate-stderr in_script ':'
  assert_status 0
  assert_equal "" "$output"
  assert_equal "" "$stderr"
}

@test "sourcing the script loads the definitions above the dispatch" {
  # A function from the top of the file and the last one defined before the
  # dispatch, `check`, so a guard placed anywhere above that last definition
  # would be caught as well as one that never returns. (An earlier version
  # checked rollback_command, which is defined near line 164 and proved
  # nothing about the bottom of the file.)
  run --separate-stderr in_script 'declare -F log check >/dev/null && echo loaded'
  assert_status 0
  assert_equal "loaded" "$output"
}

@test "a bogus subcommand prints the version, then the usage, and exits 1" {
  run --separate-stderr "$SCRIPT" bogus
  assert_status 1
  local version
  version=$(in_script 'printf "forgejo-upgrade %s\n" "$SCRIPT_VERSION"')
  assert_equal "$version"$'\n'"$(usage_range_text)" "$output"
  assert_output_contains "forgejo-upgrade.sh check"
}

@test "the sed range that prints the usage ends on the last header line" {
  local end
  end=$(usage_range_end)
  # The last line of the range is still a comment, and the line after it is
  # blank: the header ends exactly where the range does.
  assert_equal "#" "$(sed -n "${end}p" "$SCRIPT" | cut -c1)"
  assert_equal "" "$(sed -n "$((end + 1))p" "$SCRIPT")"
}

@test "no command runs when the script is sourced" {
  # The dispatch is reached with the arguments of the *sourcing* shell, so a
  # guard that did not return would run `check` here and hit the network.
  run --separate-stderr bash "$(snippet_file 'source "$0" check')"
  assert_status 0
  assert_equal "" "$output"
  assert_equal "" "$stderr"
}

# --- reading the range out of the script ---------------------------------------
#
# Both helpers below take the end of the range from the script's own dispatch
# line, so the range's end is written down in one place: the script.

usage_range_end() {
  local lineno line
  lineno=$(source_lines 'sed -n .2,[0-9]+p. "\$0"') || return 1
  line=$(sed -n "${lineno}p" "$SCRIPT")
  line=${line#*,}
  printf '%s\n' "${line%%p*}"
}

usage_range_text() {
  local end
  end=$(usage_range_end) || return 1
  sed -n "2,${end}p" "$SCRIPT"
}
