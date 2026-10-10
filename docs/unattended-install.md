# Unattended install

Go from bare metal (or a fresh VPS) to a working agent box without answering a single
question.

## Bare metal: Debian + Ventoy

`agbox preseed` writes a Debian installer [preseed](https://wiki.debian.org/DebianInstaller/Preseed)
file. It answers every question, partitions the disk and installs a first-boot service that
runs `agbox setup` with your settings.

> **Warning:** the preseed **wipes the target disk** without asking. By default it picks the
> first NVMe or virtio disk, so the Ventoy USB stick is never chosen. With a SATA-only machine,
> pass `--disk /dev/sda` explicitly, and double-check it.

What you get:
- GPT, a 1 GiB EFI partition, and **btrfs** on the rest (agbox adds snapshots on top)
- No swap partition (agbox sets up zram)
- No root password: your user gets sudo
- SSH server only, no desktop
- GRUB also installed to the removable EFI path, so picky mini-PC firmware always boots it
- On first boot: `agbox setup --yes` with the embedded config

### 1. Generate the preseed

On any Linux/macOS machine with agbox, or straight from the repo (`bin/agbox`):

```bash
agbox preseed \
  --hostname home-server \
  --user dev \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --keymap it --timezone Europe/Rome \
  --set TAILSCALE_AUTHKEY=tskey-auth-... \
  --set GIT_NAME="Your Name" --set GIT_EMAIL=you@example.com \
  -o preseed.cfg
```

It asks for the user's password, which is stored only as a SHA-512 hash. Any `--set` works,
or pass a whole file with `--config my-agbox.conf`.

Use a **one-off Tailscale auth key**: the generated file contains it, so treat
`preseed.cfg` as a secret and delete it from the stick afterwards.

### 2. Put it on the Ventoy stick

```
/debian-13.x.x-amd64-netinst.iso
/ventoy/preseed.cfg
/ventoy/ventoy.json
```

```json
{
  "auto_install": [
    { "image": "/debian-13.x.x-amd64-netinst.iso", "template": "/ventoy/preseed.cfg" }
  ]
}
```

Use your ISO's exact file name. See Ventoy's
[auto install plugin](https://www.ventoy.net/en/plugin_autoinstall.html).

### 3. Boot and walk away

Boot from the stick, select the ISO, and choose the preseed template. The machine installs
Debian, reboots, and runs agbox. Follow along from another machine:

```bash
ssh dev@home-server 'journalctl -fu agbox-firstboot'
```

When it finishes, `agbox doctor` shows what's left. Usually that's logging the agents in.
The first-boot unit runs once: a marker in `/var/lib/agbox/firstboot.done` prevents repeats.

## VPS: cloud-init

Most providers accept cloud-init "user data" when you create a server:

```yaml
#cloud-config
runcmd:
  - >-
    curl -fsSL https://raw.githubusercontent.com/antomanc/agbox/main/install.sh |
    AGBOX_TAILSCALE_AUTHKEY=tskey-auth-... bash -s -- --profile vps --yes
```

The `vps` profile creates the `dev` user, copies root's SSH keys to it, turns SSH key-only
with no root login, and enables the firewall (SSH + Tailscale only). After that, log in as
`dev`, preferably over Tailscale.

## VPS or existing machine: one command

```bash
curl -fsSL https://raw.githubusercontent.com/antomanc/agbox/main/install.sh | bash -s -- --profile vps
```

Pin a release for reproducible installs with `AGBOX_REF=v0.1.0`.
