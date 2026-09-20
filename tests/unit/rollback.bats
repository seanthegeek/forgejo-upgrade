#!/usr/bin/env bats
# rollback_needs_manual_start, and the structural guarantees inside rollback()
# that back it (AGENTS.md, "An older Forgejo binary refuses to start on a
# database a newer release migrated" and "rollback_needs_manual_start,
# exercised directly from the sourced definitions"). require_prev_slot has to
# run before the "-x $bin.prev" check and before systemctl stop, because a
# symlink at .prev would pass a bare -x test and the later "mv -fT" would then
# put the link itself in front of the service rather than the binary an
# upgrade set aside; BINARY_REPLACED=2 has to be set before the mv that
# consumes .prev, so a Ctrl-C landing between them is still reported
# correctly by on_exit; and the directory-at-$bin refusal has to run before
# anything is stopped. rollback itself is never run here (AGENTS.md: this
# machine does not run Forgejo, and never runs rollback), so everything below
# either calls the one pure function directly or inspects line numbers.

# Snippets handed to in_script are single-quoted on purpose: they must reach
# the child shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

# shellcheck source=tests/helpers.bash
setup() { load ../helpers; common_setup; }

# Prints the line number of the first top-level function definition strictly
# after line $1, or nothing when there is none. Used to bound "is this line
# really inside function X" checks without a new dependency.
_first_function_after() {
  local after=$1 n
  while read -r n; do
    if (( n > after )); then
      printf '%s\n' "$n"
      return 0
    fi
  done < <(source_lines '^[a-zA-Z_]+\(\) \{')
}

@test "rollback_needs_manual_start: a major version change with a readable previous version needs a manual start" {
  run --separate-stderr in_script 'rollback_needs_manual_start forgejo 16.0.5 15.2.0'
  assert_status 0
}

@test "rollback_needs_manual_start: an unreadable previous version counts as differing, so it also needs a manual start" {
  run --separate-stderr in_script 'rollback_needs_manual_start forgejo 16.0.5 ""'
  assert_status 0
}

@test "rollback_needs_manual_start: a matching major version starts as usual" {
  run --separate-stderr in_script 'rollback_needs_manual_start forgejo 16.0.5 16.0.4'
  assert_status 1
}

@test "rollback_needs_manual_start: an unreadable current version starts as usual, since the binary is too damaged to compare" {
  run --separate-stderr in_script 'rollback_needs_manual_start forgejo "" 15.2.0'
  assert_status 1
}

@test "rollback_needs_manual_start: the runner always starts as usual, since it keeps no database" {
  run --separate-stderr in_script 'rollback_needs_manual_start runner 13.1.0 12.0.0'
  assert_status 1
}

@test "rollback calls require_prev_slot on \$bin before the -x check and before stopping the service" {
  local rb req xcheck stop nextfn
  rb=$(source_lines '^rollback\(\) \{')
  req=$(source_lines 'require_prev_slot "\$bin"')
  xcheck=$(source_lines '\[\[ -x \$bin\.prev \]\]')
  stop=$(source_lines 'systemctl stop "\$svc"')
  nextfn=$(_first_function_after "$rb")

  [[ $req -gt $rb ]] \
    || { printf 'require_prev_slot "$bin" at line %s is not after rollback() at line %s\n' "$req" "$rb" >&2; return 1; }
  [[ -z $nextfn || $req -lt $nextfn ]] \
    || { printf 'require_prev_slot "$bin" at line %s is past the next function at line %s, so it is not inside rollback()\n' "$req" "$nextfn" >&2; return 1; }
  [[ $req -lt $xcheck ]] \
    || { printf 'require_prev_slot "$bin" (line %s) does not come before the -x check (line %s)\n' "$req" "$xcheck" >&2; return 1; }
  [[ $req -lt $stop ]] \
    || { printf 'require_prev_slot "$bin" (line %s) does not come before systemctl stop (line %s)\n' "$req" "$stop" >&2; return 1; }
}

@test "rollback sets BINARY_REPLACED=2 before the mv that consumes .prev" {
  local replaced mv
  replaced=$(source_lines '^  BINARY_REPLACED=2$')
  mv=$(source_lines 'mv -fT "\$bin\.prev" "\$bin"')
  # One assignment and one rename, so the comparison below is between two
  # line numbers and not between two lists of them.
  assert_equal "1" "$(printf '%s\n' "$replaced" | wc -l)"
  assert_equal "1" "$(printf '%s\n' "$mv" | wc -l)"
  [[ $replaced -lt $mv ]] \
    || { printf 'BINARY_REPLACED=2 (line %s) does not come before the mv (line %s)\n' "$replaced" "$mv" >&2; return 1; }
}

@test "rollback refuses a directory at the binary path before anything is stopped" {
  local dircheck stop
  dircheck=$(source_lines 'is a directory \(or a link to one\) rather than a file')
  stop=$(source_lines 'systemctl stop "\$svc"')
  [[ $dircheck -lt $stop ]] \
    || { printf 'the directory refusal (line %s) does not come before systemctl stop (line %s)\n' "$dircheck" "$stop" >&2; return 1; }
}
