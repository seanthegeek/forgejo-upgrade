#!/usr/bin/env bats
# SCRIPT_VERSION, the version/--version dispatch arms, CHANGELOG.md's shape,
# and the release-check/release-notes Makefile targets that the release
# workflows run before publishing anything. AGENTS.md's Review-discipline
# pairs bullet names SCRIPT_VERSION, the first released CHANGELOG.md
# section, and the tag as a triple that has to agree; this file is where
# that agreement is checked.

# Single-quoted snippets below carry "$0" and "$1" for a child bash, and one
# regex is matched against the script's own text; the "$0" in each has to
# survive unexpanded. That is exactly what SC2016 warns about, and exactly
# what is wanted here, so it is turned off for the file rather than repeated
# at every call.
# shellcheck disable=SC2016

# `run --separate-stderr` is a 1.5.0 feature; saying so here turns bats'
# BW02 warning into a version requirement it checks.
bats_require_minimum_version 1.5.0

setup() {
  load ../helpers
  common_setup
  ROOT=$(dirname "$SCRIPT")
  CHANGELOG=$ROOT/CHANGELOG.md
  VERSION=$(sed -n 's/^SCRIPT_VERSION=//p' "$SCRIPT")
}

# --- SCRIPT_VERSION and the dispatch arms ------------------------------------

@test "SCRIPT_VERSION is set and looks like a semantic version" {
  # A single source_lines call both proves the assignment exists and pins
  # its shape, per "An ad hoc check that matches nothing is broken, not
  # green": a typo here (a stray v prefix, a missing patch number) fails
  # loudly rather than reading back whatever is there.
  source_lines '^SCRIPT_VERSION=[0-9]+\.[0-9]+\.[0-9]+$'
}

@test "the header's Usage list names the version subcommand" {
  source_lines '^#   forgejo-upgrade\.sh version '
}

@test "'version' prints exactly forgejo-upgrade <version> on stdout and exits 0" {
  run --separate-stderr "$SCRIPT" version
  assert_status 0
  assert_equal "forgejo-upgrade $VERSION" "$output"
  assert_equal "" "$stderr"
}

@test "'--version' prints the same thing as 'version'" {
  run --separate-stderr "$SCRIPT" --version
  assert_status 0
  assert_equal "forgejo-upgrade $VERSION" "$output"
  assert_equal "" "$stderr"
}

# --- CHANGELOG.md -------------------------------------------------------------

@test "CHANGELOG.md's first two ## headings are Unreleased and the current version" {
  local headings first second
  headings=$(grep -E '^## \[' "$CHANGELOG")
  first=$(sed -n '1p' <<<"$headings")
  second=$(sed -n '2p' <<<"$headings")
  assert_equal "## [Unreleased]" "$first"
  # The date itself is not pinned to today: CHANGELOG.md is written once,
  # at merge time, and the tag can follow later. Only the shape is checked.
  if [[ ! $second =~ ^\#\#\ \[${VERSION//./\\.}\]\ -\ [0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    printf 'expected second heading "## [%s] - YYYY-MM-DD", got: %s\n' "$VERSION" "$second" >&2
    return 1
  fi
}

@test "every ## [x] heading in CHANGELOG.md has a matching link reference" {
  local heading name bad="" headings
  headings=$(grep -E '^## \[' "$CHANGELOG")
  # An ad hoc check that matches nothing is broken, not green (AGENTS.md,
  # Review discipline): if the heading grep itself found nothing, the loop
  # below would exit 0 having asserted nothing at all.
  [[ -n $headings ]] \
    || { echo "no '## [' headings found in $CHANGELOG" >&2; return 1; }
  while IFS= read -r heading; do
    name=$(sed -E 's/^## \[([^]]+)\].*/\1/' <<<"$heading")
    grep -qE "^\[$(sed 's/[.[\*^$/]/\\&/g' <<<"$name")\]: " "$CHANGELOG" \
      || bad+="no link reference for [$name]"$'\n'
  done <<<"$headings"
  if [[ -n $bad ]]; then
    printf '%s' "$bad" >&2
    return 1
  fi
}

# --- make release-check and make release-notes -------------------------------

@test "make release-check passes when TAG matches SCRIPT_VERSION" {
  run --separate-stderr bash -c \
    'cd "$1" && make --no-print-directory release-check TAG="v$2"' \
    _ "$ROOT" "$VERSION"
  assert_status 0
  assert_output_contains "matches SCRIPT_VERSION=$VERSION"
}

@test "make release-check fails naming the mismatch when TAG is wrong" {
  run --separate-stderr bash -c \
    'cd "$1" && make --no-print-directory release-check TAG=v9.9.9' \
    _ "$ROOT"
  # GNU make exits 2 on any error in a recipe, per its manual's "Summary of
  # Options" - not merely "non-zero" - which is why 2 is asserted here and
  # at every other release-check/release-notes failure below.
  assert_status 2
  assert_stderr_contains "TAG=v9.9.9 does not match v$VERSION"
}

@test "make release-check treats a tag with shell metacharacters as text, not as a command" {
  # A tag name is whatever was pushed. The recipe reads TAG from the
  # environment as "${TAG}" rather than expanding $(TAG) into the recipe
  # text, because make would substitute the latter before the shell saw it
  # and v";touch pwned;# would run as a command in a workflow that can write
  # to the repository. The mismatch message quotes the tag verbatim and no
  # file is created.
  local marker=$BATS_TEST_TMPDIR/pwned
  run --separate-stderr bash -c 'cd "$1" && make --no-print-directory release-check "TAG=$2"' \
    _ "$ROOT" "v$VERSION\";touch $marker;#"
  assert_status 2
  assert_stderr_contains "release-check: TAG=v$VERSION\";touch $marker;# does not match v$VERSION"
  if [[ -e $marker ]]; then
    printf 'the tag was executed as a command: %s exists\n' "$marker" >&2
    return 1
  fi
}

@test "make release-check quotes the tag it reads, so a splitting tag cannot pass the comparison" {
  # The metacharacter case above covers the $(TAG)-versus-"${TAG}" half of the
  # rule. This covers the other half: the quotes around "${TAG}" itself. The
  # comparison is `test "${TAG}" = "vX.Y.Z"`, and unquoted the shell would
  # split this tag into `test a = b -o vX.Y.Z = vX.Y.Z`, whose -o makes it
  # true - so a TAG that is not the version would pass the gate that exists
  # to stop exactly that. A pushed tag cannot carry a space, so this value
  # stands in for any TAG a caller supplies by hand. The guard rests on
  # /bin/sh's test implementing the obsolescent -o at seven arguments,
  # which POSIX leaves unspecified above four; dash and bash both do, so it
  # bites here and in CI, but a shell whose test errored instead would exit
  # non-zero and pass this test with the quotes gone. Quoted, it fails and
  # the message names the tag whole.
  run --separate-stderr bash -c 'cd "$1" && make --no-print-directory release-check "TAG=$2"' \
    _ "$ROOT" "a = b -o v$VERSION"
  assert_status 2
  assert_stderr_contains "release-check: TAG=a = b -o v$VERSION does not match v$VERSION"
}

@test "make release-check fails with a clear message when TAG is unset" {
  run --separate-stderr bash -c 'cd "$1" && make --no-print-directory release-check' \
    _ "$ROOT"
  assert_status 2
  assert_stderr_contains "release-check: TAG is not set"
}

@test "make release-check fails when the renamed CHANGELOG section no longer matches" {
  # The Makefile reads CHANGELOG.md relative to CURDIR; CHANGELOG ?= CHANGELOG.md
  # lets this test point the same recipe at a doctored copy instead of
  # copying the whole repo into a scratch directory.
  local doctored=$BATS_TEST_TMPDIR/CHANGELOG.md
  sed "s/## \[$VERSION\] - /## [Released] - /" "$CHANGELOG" > "$doctored"
  run --separate-stderr bash -c \
    'cd "$1" && make --no-print-directory release-check TAG="v$2" CHANGELOG="$3"' \
    _ "$ROOT" "$VERSION" "$doctored"
  assert_status 2
  assert_stderr_contains "$doctored's first released section is '## [Released]"
}

@test "make release-check fails when the Unreleased section still has bullets" {
  local doctored=$BATS_TEST_TMPDIR/CHANGELOG.md
  awk '/^## \[Unreleased\]/ { print; print ""; print "- not yet released"; next } \
       { print }' "$CHANGELOG" > "$doctored"
  run --separate-stderr bash -c \
    'cd "$1" && make --no-print-directory release-check TAG="v$2" CHANGELOG="$3"' \
    _ "$ROOT" "$VERSION" "$doctored"
  assert_status 2
  assert_stderr_contains "[Unreleased] section still has content"
}

@test "make release-check fails on an invalid calendar date" {
  local doctored=$BATS_TEST_TMPDIR/CHANGELOG.md
  sed "s/^## \[$VERSION\] - [0-9-]*\$/## [$VERSION] - 2026-99-99/" \
    "$CHANGELOG" > "$doctored"
  run --separate-stderr bash -c \
    'cd "$1" && make --no-print-directory release-check TAG="v$2" CHANGELOG="$3"' \
    _ "$ROOT" "$VERSION" "$doctored"
  assert_status 2
  assert_stderr_contains "date '2026-99-99' is not a valid calendar date"
}

@test "make release-notes prints a non-empty body with no ## heading or link line" {
  run --separate-stderr bash -c 'cd "$1" && make --no-print-directory release-notes' \
    _ "$ROOT"
  assert_status 0
  [[ -n $output ]] || { echo "release-notes printed nothing" >&2; return 1; }
  if grep -qE '^## ' <<<"$output"; then
    printf 'release-notes output still contains a "## " heading line:\n%s\n' "$output" >&2
    return 1
  fi
  if grep -qE '^\[[^]]+\]: ' <<<"$output"; then
    printf 'release-notes output still contains a link reference line:\n%s\n' "$output" >&2
    return 1
  fi
}

@test "make release-notes fails on an empty section" {
  local doctored=$BATS_TEST_TMPDIR/CHANGELOG.md
  awk -v ver="[$VERSION]" '
    index($0, "## " ver " ") == 1 { print; getline; print ""; skipping = 1; next }
    skipping && /^## / { skipping = 0 }
    !skipping { print }
  ' "$CHANGELOG" > "$doctored"
  run --separate-stderr bash -c \
    'cd "$1" && make --no-print-directory release-notes CHANGELOG="$2"' \
    _ "$ROOT" "$doctored"
  assert_status 2
  assert_stderr_contains "release-notes: empty body for [$VERSION]"
}
