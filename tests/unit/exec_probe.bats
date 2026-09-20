#!/usr/bin/env bats
# require_exec_workdir: the check that the working directory can run a
# program, made before anything is downloaded. The downloaded binary is run
# once from there to find out which version it really is, and a /tmp mounted
# noexec makes that run fail with exit 126, which reads as a broken download
# or the wrong architecture - so this probe exists to say "noexec" instead,
# with the TMPDIR remedy, and to say it before the first byte is fetched.
#
# The noexec filesystem is a bind mount remounted noexec inside a mount
# namespace of our own; unshare -Urm gives that without root. Docker's default
# seccomp profile blocks it, so those cases skip rather than fail where user
# namespaces are not available. The child shell sources the script itself
# rather than going through in_script, because WORKDIR is created by mktemp at
# source time and TMPDIR has to already point at the noexec directory by then.

# Snippets handed to a child bash are single-quoted on purpose: they must
# reach that shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

# shellcheck source=tests/helpers.bash
setup() {
  load ../helpers
  common_setup
  NOEXEC=$BATS_TEST_TMPDIR/noexec
  mkdir -p "$NOEXEC"
}

# Skip the case unless a noexec bind mount can really be made here without
# root. The probe does the whole thing, not just `unshare -Urm true`: on
# GitHub's Ubuntu runner the namespace can be entered once AppArmor's
# restriction on unprivileged user namespaces is lifted, but the bind mount
# inside it is still refused with "permission denied", and a guard that only
# tried unshare let the test run and fail there. The probe mounts a scratch
# directory, which the namespace drops again when the shell exits.
need_userns() {
  skip_unless unshare
  local probe=$BATS_TEST_TMPDIR/userns-probe
  mkdir -p "$probe"
  if ! unshare -Urm sh -c 'mount --bind "$1" "$1" && mount -o remount,bind,noexec "$1" "$1"' sh "$probe" 2>/dev/null; then
    skip "a noexec bind mount cannot be made here without root (unshare -Urm refused, or the mount inside it was), so the noexec case is not run"
  fi
}

@test "an ordinary working directory passes the exec probe" {
  # TMPDIR is the per-test directory, which is an ordinary filesystem: the
  # probe writes a two-line script there, runs it, and says nothing.
  run --separate-stderr in_script 'require_exec_workdir; printf "probe-ok\n"'
  assert_status 0
  assert_output_contains "probe-ok"
  assert_equal "" "$stderr"
}

@test "a noexec working directory fails the exec probe, naming noexec and TMPDIR" {
  need_userns
  run --separate-stderr unshare -Urm bash "$(snippet_file '
    set -e
    export LC_ALL=C
    mount --bind "$1" "$1"
    mount -o remount,bind,noexec "$1" "$1"
    export TMPDIR=$1
    source "$0"
    require_exec_workdir
    printf "PROBE-PASSED\n"
  ')" "$NOEXEC"
  assert_status 1
  # The snippet echoes the sentinel, so it would land on stdout; refuting it
  # on stderr would pass even if the probe had let the run through.
  refute_output_contains "PROBE-PASSED"
  assert_stderr_contains "cannot run a program from $NOEXEC/forgejo-upgrade."
  assert_stderr_contains "The filesystem holding it is most likely mounted noexec"
  assert_stderr_contains "Set TMPDIR to a directory on a filesystem that allows execution"
  assert_stderr_contains "sudo TMPDIR=/var/tmp $SCRIPT forgejo latest"
  assert_stderr_contains "Nothing was installed"
}

@test "fetch_and_verify stops on a noexec working directory before it downloads anything" {
  # The curl on PATH here shouts if it is reached. Reaching it would mean the
  # operator waited for a 20 MB download only to be told the file cannot be
  # run, with the real reason - the mount options - never named.
  need_userns
  run --separate-stderr unshare -Urm bash "$(snippet_file '
    set -e
    export LC_ALL=C
    mount --bind "$1" "$1"
    mount -o remount,bind,noexec "$1" "$1"
    export TMPDIR=$1
    export PATH=$2:$PATH
    source "$0"
    fetch_and_verify "$RUNNER_REPO" forgejo-runner-13.1.0-linux-amd64 13.1.0
  ')" "$NOEXEC" "$FIXTURES/curl/tripwire"
  assert_status 1
  assert_stderr_contains "cannot run a program from"
  assert_stderr_contains "mounted noexec"
  # Nothing was fetched and nothing was even announced as being fetched.
  # The tripwire echoes on stdout, but the script calls curl inside a command
  # substitution in places, so both streams are refuted.
  refute_output_contains "CURL-WAS-CALLED"
  refute_stderr_contains "CURL-WAS-CALLED"
  refute_stderr_contains "Downloading"
}

@test "the same download in an ordinary working directory gets past the probe to the download" {
  # The control for the case above, in the same mount namespace: with no
  # remount the probe passes and the run reaches curl, so the refutals above
  # are about the probe and not about the tripwire never being on PATH. The
  # run still fails, on the signature of the file the tripwire never wrote,
  # which is the point: it got that far. GNUPGHOME is a throwaway directory so
  # that gpg does not touch the developer's own keyring.
  need_userns
  run --separate-stderr unshare -Urm bash "$(snippet_file '
    set -e
    export LC_ALL=C
    export TMPDIR=$1
    export PATH=$2:$PATH
    export GNUPGHOME=$1/gnupg
    source "$0"
    fetch_and_verify "$RUNNER_REPO" forgejo-runner-13.1.0-linux-amd64 13.1.0
  ')" "$NOEXEC" "$FIXTURES/curl/tripwire"
  refute_stderr_contains "cannot run a program from"
  assert_stderr_contains "Downloading forgejo-runner-13.1.0-linux-amd64"
  assert_stderr_contains "Verifying GPG signature"
  if [[ $output != *"CURL-WAS-CALLED"* && $stderr != *"CURL-WAS-CALLED"* ]]; then
    printf 'expected the tripwire curl to be reached in the control case; stdout:\n%s\nstderr:\n%s\n' \
      "$output" "$stderr" >&2
    return 1
  fi
}
