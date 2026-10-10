# Contributing

Thanks for helping! agbox is plain Bash on purpose: it has to run on a machine that has
nothing installed yet, and people should be able to read it before piping it into a shell.

## Development

```bash
make check     # shellcheck + docs check + bats tests (all safe: dry-runs only)
make dry-run   # what would `agbox setup` do on this machine?
```

Requirements: `shellcheck` and `bats`. Tests never change the host, except one root-only
test that writes inside a temp dir.

CI also runs a **real install on a GitHub Ubuntu VM**, then `agbox doctor`, then a second run
that must change nothing. Before a release, also test on a VM: Debian 13 and Ubuntu 24.04,
`--profile vps` as root, and the preseed path in QEMU or VirtualBox.

## Layout

```
bin/agbox            CLI: option parsing, commands, preflight, summary
install.sh           curl | bash bootstrap: download, install to /opt/agbox, run setup
lib/core.sh          logging, privileges, dry-run-aware primitives, apt helpers, doctor checks
lib/config.sh        schema, profiles, config parsing and validation
lib/os.sh            distro detection, host facts
lib/modules.sh       module registry and selection
lib/preseed.sh       `agbox preseed`
lib/wizard.sh        the Apply?/customize prompt of `agbox setup` (answers become --set overrides)
modules/*.sh         one file per feature
docs/                user docs (configuration.md's table is generated)
tests/*.bats         tests
```

## Writing a module

A module is `modules/<name>.sh` with four functions, plus its name in `MODULES` in
`lib/modules.sh` (order matters: later modules may rely on earlier ones).

```bash
# shellcheck shell=bash
# One line on what this module is for.

example::describe() { echo "what it does, shown in plans"; }
example::enabled() { [[ $AGBOX_EXAMPLE == true ]]; }

example::apply() {
  apt_install some-package                       # skips installed packages
  write_file root /etc/example.conf 0644 <<'EOF'  # only writes if content differs
key = value
EOF
  if [[ $FILE_CHANGED == true ]]; then run_root systemctl restart example; fi
}

example::check() {
  check systemctl is-active --quiet example -- "example running" "agbox setup --only example"
}
```

### The rules

1. **Every change goes through a primitive**: `run_root`, `run_user`, `run_script`,
   `write_file`, `ensure_block`, `apt_get`, `apt_install`, `apt_add_repo`. They implement `--dry-run`, so
   never call `sudo`, `>` or `tee` directly to change the system. Read-only commands
   (`as_root test -f`, `dpkg-query`) are fine anywhere.
2. **Idempotent**: check before acting, and `log_skip` what's already done. A second
   `agbox setup` must change nothing (CI enforces this).
3. **Never clobber user files**: use `ensure_block` for files people edit, and merge JSON with
   `jq` or TOML with `toml_set_top`.
4. **Work before the user exists** in dry-run: use `user_path`, `target_exists`, `user_has`.
5. **Don't hide failures**: no `|| true` on things that matter. Fail with `die "what to do"`.
6. **Settings** go in `AGBOX_SCHEMA` (lib/config.sh) with a default and description, plus
   validation in `validate_config`. Then run `make docs`.
7. **Lines that only run when a condition holds** use `if ...; then ...; fi`, not `cond && cmd`,
   which can leak a failing status under `set -e`.

## Commits and releases

- Conventional, descriptive commit messages. Update `CHANGELOG.md` under *Unreleased*.
- Release: bump `VERSION`, move the changelog entries, tag `vX.Y.Z`.
