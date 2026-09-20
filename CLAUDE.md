# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## Model roles

Any new feature or modification to an existing feature must follow this model
split:

1. **Plan with Fable** (fall back to Opus only if Fable is unavailable). Enter
   plan mode, design the change, and present the plan to the user for
   approval or modification. Do not start implementing until the user
   approves the plan.
2. **Implement with Sonnet by default; use Opus for large or complex work.**
   Once the plan is approved, carry out the implementation by delegating to
   subagents via the Agent tool. Use `model: "sonnet"` for routine,
   well-scoped changes: a README correction, a new environment variable
   with a default, a clearer log message. Use `model: "opus"` for anything
   touching `fetch_and_verify`, `ensure_key`, the version parsers, or the
   stop, backup, install, start sequence. Those are the places where code
   that looks right is wrong and the failure is silent or leaves a server
   down. When in doubt, decide at planning time and note the choice in the
   plan.
3. **Review with Opus in a loop, then once with Fable.** After
   implementation, all work is reviewed in fresh context before it is
   considered done. Every round, whichever model runs it, uses the prompt
   in AGENTS.md's "The fresh-context review prompt" verbatim, apart from
   the one substitution allowed (the branch base, if it is not
   `origin/main`) and the one addition (a one-line header naming the
   repository path and branch and, from the second round on, the files
   changed since the previous round), and includes `make test-live` when
   the diff touches any function AGENTS.md's Testing section names for it.
   - **The rounds run on Opus.** Each one is a fresh subagent with
     `model: "opus"` that has seen none of the work and reads the
     committed diff. Fix what it finds, commit, and run another Opus
     round, until a pass finds nothing beyond wording (the text stays true
     and only reads better). A finding that changes what runs, what an
     operator would paste, or what a sentence claims about the code or an
     upstream source, including any sentence that is wrong, gets another
     round.
   - **The final review runs on Fable**, once, on the final diff, and it
     is the gate on "done". Wording-only findings are fixed without
     another round. Anything substantive goes back through the Opus loop:
     fix, commit, one Opus round scoped to the files changed since, then
     Fable again.
   - If Fable is unavailable, Opus runs the final review too, and the
     summary says the last review was Opus rather than claiming it was
     Fable.

**PR reviews** must also use Fable, with Opus as the fallback if Fable is
unavailable.

@AGENTS.md

## Claude Code

- Before changing `fetch_and_verify`, `ensure_key`, or either version parser,
  re-read the "Facts about Forgejo release artifacts" section in `AGENTS.md`.
  Every item there was a bug found by running against a real release, and
  the obvious-looking code was the wrong code.
- After any change to those functions, or to any other function AGENTS.md's
  Testing section names for the live suite, run `make test-live` (and
  `make test`) and include the output in your summary. Lint alone is not
  evidence here.
- This machine does not run Forgejo. Do not claim the stop, backup, install,
  start sequence was tested. Say it was reviewed and not executed.
- Do not install the script into `/usr/local/sbin` or touch systemd units on
  this machine.
- Tests and fixtures live in `tests/`; nothing is extracted from the script
  any more. If `bats` is not installed, run it from a checkout with
  `make test BATS=/path/to/bats-core/bin/bats`.
