#!/usr/bin/env bats
# fetch_and_verify against the current forgejo-runner release: the one path in
# this script that can only be trusted after it has run for real. It carries
# the AGENTS.md facts that releases are signed by a rotating subkey whose
# VALIDSIG line ends in the pinned primary fingerprint, that the KEYEXPIRED
# lines every current release carries are not a failure, that the .sha256 file
# names the asset so the check runs in the directory holding it, that the
# runner prints "forgejo-runner version v13.1.0" with a v in front, and - the
# negative half, without which a signature check that has only ever been seen
# passing guards nothing - that one appended byte is refused with the verdict
# bad-signature. The last test guards the "set -e does not apply inside $(...)"
# rule: a download that cannot succeed has to be reported as a failed
# download, never as an unverifiable signature. This file needs the network
# and downloads the runner asset (about 20 MB) once, in setup_file.

# Snippets handed to in_script are single-quoted on purpose: they must reach
# the child shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

# One download for the whole file. setup_file has no BATS_TEST_TMPDIR and no
# common_setup, so the two things in_script needs - SCRIPT, and a TMPDIR the
# script's WORKDIR can live under - are set here by hand. The verified files
# are copied out of WORKDIR before the child exits, because on_exit deletes
# WORKDIR on the way out; every test below works from those copies.
setup_file() {
  load ../helpers
  SCRIPT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/forgejo-upgrade.sh
  export SCRIPT
  export TMPDIR=$BATS_FILE_TMPDIR

  # A keyring of this file's own, empty to begin with, so ensure_key's import
  # runs on every pass rather than only on a machine that lacks the key, and
  # the developer's personal keyring is never touched. Its path is recorded
  # for setup to restore, since common_setup clears GNUPGHOME.
  mkdir -m 700 "$BATS_FILE_TMPDIR/gnupg"
  export GNUPGHOME=$BATS_FILE_TMPDIR/gnupg
  printf '%s\n' "$GNUPGHOME" > "$BATS_FILE_TMPDIR/gnupghome"

  local ver assets=$BATS_FILE_TMPDIR/assets
  mkdir -p "$assets"
  ver=$(in_script 'latest_tag "$RUNNER_REPO"')
  if [[ ! $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'setup_file: latest_tag gave no usable runner version: %s\n' "$ver" >&2
    return 1
  fi
  printf '%s\n' "$ver" > "$BATS_FILE_TMPDIR/ver"
  printf 'forgejo-runner-%s-linux-%s\n' "$ver" "$(in_script 'arch')" \
    > "$BATS_FILE_TMPDIR/asset"

  local rc=0
  in_script '
    ensure_key
    asset=forgejo-runner-$1-linux-$(arch)
    path=$(fetch_and_verify "$RUNNER_REPO" "$asset" "$1")
    cp -p "$path" "$path.asc" "$2/"
    # Older releases publish no .sha256 at all; the file is copied when it is
    # there and the test for it skips when it is not.
    if [[ -e $path.sha256 ]]; then cp -p "$path.sha256" "$2/"; fi
    printf "%s\n" "$path"
  ' "$ver" "$assets" \
    > "$BATS_FILE_TMPDIR/download.out" 2> "$BATS_FILE_TMPDIR/download.err" || rc=$?
  printf '%s\n' "$rc" > "$BATS_FILE_TMPDIR/download.status"
}

# shellcheck source=tests/helpers.bash
setup() {
  load ../helpers
  common_setup
  VER=$(cat "$BATS_FILE_TMPDIR/ver")
  ASSET=$(cat "$BATS_FILE_TMPDIR/asset")
  ASSETS=$BATS_FILE_TMPDIR/assets
  # common_setup clears GNUPGHOME so a developer's environment cannot change a
  # test's answer; here the keyring setup_file imported the release key into is
  # exactly what the tests have to read, so it is put back.
  GNUPGHOME=$(cat "$BATS_FILE_TMPDIR/gnupghome")
  export GNUPGHOME
}

teardown_file() {
  # gpg starts an agent and a dirmngr for the keyring; stop them so nothing
  # of this file's is left running once bats removes the directory.
  GNUPGHOME=$BATS_FILE_TMPDIR/gnupg gpgconf --kill all >/dev/null 2>&1 || true
}

@test "fetch_and_verify downloads the current runner release, verifies it, and prints its path" {
  local status_file=$BATS_FILE_TMPDIR/download.status
  assert_equal "0" "$(cat "$status_file")"
  local out err
  out=$(cat "$BATS_FILE_TMPDIR/download.out")
  err=$(cat "$BATS_FILE_TMPDIR/download.err")
  echo "# verified release: $VER ($ASSET)" >&3
  if [[ $out != */$ASSET ]]; then
    printf 'expected the path of the verified asset, got: %s\n' "$out" >&2
    return 1
  fi
  # The three log lines the function prints, in the order it prints them. They
  # go to stderr on purpose: this function returns its value on stdout, and a
  # log line written there would become part of a file path.
  for line in "Downloading $ASSET" "Verifying GPG signature"; do
    if [[ $err != *"$line"* ]]; then
      printf 'expected the log to contain: %s\nlog was:\n%s\n' "$line" "$err" >&2
      return 1
    fi
  done
  if [[ -e $ASSETS/$ASSET.sha256 ]]; then
    [[ $err == *"Verifying sha256"* ]] || { printf 'no sha256 log line:\n%s\n' "$err" >&2; return 1; }
    [[ $err != *"no .sha256 published"* ]] || { printf 'the release has a .sha256 but the run warned it had none\n' >&2; return 1; }
  else
    [[ $err == *"no .sha256 published for $ASSET (HTTP 404)"* ]] \
      || { printf 'no .sha256 was copied out, but the run did not warn about it:\n%s\n' "$err" >&2; return 1; }
  fi
}

@test "the verified file is the runner binary for that version, and the parsers read it" {
  # AGENTS.md: the runner prints "forgejo-runner version v13.1.0", with a "v"
  # the version this script works with does not have.
  run --separate-stderr "$ASSETS/$ASSET" --version
  assert_status 0
  echo "# the binary printed: $output" >&3
  if [[ $output != "forgejo-runner version v"* ]]; then
    printf 'expected a line starting "forgejo-runner version v", got: %s\n' "$output" >&2
    return 1
  fi
  local raw=$output

  run --separate-stderr in_script 'parse_runner_version "$1"' "$raw"
  assert_status 0
  assert_equal "$VER" "$output"

  # The same string through the other half of the pair: installed_runner runs
  # the binary itself and hands its output to that parser.
  RUNNER_BIN=$ASSETS/$ASSET run --separate-stderr in_script 'installed_runner'
  assert_status 0
  assert_equal "$VER" "$output"
}

@test "gpg_valid_sig accepts the release, whose VALIDSIG ends in the pinned key and whose KEYEXPIRED lines are tolerated" {
  run --separate-stderr in_script '
    if gpg_valid_sig "$1.asc" "$1"; then echo ACCEPTED; else echo "REFUSED verdict=$(gpg_verdict)"; fi
    printf "keyexpired=%s\n" "$(grep -c "^\[GNUPG:\] KEYEXPIRED " <<<"$GPG_STATUS" || true)"
    printf "rejected-records=%s\n" "$(grep -Ec "^\[GNUPG:\] (EXPSIG|EXPKEYSIG|REVKEYSIG) " <<<"$GPG_STATUS" || true)"
    grep -E "^\[GNUPG:\] VALIDSIG .* $RELEASE_KEY\$" <<<"$GPG_STATUS" || echo NO-MATCHING-VALIDSIG
  ' "$ASSETS/$ASSET"
  assert_status 0
  assert_output_contains "ACCEPTED"
  assert_output_contains "[GNUPG:] VALIDSIG "
  # The fingerprint is matched at the END of the line: it is the primary key,
  # and the subkey that actually signed comes first.
  local validsig
  validsig=$(printf '%s\n' "$output" | grep -m1 -E '^\[GNUPG:\] VALIDSIG ')
  if [[ $validsig != *" EB114F5E6C0DC2BCDD183550A4B61A2DC5923710" ]]; then
    printf 'VALIDSIG does not end in the pinned primary fingerprint:\n%s\n' "$validsig" >&2
    return 1
  fi
  assert_output_contains "rejected-records=0"

  local n=${output#*keyexpired=}
  n=${n%%$'\n'*}
  echo "# KEYEXPIRED lines in this release's status: $n (these must not be a failure)" >&3
  # A zero here would mean the KEYEXPIRED tolerance is no longer being
  # exercised by the live release - the test would keep passing while proving
  # nothing - so it is a failure asking for the fact to be re-checked.
  if [[ $n -lt 1 ]]; then
    printf 'no KEYEXPIRED lines in the release status; AGENTS.md says every current release carries some for older subkeys. Re-check that fact.\n' >&2
    return 1
  fi
}

@test "sha256sum -c passes in the directory holding the asset" {
  [[ -e $ASSETS/$ASSET.sha256 ]] || skip "this release publishes no .sha256"
  # The .sha256 file names the asset with no path, which is why the check has
  # to run with that directory as the working directory.
  run --separate-stderr bash -c 'cd "$1" && sha256sum -c --quiet "$2"' bash "$ASSETS" "$ASSET.sha256"
  assert_status 0
}

@test "one appended byte is refused by the same signature check, with the verdict bad-signature" {
  local dir=$BATS_TEST_TMPDIR/tampered
  mkdir -p "$dir"
  cp -p "$ASSETS/$ASSET" "$ASSETS/$ASSET.asc" "$dir/"
  [[ ! -e $ASSETS/$ASSET.sha256 ]] || cp -p "$ASSETS/$ASSET.sha256" "$dir/"
  printf 'x' >> "$dir/$ASSET"

  run --separate-stderr in_script '
    if gpg_valid_sig "$1.asc" "$1"; then echo ACCEPTED; else echo REFUSED; fi
    printf "verdict=%s\n" "$(gpg_verdict)"
    printf "status-line=%s\n" "$(gpg_status_line "^\[GNUPG:\] BADSIG ")"
  ' "$dir/$ASSET"
  assert_status 0
  assert_output_contains "REFUSED"
  assert_output_contains "verdict=bad-signature"
  assert_output_contains "status-line=[GNUPG:] BADSIG "

  if [[ -e $dir/$ASSET.sha256 ]]; then
    run --separate-stderr bash -c 'cd "$1" && sha256sum -c --quiet "$2"' bash "$dir" "$ASSET.sha256"
    if [[ $status -eq 0 ]]; then
      printf 'sha256sum -c accepted the tampered file\n' >&2
      return 1
    fi
  fi
}

@test "a download that cannot succeed says the download failed, not that a signature could not be verified" {
  # bash turns errexit off inside the $(...) both callers use, so an unchecked
  # curl failure would fall through to the GPG check and be reported as an
  # unverifiable signature. Every command in fetch_and_verify is checked by
  # hand for that reason, and this is the test that says so.
  run --separate-stderr in_script \
    'fetch_and_verify "$RUNNER_REPO" forgejo-runner-0.0.0-linux-amd64 0.0.0'
  assert_status 1
  assert_equal "" "$output"
  # The repo URL is spelled out rather than read from the script, so the
  # message is compared against a constant the test states for itself.
  assert_stderr_contains "could not download https://code.forgejo.org/forgejo/runner/releases/download/v0.0.0/forgejo-runner-0.0.0-linux-amd64 (curl exit"
  assert_stderr_contains "Nothing was installed"
  refute_stderr_contains "signature on"
  refute_stderr_contains "Verifying GPG signature"
  refute_stderr_contains "Verifying sha256"
}
