# Security model

agbox is opinionated: **the machine is the sandbox.** This page explains what that means, so
you can decide whether it fits.

## Why not per-agent sandboxes?

Claude Code and Codex sandbox commands with bubblewrap on Linux. On Ubuntu 24.04+, AppArmor
blocks the user namespaces bubblewrap needs, and even with the documented profile, network
namespace setup can still fail. Agents then hit errors, ask for approvals all the time, or fall
back to running unsandboxed anyway. On a dedicated, disposable machine, those layers cost a lot
of reliability for little protection.

So by default (`AGENT_MODE=yolo`) agbox:
- runs agents as a normal, **non-root** user with **passwordless sudo**
- turns off approval prompts (`bypassPermissions` for Claude Code, `danger-full-access` +
  `approval_policy = "never"` for Codex)
- relies on boundaries *around* the machine instead

## The boundaries

| Risk | Mitigation |
|---|---|
| An agent breaks the OS | btrfs snapshots: `sudo snapper list`, then `sudo snapper undochange N..0`, or roll back the whole root |
| An agent deletes or ruins code | git: commit often and push (`AGENTS.md` tells agents to) |
| Exposure to the internet | Tailscale for access. `vps` profile: ufw firewall, key-only SSH, no root login |
| A prompt-injected agent reads secrets | **Keep valuable secrets off the box.** Agent logins and project `.env` files *are* reachable by the agent |
| Long-lived compromise | Reinstall: with `agbox preseed` it's one unattended boot |

## What to keep off the machine

- Your personal SSH key: use a dedicated key, or GitHub fine-grained tokens via `gh auth login`
- Production database credentials and cloud admin keys
- Password manager exports, personal documents

## Prefer prompts and sandboxes?

```bash
agbox setup --set AGENT_MODE=sandboxed --set PASSWORDLESS_SUDO=false
```

This configures Claude Code's sandbox and Codex's `workspace-write` + `on-request`, installs
bubblewrap, and loads Ubuntu's `bwrap-userns-restrict` AppArmor profile where needed. `agbox
doctor` then checks that bubblewrap can actually create a sandbox.

## Docker and the firewall

Ports published by Docker (`-p 8080:80`) bypass ufw, because Docker writes its own iptables
rules. Publish to localhost (`-p 127.0.0.1:8080:80`) and reach services over Tailscale. The
generated `AGENTS.md` tells agents to do this.

## Reporting vulnerabilities

See [SECURITY.md](../SECURITY.md).
