# agbox

**Turn a fresh Debian/Ubuntu machine into a smooth home for AI coding agents, in one command.**

Mini PC in a closet, old laptop, or $5 VPS: agbox sets it up so Claude Code, Codex and
opencode can install things, run builds, start databases and test web apps **without tripping
over sandboxes, AppArmor, sudo prompts or missing toolchains**.

```bash
curl -fsSL https://raw.githubusercontent.com/antomanc/agbox/main/install.sh | bash
```

[![CI](https://github.com/antomanc/agbox/actions/workflows/ci.yml/badge.svg)](https://github.com/antomanc/agbox/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## Why

Running agents on a headless Linux box usually means a pile of small failures:
- bubblewrap sandboxes blocked by Ubuntu's AppArmor
- `node` found in your shell but not in the agent's
- password prompts mid-task
- services that die on reboot
- a database installed three different ways

agbox fixes these once, with defaults that come from actually running agents on a box like
this.

## What you get

| | |
|---|---|
| **Agents** | Claude Code, Codex, opencode, with one shared `AGENTS.md` that tells them what this machine is and how to work on it |
| **No friction** | Non-root user with passwordless sudo. Agents run without prompts, because the machine is the sandbox ([why](docs/security.md)) |
| **Toolchains** | [mise](https://mise.jdx.dev): Node, Python, uv, pnpm... working in interactive shells, agent shells *and* systemd services |
| **Services** | Docker Engine + Compose for Postgres/Mongo/Redis. Optional always-on [t3code](https://github.com/pingdotgg/t3code) and [Hermes Agent](https://github.com/NousResearch/hermes-agent) |
| **Web testing** | Playwright headless Chromium with all system libraries |
| **Access** | Tailscale + Tailscale SSH from anywhere, no open ports |
| **Safety net** | btrfs snapshots every hour (roll back anything an agent breaks), auto security updates, key-only SSH on VPSs |
| **Small machines** | zram compressed swap, Docker log rotation |

## Quick start

**Existing Debian 12/13 or Ubuntu 24.04/26.04 machine**, as your normal user:

```bash
curl -fsSL https://raw.githubusercontent.com/antomanc/agbox/main/install.sh | bash
```

**Fresh VPS**, as root. This creates user `dev` with your SSH key, locks SSH down and enables
the firewall:

```bash
curl -fsSL https://raw.githubusercontent.com/antomanc/agbox/main/install.sh | \
  AGBOX_TAILSCALE_AUTHKEY=tskey-auth-... bash -s -- --profile vps --yes
```

**Bare metal, fully unattended**: generate a Debian preseed, boot it from a Ventoy stick and
walk away. [→ docs/unattended-install.md](docs/unattended-install.md)

```bash
agbox preseed --hostname home-server --ssh-key ~/.ssh/id_ed25519.pub -o preseed.cfg
```

agbox shows its plan and asks before changing anything. Answer `c` to **customize**: a few
quick questions (profile, agents, permissions, services, components, user, hostname,
timezone, git identity), then the updated plan. When it's done, it prints the few things only
you can do (agent logins, `gh auth login`), then:

```console
$ agbox doctor
agents
  ✓ claude installed
  ✓ codex installed
mise
  ✓ node available in agent (login) shells
  ...
All good (0 warning(s))
```

## Commands

```
agbox setup      Apply the configuration (idempotent: safe to re-run)
agbox doctor     Check everything, with the fix for each problem
agbox preseed    Generate a Debian preseed.cfg for a hands-off install
agbox config     Print the effective configuration
agbox modules    List modules and whether they are enabled
agbox update     Update agbox itself
```

Useful flags: `--dry-run` (show every command, change nothing), `--only agents,mise`,
`--skip docker`, `--profile vps`, `--set KEY=VALUE`, `--yes`.

## Configure

Zero config works. For the common choices, answer `c` at the `Apply?` prompt. Everything is a
setting: pass `--set` or edit `/etc/agbox/agbox.conf` and re-run. Your choices are saved
there, so the next run starts from them.

```bash
agbox setup --set AGENTS="claude opencode" --set SERVICES=t3code --set PLAYWRIGHT=false
agbox setup --set AGENT_MODE=sandboxed       # keep prompts + sandboxes instead
agbox setup --set DOCKER_DATA_ROOT=/home/docker
```

[→ All settings](docs/configuration.md) · [Example configs](examples/)

## Design

- **Idempotent.** Every step checks before acting. Re-running is how you update and repair.
- **Honest dry-run.** Every change goes through one of four primitives, so `--dry-run` shows
  exactly what would happen.
- **Respects your files.** agbox edits `~/.bashrc`, `CLAUDE.md` and friends only inside marked
  blocks, and merges JSON/TOML settings instead of overwriting them.
- **No surprises with secrets.** The config file is parsed, never executed, and auth keys
  are never printed or saved.
- **Plain Bash, no dependencies.** It runs on a box that has nothing yet (that's the point),
  and is easy to read before you pipe it into a shell.

## Security model

By default, agents run without permission prompts, as a non-root user with passwordless
sudo. That's reasonable on a **dedicated, disposable machine** with snapshots and git, and
it's the opposite of reasonable on your daily laptop. Keep personal credentials off the box.
[→ docs/security.md](docs/security.md)

## Related

[aginit](https://github.com/antomanc/aginit) bootstraps *projects* for AI agents
(instructions, skills, test tooling). agbox prepares the *machine*. Use them together:
`agbox setup`, then `npx @antomanc/aginit` in a new project.

## Contributing

Issues and PRs welcome. Adding a module is ~50 lines: see [CONTRIBUTING.md](CONTRIBUTING.md).
`make check` runs lint, docs check and tests.

## License

[MIT](LICENSE) © 2026 Antonio Mancuso
