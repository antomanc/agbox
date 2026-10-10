# shellcheck shell=bash
# Base system: packages, upgrades, hostname, timezone, zram swap, auto-updates.

SYSTEM_PACKAGES=(
  sudo curl ca-certificates gnupg git build-essential pkg-config
  jq ripgrep fd-find tmux unzip zip htop rsync bubblewrap socat
  lsb-release bind9-dnsutils file less nano
)

system::describe() { echo "base packages, upgrades, hostname, timezone, zram, auto-updates"; }
system::enabled() { return 0; }

system::apply() {
  apt_install "${SYSTEM_PACKAGES[@]}"

  if [[ $AGBOX_UPGRADE == true ]]; then
    apt_update
    log_info "upgrading installed packages"
    apt_get full-upgrade -y
  fi

  # Debian ships fd as fdfind; agents expect `fd`.
  if [[ -x /usr/bin/fdfind && ! -e /usr/local/bin/fd ]]; then
    run_root ln -s /usr/bin/fdfind /usr/local/bin/fd
  fi

  _system_hostname
  _system_timezone
  _system_zram
  _system_auto_updates
}

_system_hostname() {
  [[ -n $AGBOX_HOSTNAME ]] || return 0
  if [[ $(hostname) == "$AGBOX_HOSTNAME" ]]; then
    log_skip "hostname already $AGBOX_HOSTNAME"
    return 0
  fi
  log_info "setting hostname to $AGBOX_HOSTNAME"
  run_root hostnamectl set-hostname "$AGBOX_HOSTNAME"
  # Keep 127.0.1.1 in sync so sudo doesn't complain about an unresolvable host.
  local hosts
  hosts=$(grep -v '^127\.0\.1\.1[[:space:]]' /etc/hosts)
  printf '%s\n127.0.1.1\t%s\n' "$hosts" "$AGBOX_HOSTNAME" | write_file root /etc/hosts 0644
}

_system_timezone() {
  [[ -n $AGBOX_TIMEZONE ]] || return 0
  [[ -e /usr/share/zoneinfo/$AGBOX_TIMEZONE ]] || die "unknown timezone '$AGBOX_TIMEZONE'"
  if [[ $(timedatectl show -p Timezone --value 2>/dev/null) == "$AGBOX_TIMEZONE" ]]; then
    log_skip "timezone already $AGBOX_TIMEZONE"
    return 0
  fi
  run_root timedatectl set-timezone "$AGBOX_TIMEZONE"
}

# Some kernels (e.g. cloud images without linux-modules-extra) lack zram entirely.
_system_zram_supported() {
  [[ -d /sys/module/zram ]] || modinfo zram >/dev/null 2>&1
}

_system_zram() {
  [[ $AGBOX_ZRAM == true ]] || return 0
  if ! _system_zram_supported; then
    log_warn "kernel $(uname -r) has no zram module; skipping zram swap"
    return 0
  fi
  apt_install zram-tools
  write_file root /etc/default/zramswap 0644 <<EOF
# Managed by agbox
ALGO=zstd
PERCENT=$AGBOX_ZRAM_PERCENT
PRIORITY=100
EOF
  if [[ $FILE_CHANGED == true ]] && has_systemd; then
    run_root systemctl restart zramswap.service
  fi
}

_system_auto_updates() {
  [[ $AGBOX_AUTO_UPDATES == true ]] || return 0
  apt_install unattended-upgrades
  write_file root /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
}

system::check() {
  if os_is_supported; then check_pass "OS: $OS_PRETTY"; else check_warn "OS: $OS_PRETTY (untested)" "supported: Debian 12/13, Ubuntu 24.04/26.04"; fi
  local missing=() pkg
  for pkg in "${SYSTEM_PACKAGES[@]}"; do pkg_installed "$pkg" || missing+=("$pkg"); done
  if ((${#missing[@]})); then check_fail "base packages missing: ${missing[*]}" "agbox setup --only system"; else check_pass "base packages installed"; fi
  if [[ $AGBOX_ZRAM == true ]] && ! _system_zram_supported; then
    check_warn "zram not supported by kernel $(uname -r)" "install the kernel's extra modules or set ZRAM=false"
  elif [[ $AGBOX_ZRAM == true ]]; then
    check grep -q zram /proc/swaps -- "zram swap active" "agbox setup --only system"
  fi
  if [[ $AGBOX_AUTO_UPDATES == true ]]; then
    check test -f /etc/apt/apt.conf.d/20auto-upgrades -- "unattended upgrades enabled" "agbox setup --only system"
  fi
}
