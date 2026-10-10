# shellcheck shell=bash
# `agbox preseed`: generate a Debian installer preseed.cfg for an unattended install
# (single disk, btrfs root, SSH only) that runs `agbox setup` on first boot.

preseed_usage() {
  cat <<'EOF'
Usage: agbox preseed [options] > preseed.cfg

Generates a Debian 12/13 preseed for a hands-off install that WIPES the target disk:
GPT + EFI + btrfs root (snapshots), no swap (zram), SSH server only. On first boot
the machine runs `agbox setup` with the embedded configuration.

Install options:
  --user NAME            Login user (default: dev)
  --hostname NAME        Hostname (default: agbox)
  --password-hash HASH   SHA-512 crypt hash (default: prompt; or openssl passwd -6)
  --ssh-key FILE         Authorized SSH public key(s) for the user (recommended)
  --disk DEVICE|auto     Target disk, e.g. /dev/nvme0n1 (default: auto = first NVMe or
                         virtio disk; the installer asks if there is none)
  --timezone TZ          e.g. Europe/Rome (default: this machine's timezone)
  --keymap LAYOUT        Keyboard layout, e.g. us, it, de (default: us)
  --locale LOCALE        (default: en_US.UTF-8)
  --mirror HOST          Debian mirror (default: deb.debian.org)

agbox options (embedded in /etc/agbox/agbox.conf):
  --config FILE          Base agbox config file
  --profile NAME         homelab or vps
  --set KEY=VALUE        Any agbox setting (repeatable), e.g. --set TAILSCALE_AUTHKEY=tskey-...
  --no-firstboot         Only install Debian; don't run agbox on first boot
  --ref REF              agbox git ref to install on first boot (default: main)

Output:
  -o, --output FILE      Write to FILE instead of stdout

Example (Ventoy):
  agbox preseed --hostname home-server --ssh-key ~/.ssh/id_ed25519.pub \
    --keymap it --set TAILSCALE_AUTHKEY=tskey-auth-... -o /media/ventoy/ventoy/preseed.cfg
EOF
}

cmd_preseed() {
  local user=dev hostname=agbox hash='' ssh_key_file='' disk=auto timezone='' keymap=us
  local locale=en_US.UTF-8 mirror=deb.debian.org config_file='' firstboot=true ref=main output=''
  local -a sets=()
  while (($#)); do
    case $1 in
      --user) user=${2:?}; shift ;;
      --hostname) hostname=${2:?}; shift ;;
      --password-hash) hash=${2:?}; shift ;;
      --ssh-key) ssh_key_file=${2:?}; shift ;;
      --disk) disk=${2:?}; shift ;;
      --timezone) timezone=${2:?}; shift ;;
      --keymap) keymap=${2:?}; shift ;;
      --locale) locale=${2:?}; shift ;;
      --mirror) mirror=${2:?}; shift ;;
      --config) config_file=${2:?}; shift ;;
      --profile) sets+=("PROFILE=${2:?}"); shift ;;
      --set) [[ ${2:-} == *=* ]] || die "--set expects KEY=VALUE"; sets+=("${2#AGBOX_}"); shift ;;
      --no-firstboot) firstboot=false ;;
      --ref) ref=${2:?}; shift ;;
      -o | --output) output=${2:?}; shift ;;
      -h | --help) preseed_usage; return 0 ;;
      *) die "unknown preseed option '$1' (see: agbox preseed --help)" ;;
    esac
    shift
  done

  [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ && $user != root ]] || die "invalid --user '$user'"
  [[ $hostname =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "invalid --hostname '$hostname'"
  [[ $disk == auto || $disk == /dev/* ]] || die "--disk must be 'auto' or a /dev path"
  [[ $keymap =~ ^[a-z]{2,3}(-[a-z0-9]+)?$ ]] || die "invalid --keymap '$keymap'"
  [[ $ref =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid --ref '$ref'"
  if [[ -z $timezone ]]; then
    timezone=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    timezone=${timezone:-Etc/UTC}
  fi

  local ssh_keys=''
  if [[ -n $ssh_key_file ]]; then
    [[ -r $ssh_key_file ]] || die "cannot read --ssh-key $ssh_key_file"
    ssh_keys=$(<"$ssh_key_file")
    [[ $ssh_keys == ssh-* || $ssh_keys == ecdsa-* || $ssh_keys == sk-* ]] ||
      die "$ssh_key_file does not look like an SSH *public* key"
  fi
  [[ -n $hash ]] || hash=$(_preseed_prompt_password)
  [[ $hash == \$6\$* || $hash == \$y\$* ]] || die "--password-hash must be a SHA-512 (\$6\$) or yescrypt (\$y\$) hash"

  local agbox_conf=''
  if [[ $firstboot == true ]]; then
    agbox_conf=$(_preseed_agbox_conf "$config_file" "$user" "$hostname" "$timezone" "${sets[@]}")
  fi

  local rendered
  rendered=$(render_preseed "$user" "$hostname" "$hash" "$disk" "$timezone" "$keymap" "$locale" \
    "$mirror" "$ssh_keys" "$agbox_conf" "$ref")
  if [[ -n $output ]]; then
    printf '%s\n' "$rendered" >"$output"
    log_ok "wrote $output"
    _preseed_ventoy_hint "$output"
  else
    printf '%s\n' "$rendered"
  fi
  if [[ -z $ssh_keys ]]; then
    log_warn "no --ssh-key: you'll log in with the password (SSH hardening stays off until you add a key)"
  fi
}

_preseed_prompt_password() {
  [[ -r /dev/tty ]] || die "no --password-hash given and no terminal to prompt on"
  local p1 p2
  read -rsp "Password for the new user: " p1 </dev/tty && printf '\n' >/dev/tty
  read -rsp "Repeat password: " p2 </dev/tty && printf '\n' >/dev/tty
  [[ -n $p1 ]] || die "empty password"
  [[ $p1 == "$p2" ]] || die "passwords do not match"
  if has_cmd openssl; then
    printf '%s' "$p1" | openssl passwd -6 -stdin
  elif has_cmd mkpasswd; then
    printf '%s' "$p1" | mkpasswd -m sha-512 --stdin
  else
    die "need openssl or mkpasswd to hash the password (or pass --password-hash)"
  fi
}

# Build and validate the agbox config embedded into the installed system.
_preseed_agbox_conf() {
  local config_file=$1 user=$2 hostname=$3 timezone=$4
  shift 4
  local conf='' kv
  if [[ -n $config_file ]]; then
    [[ -r $config_file ]] || die "cannot read --config $config_file"
    conf=$(<"$config_file")$'\n'
  fi
  conf+="# Added by agbox preseed"$'\n'
  conf+="AGBOX_USER=\"$user\""$'\n'"AGBOX_HOSTNAME=\"$hostname\""$'\n'"AGBOX_TIMEZONE=\"$timezone\""$'\n'
  for kv in "$@"; do
    [[ ${kv#*=} != *'"'* ]] || die "--set values must not contain double quotes"
    conf+="AGBOX_${kv%%=*}=\"${kv#*=}\""$'\n'
  done
  # Validate now rather than on first boot, where nobody is watching.
  local tmp
  tmp=$(mktemp)
  printf '%s' "$conf" >"$tmp"
  if ! (load_config "$tmp" >/dev/null); then
    rm -f "$tmp"
    die "invalid agbox configuration for the preseed (see error above)"
  fi
  rm -f "$tmp"
  printf '%s' "$conf"
}

_b64() { printf '%s\n' "$1" | base64 -w0; }

# render_preseed USER HOSTNAME HASH DISK TZ KEYMAP LOCALE MIRROR SSH_KEYS AGBOX_CONF REF
# Pure: prints the preseed file. Every interactive installer question is answered.
render_preseed() {
  local user=$1 hostname=$2 hash=$3 disk=$4 timezone=$5 keymap=$6 locale=$7 mirror=$8
  local ssh_keys=$9 agbox_conf=${10} ref=${11}

  local disk_line
  if [[ $disk == auto ]]; then
    # Prefer internal NVMe / virtio disks over USB sticks (the installer media).
    # shellcheck disable=SC2016 # evaluated by the installer's shell, not here
    disk_line='d-i partman/early_command string D="$(list-devices disk | grep -E "/dev/(nvme|vd)" | head -n1)"; if [ -n "$D" ]; then debconf-set partman-auto/disk "$D"; fi'
  else
    disk_line="d-i partman-auto/disk string $disk"
  fi

  local -a late=()
  if [[ -n $ssh_keys ]]; then
    late+=("in-target sh -c 'install -d -m 0700 -o $user -g $user /home/$user/.ssh && echo $(_b64 "$ssh_keys") | base64 -d > /home/$user/.ssh/authorized_keys && chown $user:$user /home/$user/.ssh/authorized_keys && chmod 0600 /home/$user/.ssh/authorized_keys'")
  fi
  if [[ -n $agbox_conf ]]; then
    local unit
    unit=$(render_firstboot_unit "$ref")
    late+=("in-target sh -c 'install -d -m 0755 /etc/agbox && echo $(_b64 "$agbox_conf") | base64 -d > /etc/agbox/agbox.conf && chmod 0600 /etc/agbox/agbox.conf'")
    late+=("in-target sh -c 'echo $(_b64 "$unit") | base64 -d > /etc/systemd/system/agbox-firstboot.service && systemctl enable agbox-firstboot.service'")
  fi
  local late_line=''
  if ((${#late[@]})); then
    local IFS=';'
    late_line="d-i preseed/late_command string ${late[*]}"
  fi

  cat <<EOF
# Debian preseed generated by agbox $AGBOX_VERSION (https://github.com/$AGBOX_REPO)
# WARNING: wipes ${disk/auto/the first NVMe or virtio disk} without asking.

### Localization
d-i debian-installer/locale string $locale
d-i keyboard-configuration/xkb-keymap select $keymap

### Network
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string $hostname
d-i netcfg/hostname string $hostname
d-i netcfg/get_domain string
d-i hw-detect/load_firmware boolean true

### Mirror
d-i mirror/country string manual
d-i mirror/http/hostname string $mirror
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

### Accounts: no root password, so '$user' gets sudo
d-i passwd/root-login boolean false
d-i passwd/user-fullname string $user
d-i passwd/username string $user
d-i passwd/user-password-crypted password $hash

### Clock
d-i clock-setup/utc boolean true
d-i time/zone string $timezone
d-i clock-setup/ntp boolean true

### Partitioning: GPT, 1 GiB EFI, btrfs root on the rest, no swap (agbox sets up zram)
$disk_line
d-i partman-auto/method string regular
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-partitioning/choose_label select gpt
d-i partman-partitioning/default_label string gpt
d-i partman-efi/non_efi_system boolean true
d-i partman-auto/expert_recipe string agbox :: \\
  1024 1024 1024 free \$iflabel{ gpt } \$reusemethod{ } method{ efi } format{ } . \\
  8192 10000 -1 btrfs \$primary{ } method{ format } format{ } use_filesystem{ } filesystem{ btrfs } mountpoint{ / } .
d-i partman-auto/choose_recipe select agbox
d-i partman-basicfilesystems/no_swap boolean false
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

### Packages: SSH server only, plus what agbox needs on first boot
d-i apt-setup/non-free-firmware boolean true
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string sudo curl ca-certificates
d-i pkgsel/upgrade select full-upgrade
popularity-contest popularity-contest/participate boolean false

### Boot loader: also install to the removable path, so picky UEFI firmware always boots
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean false
d-i grub-installer/force-efi-extra-removable boolean true
d-i grub-installer/bootdev string default

### Finish
$late_line
d-i finish-install/reboot_in_progress note
EOF
}

render_firstboot_unit() {
  local ref=$1
  cat <<EOF
[Unit]
Description=agbox first-boot setup
Wants=network-online.target
After=network-online.target
ConditionPathExists=!/var/lib/agbox/firstboot.done

[Service]
Type=oneshot
Environment=HOME=/root AGBOX_REF=$ref
ExecStart=/bin/sh -c 'curl -fsSL --retry 10 --retry-all-errors --retry-delay 5 https://raw.githubusercontent.com/$AGBOX_REPO/$ref/install.sh | bash -s -- --yes'
ExecStartPost=/bin/sh -c 'mkdir -p /var/lib/agbox && touch /var/lib/agbox/firstboot.done'
TimeoutStartSec=0
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
}

_preseed_ventoy_hint() {
  cat >&2 <<EOF

  Ventoy: copy it to the stick as /ventoy/preseed.cfg and add to /ventoy/ventoy.json:
    { "auto_install": [ { "image": "/debian-13.x.x-amd64-netinst.iso",
                          "template": "/ventoy/preseed.cfg" } ] }
  (use your ISO's exact file name). Boot the ISO and pick the template.
  Follow first-boot progress with: journalctl -fu agbox-firstboot
EOF
}
