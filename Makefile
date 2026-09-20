# Development tasks for forgejo-upgrade.sh. None of this is needed to run the
# script on a server: it needs only the tools listed in AGENTS.md. These
# targets need shellcheck, bats-core and, for coverage, kcov.
#
#   make lint            shellcheck over the script, the helpers, the link checker and every stub
#   make test            the offline suite
#   make test-live       the suite that talks to the release API and a keyserver
#   make links           check every https:// URL in the docs and script (network)
#   make coverage        line coverage of the offline suite
#   make coverage-all    line coverage of both suites, merged
#   make release-check   verify TAG, SCRIPT_VERSION and CHANGELOG.md agree
#   make release-notes   print the CHANGELOG.md section for SCRIPT_VERSION
#
# Override the tool paths when they are not on PATH, e.g.
#   make test BATS=/opt/bats-core/bin/bats

BATS       ?= bats
KCOV       ?= kcov
SHELLCHECK ?= shellcheck

SCRIPT    := forgejo-upgrade.sh
CHANGELOG ?= CHANGELOG.md

# Read out of the script rather than duplicated here, so a version bump only
# ever happens in one place.
SCRIPT_VERSION := $(shell sed -n 's/^SCRIPT_VERSION=//p' $(SCRIPT))

# $(wildcard) rather than a bare glob so a target still runs when one of these
# directories is empty: an unmatched glob would be handed to shellcheck as a
# literal path and fail as a missing file.
SHELL_SOURCES := $(SCRIPT) tests/helpers.bash tests/verify-links.sh \
                 $(wildcard tests/unit/*.bats) \
                 $(wildcard tests/live/*.bats) \
                 $(wildcard tests/fixtures/bin/*) \
                 $(wildcard tests/fixtures/nounits/*) \
                 $(wildcard tests/fixtures/curl/*/curl)

.PHONY: all lint test test-live links coverage coverage-all report clean \
        release-check release-notes

all: lint test

lint:
	$(SHELLCHECK) $(SHELL_SOURCES)

test:
	$(BATS) tests/unit

test-live:
	$(BATS) tests/live

# Fetches every https:// URL cited in README.md, docs/*.md, AGENTS.md,
# CLAUDE.md, CHANGELOG.md and the script; see tests/verify-links.sh's own
# header for what each check does. Needs outbound network access.
links:
	./tests/verify-links.sh

# kcov follows the child bash processes the harness starts, so the lines that
# run inside `in_script` are attributed to the sourced script. --include-path
# keeps the report to this one file. The percentage is read out of kcov's own
# JSON with sed: no jq, for the same reason the script itself has none.
coverage:
	rm -rf coverage/unit
	mkdir -p coverage/unit
	$(KCOV) --include-path=$(CURDIR)/$(SCRIPT) coverage/unit $(BATS) tests/unit
	@$(MAKE) --no-print-directory report REPORT_DIR=coverage/unit

coverage-all:
	rm -rf coverage/unit coverage/live coverage/all
	mkdir -p coverage/unit coverage/live coverage/all
	$(KCOV) --include-path=$(CURDIR)/$(SCRIPT) coverage/unit $(BATS) tests/unit
	$(KCOV) --include-path=$(CURDIR)/$(SCRIPT) coverage/live $(BATS) tests/live
	$(KCOV) --merge coverage/all coverage/unit coverage/live
	@$(MAKE) --no-print-directory report REPORT_DIR=coverage/all

# Prints the covered percentage kcov recorded for the script: from
# kcov-merged/coverage.json after a merge, else from the single run's own
# coverage.json. A JSON with no readable percent_covered fails the target
# rather than printing a blank number and passing CI. kcov's idea of an
# executable line in bash is a heuristic, so this is a trend, not a truth.
# kcov creates its output directory but not the parent, hence the mkdir above.
report:
	@f="$(REPORT_DIR)/kcov-merged/coverage.json"; \
	  [ -f "$$f" ] || f=$$(find "$(REPORT_DIR)" -name coverage.json | head -n 1); \
	  [ -n "$$f" ] || { echo "no coverage.json under $(REPORT_DIR)" >&2; exit 1; }; \
	  pct=$$(sed -n 's/.*"percent_covered"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' "$$f" | head -n 1); \
	  [ -n "$$pct" ] || { echo "no percent_covered in $$f; the kcov output format may have changed" >&2; exit 1; }; \
	  echo "$(SCRIPT) line coverage: $$pct%"

clean:
	rm -rf coverage

# The release workflows' check step, run before anything is published: fail
# if the tag, the script, and the changelog disagree. Every check names what
# it expected and what it found; `TAG` has no default, since a mistyped or
# forgotten TAG must stop the release rather than silently check v0.0.0.
# TAG is read from the environment as "$${TAG}", never expanded as $(TAG)
# into the recipe text: make substitutes $(TAG) before the shell sees the
# line, so a tag such as v";id;# would run as a command. A variable given on
# make's command line is exported to the recipe's environment, which is how
# the release workflows pass it.
release-check:
	@test -n "$${TAG:-}" || { \
	  echo "release-check: TAG is not set; run as, e.g., make release-check TAG=v$(SCRIPT_VERSION)" >&2; \
	  exit 1; }
	@test "$${TAG}" = "v$(SCRIPT_VERSION)" || { \
	  echo "release-check: TAG=$${TAG} does not match v$(SCRIPT_VERSION) (SCRIPT_VERSION in $(SCRIPT))" >&2; \
	  exit 1; }
	@got=$$(./$(SCRIPT) version) && [ "$$got" = "forgejo-upgrade $(SCRIPT_VERSION)" ] || { \
	  echo "release-check: '$(SCRIPT) version' printed '$$got', want 'forgejo-upgrade $(SCRIPT_VERSION)'" >&2; \
	  exit 1; }
	@body=$$(awk '/^## \[Unreleased\]/ { seen = 1; next } \
	                  seen && /^## \[/ { exit } \
	                  seen { print }' $(CHANGELOG)); \
	  if echo "$$body" | grep -qE '[^[:space:]]'; then \
	    echo "release-check: $(CHANGELOG)'s [Unreleased] section still has content; move its bullets under the new version section first" >&2; \
	    exit 1; \
	  fi
	@heading=$$(awk '/^## \[Unreleased\]/ { seen = 1; next } \
	                  seen && /^## \[/ { print; exit }' $(CHANGELOG)); \
	  echo "$$heading" \
	    | grep -qE '^## \[$(subst .,\.,$(SCRIPT_VERSION))\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$$' || { \
	    echo "release-check: $(CHANGELOG)'s first released section is '$$heading', want '## [$(SCRIPT_VERSION)] - YYYY-MM-DD'" >&2; \
	    exit 1; }; \
	  d=$${heading##*- }; \
	  got=$$(date -d "$$d" +%F 2>/dev/null); \
	  [ -n "$$got" ] && [ "$$got" = "$$d" ] || { \
	    echo "release-check: $(CHANGELOG)'s date '$$d' is not a valid calendar date" >&2; \
	    exit 1; }
	@echo "release-check: TAG=$${TAG} matches SCRIPT_VERSION=$(SCRIPT_VERSION) and $(CHANGELOG)'s first released section"

# The release workflows' notes step: the body of the current version's own
# CHANGELOG.md section, trimmed of the blank lines Keep a Changelog leaves
# around each heading, becomes the release notes handed to gh and
# forgejo-release. Empty is a hard failure, not a release with no notes. The
# section also ends at a reference-style link definition ("[x.y.z]: url"),
# not just the next "## " heading, because the oldest release in the file has
# no heading after it and its body would otherwise run into that block.
release-notes:
	@body=$$(awk -v ver="[$(SCRIPT_VERSION)]" ' \
	    found && (index($$0, "## ") == 1 || $$0 ~ /^\[.*\]: /) { exit } \
	    found { print } \
	    index($$0, "## " ver " ") == 1 { found = 1 } \
	  ' $(CHANGELOG) | sed -e '/./,$$!d' -e :a -e '/^\n*$$/{$$d;N;ba}'); \
	  [ -n "$$body" ] || { \
	    echo "release-notes: empty body for [$(SCRIPT_VERSION)] in $(CHANGELOG)" >&2; \
	    exit 1; }; \
	  printf '%s\n' "$$body"
