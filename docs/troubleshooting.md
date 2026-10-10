# Troubleshooting

Start with `agbox doctor`: every failed check prints the command that fixes it. agbox is
idempotent, so re-running `agbox setup` (or `agbox setup --only <module>`) is always safe.

## Logging in to agents on a headless machine

**Claude Code**: run `claude`, open the printed URL on any device, and paste the code back.
The first start in bypass mode asks you to accept the warning once.

**Codex**: `codex login --device-auth` is easiest. If your organization blocks device codes,
use the browser flow, which redirects to `127.0.0.1:1455` *on the machine running Codex*.
Two ways to bridge that:

1. **SSH tunnel** (cleanest). From your laptop:
   ```bash
   ssh -L 1455:127.0.0.1:1455 dev@home-server
   codex login        # open the URL in your laptop's browser; it completes by itself
   ```
2. **Paste the callback.** Run `codex login` and keep it waiting. Sign in from your laptop,
   then copy the `http://127.0.0.1:1455/auth/callback?...` URL from the browser's address
   bar, even though the page fails to load. From a **second** SSH session:
   ```bash
   curl -L "http://127.0.0.1:1455/auth/callback?code=...&state=..."
   ```
   The URL must come from the run that is currently waiting (the `state=` must match).
   Without `-L` the login may not finish.

**Fallback**: copy `~/.codex/auth.json` from a machine where you're already logged in.

## "permission denied" on docker right after setup

Group membership applies to new logins. Log out and back in, or run `newgrp docker`.

## A tool works in my shell but not for the agent

Agents start login shells, and systemd services start with almost no environment. agbox wires
mise into all three. Check with:

```bash
bash -lc 'command -v node'                    # what agents see
systemctl --user show-environment | grep PATH  # what services see
```

If you added tools to `~/.bashrc` yourself, move the PATH changes into `~/.profile`.

## Sandbox errors (`bwrap: ... Operation not permitted`)

You're in `AGENT_MODE=sandboxed` on Ubuntu 24.04+, where AppArmor restricts user namespaces.
Run `agbox setup --only agents` to load the bubblewrap AppArmor profile, then `agbox doctor`.
If it still fails, `AGENT_MODE=yolo` on a dedicated machine is the reliable option (see
[security.md](security.md)).

## Boot drops to a `grub>` prompt after reinstalling

Firmware is booting an old bootloader entry. Boot Debian once from the firmware boot menu,
then:

```bash
sudo efibootmgr                       # find stale entries, e.g. "ubuntu"
sudo efibootmgr -b 0000 -B            # delete one (use its number)
sudo grub-install --target=x86_64-efi --efi-directory=/boot/efi --force-extra-removable
sudo update-grub
```

The preseed install wipes the disk and installs to the removable path, which avoids this.

## First-boot setup didn't finish

```bash
journalctl -u agbox-firstboot          # what happened
sudo agbox setup                        # just run it again: completed steps are skipped
```

## Undo what an agent did to the system

```bash
sudo snapper list                       # find the snapshot from before
sudo snapper status N..0                # what changed since
sudo snapper undochange N..0            # revert those files
```
