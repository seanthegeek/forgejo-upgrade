#!/usr/bin/env bats
# The one automatic key action the script takes: when a release's signature is
# by a subkey the local keyring has never seen, fetch_and_verify refreshes
# exactly RELEASE_KEY from KEYSERVER and tries the check once more. This file
# runs both halves against the live release and the live keyserver, from a
# GNUPGHOME that starts empty and with ensure_key deliberately not called - the
# second half with the keyserver pointed at a host that does not resolve, where
# the run has to stop rather than pass. The trust root does not move in either
# case: only the pinned fingerprint is ever asked for.
#
# This file needs the network and a reachable keyserver, and it downloads the
# runner asset (about 20 MB) twice in setup_file, once per scenario: the
# download happens before the signature check, so neither scenario can be
# reached without it, and a cached copy would take the real download out of the
# path being tested.

# Snippets handed to in_script are single-quoted on purpose: they must reach
# the child shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

setup_file() {
  load ../helpers
  SCRIPT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/forgejo-upgrade.sh
  export SCRIPT
  export TMPDIR=$BATS_FILE_TMPDIR

  local ver asset
  ver=$(in_script 'latest_tag "$RUNNER_REPO"')
  if [[ ! $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'setup_file: latest_tag gave no usable runner version: %s\n' "$ver" >&2
    return 1
  fi
  asset=forgejo-runner-$ver-linux-$(in_script 'arch')
  printf '%s\n' "$ver" > "$BATS_FILE_TMPDIR/ver"
  printf '%s\n' "$asset" > "$BATS_FILE_TMPDIR/asset"

  # GNUPGHOME is exported here rather than set in front of the in_script call:
  # an assignment in front of a shell function is not reliably confined to that
  # call, and a subshell around it would hide the export from the reader (and
  # from shellcheck) for no gain. setup_file runs in its own process, and every
  # test below starts from common_setup, which clears GNUPGHOME again.
  local home rc
  for home in a b; do
    mkdir -p "$BATS_FILE_TMPDIR/gnupg-$home"
    chmod 700 "$BATS_FILE_TMPDIR/gnupg-$home"
    # Proof that each keyring really starts without the pinned key, so a pass
    # below cannot come from a key that was already there.
    rc=0
    export GNUPGHOME=$BATS_FILE_TMPDIR/gnupg-$home
    gpg --list-keys EB114F5E6C0DC2BCDD183550A4B61A2DC5923710 >/dev/null 2>&1 || rc=$?
    printf '%s\n' "$rc" > "$BATS_FILE_TMPDIR/before-$home.status"
  done

  # a: an empty keyring and the real keyserver. ensure_key is never called, so
  # the first signature check fails with the key missing and the refresh
  # inside fetch_and_verify is the only thing that can rescue it.
  rc=0
  export GNUPGHOME=$BATS_FILE_TMPDIR/gnupg-a
  in_script 'fetch_and_verify "$RUNNER_REPO" "$1" "$2"' "$asset" "$ver" \
    > "$BATS_FILE_TMPDIR/a.out" 2> "$BATS_FILE_TMPDIR/a.err" || rc=$?
  printf '%s\n' "$rc" > "$BATS_FILE_TMPDIR/a.status"

  # b: the same, with the keyserver pointed at a host that does not resolve.
  rc=0
  export GNUPGHOME=$BATS_FILE_TMPDIR/gnupg-b
  in_script 'KEYSERVER=hkps://no-such-host.invalid; fetch_and_verify "$RUNNER_REPO" "$1" "$2"' \
    "$asset" "$ver" \
    > "$BATS_FILE_TMPDIR/b.out" 2> "$BATS_FILE_TMPDIR/b.err" || rc=$?
  printf '%s\n' "$rc" > "$BATS_FILE_TMPDIR/b.status"
  unset GNUPGHOME
}

teardown_file() {
  # gpg starts an agent and a dirmngr per GNUPGHOME; stop the two this file
  # started rather than leave them holding a directory bats is about to delete.
  local home
  for home in a b; do
    GNUPGHOME=$BATS_FILE_TMPDIR/gnupg-$home gpgconf --kill all >/dev/null 2>&1 || true
  done
}

# shellcheck source=tests/helpers.bash
setup() {
  load ../helpers
  common_setup
  VER=$(cat "$BATS_FILE_TMPDIR/ver")
  ASSET=$(cat "$BATS_FILE_TMPDIR/asset")
}

@test "an empty keyring is rescued by refreshing exactly the pinned key, and the release then verifies" {
  assert_equal "0" "$(cat "$BATS_FILE_TMPDIR/a.status")"
  local out err
  out=$(cat "$BATS_FILE_TMPDIR/a.out")
  err=$(cat "$BATS_FILE_TMPDIR/a.err")
  echo "# release under test: $VER ($ASSET)" >&3
  # The keyring had nothing in it before the run, so the pass below is the
  # refresh working and not a key that was already present.
  if [[ $(cat "$BATS_FILE_TMPDIR/before-a.status") == 0 ]]; then
    printf 'the "empty" keyring already held the release key; this test would prove nothing\n' >&2
    return 1
  fi
  if [[ $out != */$ASSET ]]; then
    printf 'expected the path of the verified asset, got: %s\nlog:\n%s\n' "$out" "$err" >&2
    return 1
  fi
  for line in \
    "Verifying GPG signature" \
    "signature is by a key not in the keyring; refreshing the pinned key EB114F5E6C0DC2BCDD183550A4B61A2DC5923710 from hkps://keys.openpgp.org (the same fingerprint, nothing else)"
  do
    if [[ $err != *"$line"* ]]; then
      printf 'expected the log to contain: %s\nlog was:\n%s\n' "$line" "$err" >&2
      return 1
    fi
  done
}

@test "the refreshed keyring holds the pinned key afterwards, and nothing else was imported" {
  GNUPGHOME=$BATS_FILE_TMPDIR/gnupg-a run --separate-stderr \
    gpg --list-keys EB114F5E6C0DC2BCDD183550A4B61A2DC5923710
  assert_status 0
  # Exactly one primary key: the refresh fetches the pinned fingerprint and
  # nothing else, which is what keeps the trust root from moving.
  GNUPGHOME=$BATS_FILE_TMPDIR/gnupg-a run --separate-stderr bash -c \
    'gpg --list-keys --with-colons | grep -c "^pub:"'
  assert_status 0
  assert_equal "1" "$output"
}

@test "a keyserver that cannot be reached stops the run instead of letting the download through" {
  local rc out err
  rc=$(cat "$BATS_FILE_TMPDIR/b.status")
  out=$(cat "$BATS_FILE_TMPDIR/b.out")
  err=$(cat "$BATS_FILE_TMPDIR/b.err")
  if [[ $rc -eq 0 ]]; then
    printf 'fetch_and_verify passed with an unusable keyserver and an empty keyring\nlog:\n%s\n' "$err" >&2
    return 1
  fi
  assert_equal "" "$out"
  # gpg --recv itself fails here, so the run stops on the refresh rather than
  # on die_bad_signature: die_bad_signature's "even after the pinned key was
  # refreshed" wording is reached only when the refresh succeeds and the
  # signature is still not good, which is exercised with synthetic status text
  # in tests/unit/gpg.bats.
  for line in \
    "could not refresh the key EB114F5E6C0DC2BCDD183550A4B61A2DC5923710 from hkps://no-such-host.invalid" \
    "the signature on $ASSET cannot be checked, so the download is not trusted and nothing was installed" \
    "import the key by hand from https://forgejo.org/download/"
  do
    if [[ $err != *"$line"* ]]; then
      printf 'expected the failure to say: %s\nit said:\n%s\n' "$line" "$err" >&2
      return 1
    fi
  done
  # It never reached the checksum, and it never called the file verified.
  if [[ $err == *"Verifying sha256"* ]]; then
    printf 'the run went on to the checksum after the signature could not be checked:\n%s\n' "$err" >&2
    return 1
  fi
}

@test "the keyring that could not reach the keyserver is left without the pinned key" {
  if [[ $(cat "$BATS_FILE_TMPDIR/before-b.status") == 0 ]]; then
    printf 'the "empty" keyring already held the release key; this test would prove nothing\n' >&2
    return 1
  fi
  GNUPGHOME=$BATS_FILE_TMPDIR/gnupg-b run --separate-stderr \
    gpg --list-keys EB114F5E6C0DC2BCDD183550A4B61A2DC5923710
  if [[ $status -eq 0 ]]; then
    printf 'the release key is in a keyring whose keyserver never answered\n' >&2
    return 1
  fi
}
