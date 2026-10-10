# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `agbox setup` asks `Apply? [Y]es / [n]o / [c]ustomize`. Customize goes through the
  settings that vary between machines (profile, agents, agent mode, services, components,
  user, hostname, timezone, git identity), then shows the updated plan. Answers are applied
  like `--set` and saved to the config file. Runs with `--yes`, `--dry-run` or without a
  terminal never ask.
- Hermes Agent gets the shared `AGENTS.md` too: `~/.hermes/SOUL.md` (the one file Hermes
  loads in every session) gets a managed block pointing at it, and `agbox doctor` checks it.

### Changed
- An existing `~/.claude/CLAUDE.md` gets a one-line import of the shared `AGENTS.md` instead
  of a full copy, so edits to the shared file reach Claude too.
- The `devtools` line in the plan only lists the GitHub CLI and Playwright when they are
  enabled.

## [0.1.0] - 2026-10-10

### Added
- `agbox setup` with 11 idempotent modules: system, user, ssh, firewall, tailscale, docker,
  mise, agents, devtools, services, snapshots.
- `homelab` and `vps` profiles, a parsed (never sourced) config file, `--set` overrides and
  `--only`/`--skip`.
- `--dry-run` that prints every command and file write.
- `agbox doctor` with a fix hint for every failed check.
- `agbox preseed`: unattended Debian install (GPT + EFI + btrfs, no swap) with a first-boot
  `agbox setup`, plus Ventoy instructions.
- Agents: Claude Code, Codex, opencode, in `yolo` or `sandboxed` mode, sharing one generated
  `AGENTS.md`.
- `curl | bash` installer with atomic upgrades and `agbox update`.
