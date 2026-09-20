# shellcheck shell=bash
#
# Shared helpers for the bats suite. Loaded by every test file with
#   setup() { load ../helpers; common_setup; }
#
# The one rule this file exists to enforce: script code runs in a child bash,
# never in the bats process. Sourcing forgejo-upgrade.sh arms `trap on_exit
# EXIT`, and bats owns the EXIT trap of its own test process; sourcing there
# would replace it and bats would lose track of the test. `in_script` below is
# the only sanctioned way to call into the script.

# --- setup -------------------------------------------------------------------

# Called from each test file's setup(). Works out where the script and the
# fixtures are, points TMPDIR at the per-test directory bats removes
# afterwards, and clears every variable the script treats as an operator
# override, so the developer's own environment cannot change a test's answer.
# PATH is deliberately left alone: a test that wants the stubs opts in with
# stub_path.
common_setup() {
  local root
  root=$(cd "$BATS_TEST_DIRNAME/../.." && pwd) || return 1
  SCRIPT=$root/forgejo-upgrade.sh
  FIXTURES=$root/tests/fixtures
  export SCRIPT FIXTURES
  # The script's WORKDIR, and any file a test makes, land here; bats deletes
  # the directory when the test ends.
  export TMPDIR=$BATS_TEST_TMPDIR
  unset FORGEJO_SERVICE FORGEJO_BIN FORGEJO_USER FORGEJO_CONFIG \
        FORGEJO_WORK_PATH FORGEJO_URL FORGEJO_SOCKET FORGEJO_DB_TYPE \
        BACKUP_DIR SKIP_BACKUP \
        RUNNER_SERVICE RUNNER_BIN RUNNER_HOME RUNNER_CONFIG \
        SUDO_USER GNUPGHOME CURL_HOME
}

# --- calling into the script --------------------------------------------------

# Write a snippet to a file that runs as if it were the script itself, and
# print the file's path. BASH_ARGV0 (bash 5.0 and later) makes $0 the script's
# own path inside the file, so rollback_command's %q "$0" and the usage text's
# `sed -n '2,36p' "$0"` see the real path, and `source "$0"` in the snippet
# loads the script. The snippet is run from a file rather than handed to
# `bash -c` for kcov's sake: kcov traces bash through a PS4 that expands
# ${BASH_SOURCE}, and once the script's `set -u` is in force a command at the
# top level of a -c string has no BASH_SOURCE and aborts with "unbound
# variable"; a file always has one. The file lands under the per-test
# directory, or the per-file one from setup_file, so bats removes it.
snippet_file() {  # $1 = bash text; it sources the script itself when it needs it
  local f
  f=$(mktemp "${BATS_TEST_TMPDIR:-${BATS_FILE_TMPDIR:-${TMPDIR:-/tmp}}}/snippet.XXXXXX") || return 1
  printf 'BASH_ARGV0=%q\n%s\n' "$SCRIPT" "$1" > "$f"
  printf '%s\n' "$f"
}

# Run a bash snippet in a fresh shell that has sourced the script. $0 inside
# the snippet is the script's own path (see snippet_file); any extra arguments
# are $1, $2 ... inside the snippet. The script's own `set -euo pipefail` is
# in force, as it is for the real thing. Use it with bats' run, and with
# --separate-stderr because the script's contract is that returned values go
# to stdout and log/warn/die go to stderr:
#   FORGEJO_BIN=/x run --separate-stderr in_script 'parse_runner_version "$1"' "$v"
# A snippet that has to do something before the script is sourced (set
# TMPDIR, say) uses snippet_file directly and puts its own `source "$0"`
# where it belongs.
in_script() {
  local f
  # The single quotes are the point: `source "$0"` must reach the child shell
  # unexpanded, where $0 is the script's path.
  # shellcheck disable=SC2016
  f=$(snippet_file 'source "$0"; '"$1") || return 1
  bash "$f" "${@:2}"
}

# --- fixtures and stubs --------------------------------------------------------

# Put a directory of stub commands in front of PATH for the rest of the test.
stub_path() { PATH=$1:$PATH; export PATH; }

# Write an executable one-line script at $1 that prints $2 and exits with $3
# (0 by default). Used for fake `forgejo --version` binaries and one-off
# command stubs. Parent directories are created.
fake_bin() {
  local path=$1 text=$2 rc=${3:-0} dir=${1%/*}
  [[ $dir == "$path" ]] || mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf "printf '%%s\\\\n' %q\n" "$text"
    printf 'exit %s\n' "$rc"
  } > "$path"
  chmod +x "$path"
}

# --- structural checks ----------------------------------------------------------

# Print the line numbers in the script matching an extended regex, one per
# line. Zero matches is a failure, not an empty pass: a structural check aimed
# at a string that is no longer there would otherwise look green while
# checking nothing (AGENTS.md, "An ad hoc check that matches nothing is broken,
# not green").
source_lines() {
  local hits
  hits=$(grep -nE -- "$1" "$SCRIPT") || hits=""
  if [[ -z $hits ]]; then
    printf 'source_lines: no line of %s matches the regex: %s\n' "$SCRIPT" "$1" >&2
    return 1
  fi
  printf '%s\n' "$hits" | cut -d: -f1
}

# --- optional tools ---------------------------------------------------------------

# Skip the test when a command this case needs is not installed here.
skip_unless() {
  local cmd=$1 msg=${2:-"$1 is not installed"}
  command -v "$cmd" >/dev/null 2>&1 || skip "$msg"
}

# Set an extended attribute: setfattr when the attr package is installed,
# else python3, else return 2 so the caller can skip the case. Names have to
# carry their namespace, e.g. user.test.
set_xattr() {  # $1 = file, $2 = name, $3 = value
  if command -v setfattr >/dev/null 2>&1; then
    setfattr -n "$2" -v "$3" "$1"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; os.setxattr(sys.argv[1], sys.argv[2], sys.argv[3].encode())' \
      "$1" "$2" "$3"
  else
    return 2
  fi
}

# Read back an extended attribute set by set_xattr, by the same three routes.
get_xattr() {  # $1 = file, $2 = name
  if command -v getfattr >/dev/null 2>&1; then
    getfattr --absolute-names --only-values -n "$2" "$1"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; sys.stdout.write(os.getxattr(sys.argv[1], sys.argv[2]).decode())' \
      "$1" "$2"
  else
    return 2
  fi
}

# --- assertions ---------------------------------------------------------------------
#
# Deliberately small and local: no bats-assert, no submodule. Each one prints
# what it expected and what it got, so a failure line in bats' output says why
# without the reader opening the test file.

assert_equal() {  # $1 = expected, $2 = actual
  if [[ $1 != "$2" ]]; then
    printf 'expected: %s\n  actual: %s\n' "$1" "$2" >&2
    return 1
  fi
}

# Checks bats' $status from the last `run`.
assert_status() {  # $1 = expected exit status
  if [[ ${status?run has not been called} -ne $1 ]]; then
    printf 'expected exit status: %s\n  actual exit status: %s\n' "$1" "$status" >&2
    printf 'stdout: %s\nstderr: %s\n' "${output-}" "${stderr-}" >&2
    return 1
  fi
}

assert_output_contains() {  # $1 = substring that must appear on stdout
  if [[ ${output?run has not been called} != *"$1"* ]]; then
    printf 'expected stdout to contain: %s\n            actual stdout: %s\n' "$1" "$output" >&2
    return 1
  fi
}

assert_stderr_contains() {  # $1 = substring that must appear on stderr
  if [[ ${stderr?run --separate-stderr has not been called} != *"$1"* ]]; then
    printf 'expected stderr to contain: %s\n            actual stderr: %s\n' "$1" "$stderr" >&2
    return 1
  fi
}

refute_stderr_contains() {  # $1 = substring that must not appear on stderr
  if [[ ${stderr?run --separate-stderr has not been called} == *"$1"* ]]; then
    printf 'expected stderr NOT to contain: %s\n                actual stderr: %s\n' "$1" "$stderr" >&2
    return 1
  fi
}

# Both strings must appear on stderr, the first on an earlier line than the
# second. This is how the ordering rules are checked, e.g. that on_exit prints
# the rollback command before the `systemctl start` hint.
assert_line_before() {  # $1 = the string that must come first, $2 = the one that follows
  local first second
  first=$(printf '%s\n' "${stderr?run --separate-stderr has not been called}" \
            | grep -n -m1 -F -- "$1" | cut -d: -f1)
  second=$(printf '%s\n' "$stderr" | grep -n -m1 -F -- "$2" | cut -d: -f1)
  if [[ -z $first || -z $second || $first -ge $second ]]; then
    printf 'expected "%s" (line %s) before "%s" (line %s) on stderr:\n%s\n' \
      "$1" "${first:-absent}" "$2" "${second:-absent}" "$stderr" >&2
    return 1
  fi
}
