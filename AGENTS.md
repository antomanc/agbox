# Instructions for AI agents working on agbox

agbox is a Bash tool that sets up Debian/Ubuntu machines for AI coding agents. Read
CONTRIBUTING.md first: the module rules there are mandatory.

- Run `make check` before finishing (shellcheck, generated-docs check, bats tests). All
  tests are dry-run and safe to run anywhere.
- Never mutate the system outside the primitives in `lib/core.sh` (`run_root`, `run_user`,
  `run_script`, `write_file`, `ensure_block`, `apt_install`, `apt_add_repo`): they implement
  `--dry-run`.
- Every module must stay idempotent: a second `agbox setup` changes nothing.
- New settings go in `AGBOX_SCHEMA` with validation, then run `make docs`.
- Use `if ...; then ...; fi` instead of `cond && cmd` (`set -e` safety).
- Keep it dependency-free Bash 5. No new runtime dependencies.
- Add a bats test for any pure function or CLI behaviour you add or change.
