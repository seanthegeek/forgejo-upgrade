# forgejo-upgrade

A single Bash script that makes binary installs of
[Forgejo](https://forgejo.org) and
[forgejo-runner](https://code.forgejo.org/forgejo/runner) easy: it
[verifies the release signature and checksum](https://forgejo.org/download/#installation-from-binary),
backs up before touching anything, keeps the previous binary for rollback, and
checks that the service came back healthy. It upgrades whichever of the two is
installed on a given host — a host may run Forgejo, the runner, or both. The
runner is optional and is often installed on a separate host from Forgejo;
see [Contain the runner](docs/hardening.md#contain-the-runner) for why.

## Documentation

- [How the script works](docs/how-it-works.md): The step-by-step
  walkthrough of a server and runner upgrade.
- [Installation](docs/installation.md): Instructions for installing forgejo-upgrade.
- [Usage](docs/usage.md): Instructions for using forgejo-upgrade.
- [Configuration](docs/configuration.md): Every setting, where it is
  read from, and its default.
- [Hardening](docs/hardening.md): Reducing what a compromise of Forgejo
  or the runner can reach.
- [Development](docs/development.md): Instructions for development forgejo-upgrade.

## Why this is hosted on GitHub

I use GitHub Copilot AI to double-check the work of Claude Code, as you can see in the PR and commit history.

## License

Apache License 2.0. See `LICENSE`.
