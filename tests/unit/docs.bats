#!/usr/bin/env bats
# Every relative markdown link among README.md, docs/*.md, AGENTS.md,
# CLAUDE.md, and CHANGELOG.md: the target file has to exist relative to the
# file that links it, and if the link has an anchor, some heading in the
# target has to slug to it. Splitting README.md into docs/ (PR #3) created a
# class of breakage
# nothing else in this suite catches — markdownlint does not resolve
# relative links, and neither does shellcheck. `https://` URLs are a
# separate concern, checked by tests/verify-links.sh, not here.
#
# The slug rule follows what GitHub and goldmark do to a heading: lowercase,
# keep letters, digits, spaces, hyphens and underscores and drop everything
# else (this is what turns "About `latest`" into "about-latest"), then turn
# spaces into hyphens. It is the common core of the two, not a full copy of
# either.

# The sed pattern that strips inline code spans is single-quoted on purpose:
# it is a literal backtick pattern, not a shell expansion, and that is
# exactly what SC2016 warns about.
# shellcheck disable=SC2016

# `run --separate-stderr` is a 1.5.0 feature; saying so here turns bats'
# BW02 warning into a version requirement it checks.
bats_require_minimum_version 1.5.0

setup() {
  load ../helpers
  common_setup
  ROOT=$(dirname "$SCRIPT")
}

# --- the checker -------------------------------------------------------------
#
# Plain bash functions, not calls into forgejo-upgrade.sh, so they run
# directly in the bats process rather than through in_script.

slugify() {
  local input=$1 s
  s=$(LC_ALL=C tr '[:upper:]' '[:lower:]' <<<"$input")
  s=$(LC_ALL=C sed -E 's/[^a-z0-9 _-]//g' <<<"$s")
  printf '%s\n' "${s// /-}"
}

# Every heading's slug in a file, one per line. Headings are lines matching
# ^#{1,6} (the only form this project's markdown uses) outside fenced code
# blocks, where a "# comment" line in a shell example is not a heading.
heading_slugs_in() {
  awk '/^```/ { fenced = !fenced; next } !fenced' "$1" \
    | grep -E '^#{1,6} ' | sed -E 's/^#{1,6} +//' | while IFS= read -r line; do
    slugify "$line"
  done
}

# Every "](target)" link target in a file that is not a URL, one per line: a
# bare path, a "path#anchor", or a same-file "#anchor". Inline code spans are
# stripped first so a literal example — AGENTS.md's own Markdown style
# section cites `[text](url)` — is not mistaken for a real link.
collect_relative_links() {
  sed -E 's/``[^`]*``//g; s/`[^`]*`//g' "$1" \
    | grep -ohE '\]\([^)]+\)' \
    | sed -E 's/^\]\((.*)\)$/\1/' \
    | while IFS= read -r target; do
        case $target in
          http://* | https://* | mailto:*) ;;
          *) printf '%s\n' "$target" ;;
        esac
      done
}

# Check one link target found in file $1. A bare "#anchor" checks against
# $1 itself; anything else resolves relative to $1's own directory, the way
# a markdown viewer resolves it. Reports the failure on stderr and returns 1
# rather than just returning non-zero, so a caller can show what broke.
check_relative_link() {
  local source=$1 target=$2 dir path anchor
  dir=$(dirname "$source")
  if [[ $target == \#* ]]; then
    path=$source
    anchor=${target#\#}
  else
    path=${target%%#*}
    anchor=""
    [[ $target == *#* ]] && anchor=${target#*#}
    path="$dir/$path"
  fi
  if [[ ! -f $path ]]; then
    printf 'in %s: link target "%s" does not exist (looked for %s)\n' \
      "$source" "$target" "$path" >&2
    return 1
  fi
  if [[ -n $anchor ]] \
    && ! heading_slugs_in "$path" | grep -qxF "$(slugify "$anchor")"; then
    printf 'in %s: anchor "#%s" has no matching heading in %s\n' \
      "$source" "$anchor" "$path" >&2
    return 1
  fi
}

# Every relative link in file $1. Reports the count either way, passing or
# failing, so a run that quietly found zero links looks different from one
# that checked some and passed (AGENTS.md: "An ad hoc check that matches
# nothing is broken, not green").
check_file_links() {
  local file=$1 target ok=0 bad=0
  while IFS= read -r target; do
    [[ -z $target ]] && continue
    if check_relative_link "$file" "$target"; then
      ok=$((ok + 1))
    else
      bad=$((bad + 1))
    fi
  done < <(collect_relative_links "$file")
  printf 'checked %d relative link(s) in %s: %d ok, %d broken\n' \
    "$((ok + bad))" "$file" "$ok" "$bad" >&2
  [[ $bad -eq 0 ]]
}

# --- the real files ------------------------------------------------------

@test "every relative link in README.md, docs, AGENTS.md, CLAUDE.md and CHANGELOG.md resolves" {
  local files=("$ROOT/README.md" "$ROOT"/docs/*.md "$ROOT/AGENTS.md" \
    "$ROOT/CLAUDE.md" "$ROOT/CHANGELOG.md")
  local f target total=0 broken=0
  for f in "${files[@]}"; do
    while IFS= read -r target; do
      [[ -z $target ]] && continue
      total=$((total + 1))
      check_relative_link "$f" "$target" || broken=$((broken + 1))
    done < <(collect_relative_links "$f")
  done
  # Zero links found means the extraction broke, not that there is nothing
  # to check: the Documentation index alone puts at least three in README.md.
  if [[ $total -eq 0 ]]; then
    printf 'no relative links found across %s: the extraction is broken\n' \
      "${files[*]}" >&2
    return 1
  fi
  printf 'checked %d relative link(s) across %d files: %d broken\n' \
    "$total" "${#files[@]}" "$broken" >&2
  [[ $broken -eq 0 ]]
}

# --- structural checks -----------------------------------------------------

@test "README.md no longer has the old Hardening or Configuration headings" {
  # Those two sections moved to docs/hardening.md and docs/configuration.md;
  # a heading left behind here would mean the split was reverted in part.
  run grep -nE '^## (Hardening|Configuration)$' "$ROOT/README.md"
  assert_status 1
}

@test "each page under docs/ has exactly one top-level heading" {
  local f count bad=""
  for f in "$ROOT"/docs/*.md; do
    count=$(grep -cE '^# ' "$f")
    [[ $count -eq 1 ]] || bad+="$f has $count top-level (# ) headings, not 1"$'\n'
  done
  if [[ -n $bad ]]; then
    printf '%s' "$bad" >&2
    return 1
  fi
}

@test "the README's Documentation index links every page under docs/" {
  local f base bad=""
  for f in "$ROOT"/docs/*.md; do
    base=$(basename "$f")
    # Only the index itself counts: a pointer elsewhere in the README (the
    # summary links the hardening page) must not stand in for a bullet.
    sed -n '/^## Documentation/,/^## /p' "$ROOT/README.md" | grep -qF "docs/$base" \
      || bad+="README.md's Documentation index has no link to docs/$base"$'\n'
  done
  if [[ -n $bad ]]; then
    printf '%s' "$bad" >&2
    return 1
  fi
}

# --- control ---------------------------------------------------------------

@test "the checker itself fails on a synthetic broken link" {
  # Proves check_file_links reports rather than silently passing: one link
  # to a missing anchor, one to a missing file.
  local f=$BATS_TEST_TMPDIR/broken.md
  cat > "$f" <<'EOF'
# Heading

[missing anchor](#does-not-exist)
[missing file](does-not-exist.md)
EOF
  run --separate-stderr check_file_links "$f"
  assert_status 1
  assert_stderr_contains 'anchor "#does-not-exist" has no matching heading'
  assert_stderr_contains 'link target "does-not-exist.md" does not exist'
}
