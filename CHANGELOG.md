# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
