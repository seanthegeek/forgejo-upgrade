#!/usr/bin/env bats
# The signature check, read from gpg's machine-readable status lines rather
# than its exit status. This file carries the AGENTS.md fact "Releases are
# signed by a rotating subkey, not the primary key": the pinned fingerprint is
# matched at the *end* of the VALIDSIG line, EXPSIG/EXPKEYSIG/REVKEYSIG are
# refused even though VALIDSIG is present beside them, and KEYEXPIRED - which
# every current release carries for older, unrelated subkeys - is not a
# failure. It also pins the wording of every way die_bad_signature can refuse
# a file, since that message is the whole of what an operator sees when an
# upgrade stops here.
#
# No gpg runs. A shell function named gpg shadows the binary inside the child
# shell and writes a status of this test's choosing to the status fd (which
# gpg_valid_sig sets to 1), so the real gpg_valid_sig, gpg_verdict,
# gpg_status_line and die_bad_signature are exercised over synthetic lines.
# The real release's real status is checked in tests/live.

# Snippets handed to in_script are single-quoted on purpose: they must reach
# the child shell unexpanded.
# shellcheck disable=SC2016
bats_require_minimum_version 1.5.0

# shellcheck source=tests/helpers.bash
setup() {
  load ../helpers
  common_setup
  # The Forgejo release key's primary fingerprint, per the download page. It is
  # written out here rather than read from the script so that a change to
  # RELEASE_KEY fails these tests: per AGENTS.md, moving the trust root is a
  # security decision, not a fix.
  KEY=EB114F5E6C0DC2BCDD183550A4B61A2DC5923710
  OTHER=0000000000000000000000000000000000000000
  SUBKEY=AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555
  # The shape gpg really prints: the signing subkey first, then the dates and
  # the algorithm fields, then the primary key fingerprint last.
  GOOD="[GNUPG:] VALIDSIG $SUBKEY 2026-01-01 1767225600 0 4 0 22 8 01 $KEY"
  NOTOURS="[GNUPG:] VALIDSIG $SUBKEY 2026-01-01 1767225600 0 4 0 22 8 01 $OTHER"
}

# Run gpg_valid_sig and gpg_verdict over one synthetic status text, printing
# "valid=<exit status> verdict=<word>". $1 is the status.
verdict_run() {  # $1 = status text
  run --separate-stderr in_script '
    gpg() { printf "%s\n" "$SYNTH"; }
    SYNTH=$1
    rc=0
    gpg_valid_sig /dev/null /dev/null || rc=$?
    printf "valid=%s verdict=%s\n" "$rc" "$(gpg_verdict)"
  ' "$1"
}

@test "the pinned release key is the fingerprint published on Forgejo's download page" {
  run --separate-stderr in_script 'printf "%s\n" "$RELEASE_KEY"'
  assert_status 0
  assert_equal "$KEY" "$output"
}

@test "a VALIDSIG line ending in the pinned primary key is accepted" {
  # The subkey fingerprint comes first and is deliberately not the pinned one:
  # matching the pinned fingerprint straight after VALIDSIG would fail on every
  # real release.
  verdict_run "$GOOD"
  assert_status 0
  assert_output_contains "valid=0"
}

@test "KEYEXPIRED lines for older subkeys do not make a good signature fail" {
  # Every current release's status carries these for unrelated subkeys on the
  # same primary key. Treating them as a failure would reject every release.
  verdict_run "[GNUPG:] KEYEXPIRED 1609459200
$GOOD
[GNUPG:] KEYEXPIRED 1640995200"
  assert_status 0
  assert_output_contains "valid=0"
}

@test "a VALIDSIG for the pinned key beside EXPKEYSIG is refused and the verdict is expired" {
  verdict_run "$GOOD
[GNUPG:] EXPKEYSIG AAAA1111BBBB2222 Forgejo <contact@forgejo.org>"
  assert_status 0
  assert_output_contains "valid=1 verdict=expired"
}

@test "a VALIDSIG for the pinned key beside EXPSIG is refused and the verdict is expired" {
  verdict_run "$GOOD
[GNUPG:] EXPSIG AAAA1111BBBB2222 Forgejo <contact@forgejo.org>"
  assert_status 0
  assert_output_contains "valid=1 verdict=expired"
}

@test "a VALIDSIG for the pinned key beside REVKEYSIG is refused and the verdict is revoked" {
  verdict_run "[GNUPG:] REVKEYSIG AAAA1111BBBB2222 Forgejo <contact@forgejo.org>
$GOOD"
  assert_status 0
  assert_output_contains "valid=1 verdict=revoked"
}

@test "a VALIDSIG ending in some other primary key is refused with the verdict other-key" {
  verdict_run "$NOTOURS"
  assert_status 0
  assert_output_contains "valid=1 verdict=other-key"
}

@test "an expired signature by another key is reported as expired, not as other-key" {
  # The order of the tests inside gpg_verdict is what decides this: the reason
  # the file was refused is the expiry, and saying "some other key" would send
  # the operator to the wrong page.
  verdict_run "$NOTOURS
[GNUPG:] EXPKEYSIG AAAA1111BBBB2222 Forgejo <contact@forgejo.org>"
  assert_status 0
  assert_output_contains "verdict=expired"
}

@test "BADSIG gives the verdict bad-signature" {
  verdict_run "[GNUPG:] BADSIG AAAA1111BBBB2222 Forgejo <contact@forgejo.org>"
  assert_status 0
  assert_output_contains "valid=1 verdict=bad-signature"
}

@test "NO_PUBKEY gives the verdict missing-key, the one verdict the caller retries" {
  verdict_run "[GNUPG:] NO_PUBKEY AAAA1111BBBB2222"
  assert_status 0
  assert_output_contains "valid=1 verdict=missing-key"
}

@test "ERRSIG gives the verdict missing-key too" {
  # gpg prints ERRSIG rather than NO_PUBKEY when it cannot say more about a
  # signature it could not check, so both have to lead to the key refresh.
  verdict_run "[GNUPG:] ERRSIG AAAA1111BBBB2222 22 8 00 1758240000 9 $KEY"
  assert_status 0
  assert_output_contains "valid=1 verdict=missing-key"
}

@test "an empty status gives the verdict unverifiable" {
  verdict_run ""
  assert_status 0
  assert_output_contains "valid=1 verdict=unverifiable"
}

@test "gpg_status_line quotes back the first status line matching the regex" {
  run --separate-stderr in_script '
    GPG_STATUS="[GNUPG:] KEYEXPIRED 1609459200
[GNUPG:] BADSIG AAAA1111BBBB2222 Forgejo <contact@forgejo.org>
[GNUPG:] BADSIG CCCC3333DDDD4444 Someone Else <x@example.org>"
    gpg_status_line "^\[GNUPG:\] BADSIG "
  '
  assert_status 0
  assert_equal "[GNUPG:] BADSIG AAAA1111BBBB2222 Forgejo <contact@forgejo.org>" "$output"
}

@test "gpg_status_line prints nothing and does not fail when no line matches" {
  # grep exits 1 on no match, which under the script's own set -e would end the
  # run in the middle of building an error message. An empty status - the
  # unverifiable case - is exactly when that would happen.
  run --separate-stderr in_script '
    GPG_STATUS=""
    gpg_status_line "^\[GNUPG:\] BADSIG "
    printf "survived\n"
  '
  assert_status 0
  assert_equal "survived" "$output"
}

# --- die_bad_signature: one message per verdict ------------------------------
#
# Each case feeds a status, lets gpg_verdict classify it exactly as
# fetch_and_verify does, and checks the sentence the operator reads.

# Call die_bad_signature over a synthetic status, with $2 as the "when" suffix.
die_run() {  # $1 = status text, $2 = when suffix
  run --separate-stderr in_script '
    GPG_STATUS=$1
    die_bad_signature forgejo-runner-13.1.0-linux-amd64 "$(gpg_verdict)" "$2"
  ' "$1" "$2"
}

@test "die_bad_signature on a bad signature says the file is damaged or tampered with" {
  die_run "[GNUPG:] BADSIG AAAA1111BBBB2222 Forgejo <contact@forgejo.org>" ""
  assert_status 1
  assert_stderr_contains "signature on forgejo-runner-13.1.0-linux-amd64 was refused: the signature does not match the file, so the download is damaged or has been tampered with"
  assert_stderr_contains "gpg reported 'bad-signature', status line: [GNUPG:] BADSIG AAAA1111BBBB2222"
  assert_stderr_contains "Do not install this file: check the release and the key fingerprint at https://forgejo.org/download/, and report a mismatch to Forgejo"
}

@test "die_bad_signature on an expired key says the signature or its key has expired" {
  die_run "$GOOD
[GNUPG:] EXPKEYSIG AAAA1111BBBB2222 Forgejo <contact@forgejo.org>" ""
  assert_status 1
  assert_stderr_contains "was refused: the signature or the key that made it has expired"
  assert_stderr_contains "gpg reported 'expired', status line: [GNUPG:] EXPKEYSIG AAAA1111BBBB2222"
  assert_stderr_contains "Do not install this file"
}

@test "die_bad_signature on a revoked key says the key has been revoked" {
  die_run "[GNUPG:] REVKEYSIG AAAA1111BBBB2222 Forgejo <contact@forgejo.org>" ""
  assert_status 1
  assert_stderr_contains "was refused: the key that made the signature has been revoked"
  assert_stderr_contains "gpg reported 'revoked', status line: [GNUPG:] REVKEYSIG AAAA1111BBBB2222"
  assert_stderr_contains "Do not install this file"
}

@test "die_bad_signature on another key quotes the VALIDSIG line it did see" {
  die_run "$NOTOURS" ""
  assert_status 1
  assert_stderr_contains "was refused: the file is signed by some other key"
  assert_stderr_contains "Expected gpg to report a VALIDSIG line ending in $KEY"
  assert_stderr_contains "gpg reported 'other-key', status line: $NOTOURS"
  assert_stderr_contains "Do not install this file"
}

@test "die_bad_signature on an empty status says gpg could not check the signature at all" {
  # With nothing to quote, the status-line clause has to be left out rather
  # than printed empty.
  die_run "" ""
  assert_status 1
  assert_stderr_contains "was refused: gpg could not check the signature at all"
  assert_stderr_contains "gpg reported 'unverifiable'. Do not install this file"
  refute_stderr_contains "status line:"
}

@test "die_bad_signature after the key refresh says so and still refuses the file" {
  # The second failure is the hard stop fetch_and_verify takes when refreshing
  # the pinned key did not help; the message has to say the refresh happened so
  # the operator does not try it again by hand.
  run --separate-stderr in_script '
    GPG_STATUS=$1
    die_bad_signature forgejo-runner-13.1.0-linux-amd64 "$(gpg_verdict)" \
      " even after the pinned key was refreshed from $KEYSERVER"
  ' "[GNUPG:] BADSIG AAAA1111BBBB2222 Forgejo <contact@forgejo.org>"
  assert_status 1
  assert_stderr_contains "was refused even after the pinned key was refreshed from hkps://keys.openpgp.org: the signature does not match the file"
  assert_stderr_contains "Do not install this file"
}
