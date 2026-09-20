# Development tasks for forgejo-upgrade.sh. None of this is needed to run the
# script on a server: it needs only the tools listed in AGENTS.md. These
# targets need shellcheck, bats-core and, for coverage, kcov.
#
#   make lint           shellcheck over the script, the helpers and every stub
#   make test           the offline suite
#   make test-live      the suite that talks to the release API and a keyserver
#   make coverage       line coverage of the offline suite
#   make coverage-all   line coverage of both suites, merged
#
# Override the tool paths when they are not on PATH, e.g.
#   make test BATS=/opt/bats-core/bin/bats

BATS       ?= bats
KCOV       ?= kcov
SHELLCHECK ?= shellcheck

SCRIPT  := forgejo-upgrade.sh

# $(wildcard) rather than a bare glob so a target still runs when one of these
# directories is empty: an unmatched glob would be handed to shellcheck as a
# literal path and fail as a missing file.
SHELL_SOURCES := $(SCRIPT) tests/helpers.bash \
                 $(wildcard tests/unit/*.bats) \
                 $(wildcard tests/live/*.bats) \
                 $(wildcard tests/fixtures/bin/*) \
                 $(wildcard tests/fixtures/curl/*/curl)

.PHONY: all lint test test-live coverage coverage-all report clean

all: lint test

lint:
	$(SHELLCHECK) $(SHELL_SOURCES)

test:
	$(BATS) tests/unit

test-live:
	$(BATS) tests/live

# kcov follows the child bash processes the harness starts, so the lines that
# run inside `in_script` are attributed to the sourced script. --include-path
# keeps the report to this one file. The percentage is read out of kcov's own
# JSON with sed: no jq, for the same reason the script itself has none.
coverage:
	rm -rf coverage/unit
	$(KCOV) --include-path=$(CURDIR)/$(SCRIPT) coverage/unit $(BATS) tests/unit
	@$(MAKE) --no-print-directory report REPORT_DIR=coverage/unit

coverage-all:
	rm -rf coverage/unit coverage/live coverage/all
	$(KCOV) --include-path=$(CURDIR)/$(SCRIPT) coverage/unit $(BATS) tests/unit
	$(KCOV) --include-path=$(CURDIR)/$(SCRIPT) coverage/live $(BATS) tests/live
	$(KCOV) --merge coverage/all coverage/unit coverage/live
	@$(MAKE) --no-print-directory report REPORT_DIR=coverage/all

# Prints the covered percentage kcov recorded for the script. kcov's idea of an
# executable line in bash is a heuristic, so this is a trend, not a truth.
report:
	@sed -n 's/.*"percent_covered"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' \
	  "$(REPORT_DIR)/kcov-merged/coverage.json" | head -n 1 \
	  | sed 's|^|$(SCRIPT) line coverage: |; s|$$|%|'

clean:
	rm -rf coverage
