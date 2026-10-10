# shellcheck shell=bash
# The non-root user agents run as: account, sudo, SSH keys, lingering, projects dir.

user::describe() { echo "target user, sudo, SSH keys, systemd lingering, projects dir"; }
user::enabled() { return 0; }

user::apply() {
  local user=$AGBOX_USER

  if target_exists; then
    log_skip "user $user exists"
  else
    log_info "creating user $user"
    # No password (locked): login is via SSH keys / Tailscale SSH; sudo is configured below.
    run_root useradd --create-home --shell /bin/bash --groups sudo "$user"
    if [[ $AGBOX_PASSWORDLESS_SUDO != true ]]; then
      log_warn "$user has no password and PASSWORDLESS_SUDO=false: set one with 'sudo passwd $user'"
    fi
  fi
  # From here on, dry-run may refer to a user that doesn't exist yet.
  is_dry_run && ! target_exists && return 0

  if ! id -nG "$user" | tr ' ' '\n' | grep -qx sudo; then
    run_root usermod -aG sudo "$user"
  fi

  _user_sudoers
  _user_ssh_keys

  if [[ ! -e /var/lib/systemd/linger/$user ]] && has_systemd; then
    run_root loginctl enable-linger "$user"
  fi

  local dir
  dir=$(expand_home "$AGBOX_PROJECTS_DIR")
  if [[ ! -d $dir ]]; then run_user mkdir -p "$dir"; fi
}

_user_sudoers() {
  local file="/etc/sudoers.d/90-agbox-$AGBOX_USER"
  if [[ $AGBOX_PASSWORDLESS_SUDO != true ]]; then
    if as_root test -e "$file"; then run_root rm -f "$file"; fi
    return 0
  fi
  local rule="$AGBOX_USER ALL=(ALL:ALL) NOPASSWD: ALL"
  [[ $(as_root cat "$file" 2>/dev/null) == "$rule" ]] && return 0
  # Validate before installing: a broken sudoers file locks you out of sudo.
  if ! is_dry_run; then
    printf '%s\n' "$rule" | as_root visudo -cqf - || die "generated sudoers rule failed validation"
  fi
  printf '%s\n' "$rule" | write_file root "$file" 0440
}

# Fresh VPS: you SSH in as root with a key. Give the new user the same key.
_user_ssh_keys() {
  local home keys
  home=$(target_home)
  keys="$home/.ssh/authorized_keys"
  as_root test -s "$keys" && return 0
  as_root test -s /root/.ssh/authorized_keys || return 0
  log_info "copying root's SSH authorized_keys to $AGBOX_USER"
  run_root install -d -m 0700 -o "$AGBOX_USER" -g "$AGBOX_USER" "$home/.ssh"
  run_root install -m 0600 -o "$AGBOX_USER" -g "$AGBOX_USER" /root/.ssh/authorized_keys "$keys"
}

user::check() {
  if ! target_exists; then
    check_fail "user $AGBOX_USER exists" "agbox setup --only user"
    return 0
  fi
  check_pass "user $AGBOX_USER exists"
  if [[ $AGBOX_PASSWORDLESS_SUDO == true ]]; then
    check as_user sudo -n true -- "passwordless sudo for $AGBOX_USER" "agbox setup --only user"
  fi
  check test -e "/var/lib/systemd/linger/$AGBOX_USER" -- "lingering enabled (user services run without login)" "sudo loginctl enable-linger $AGBOX_USER"
  check test -d "$(expand_home "$AGBOX_PROJECTS_DIR")" -- "projects dir $(expand_home "$AGBOX_PROJECTS_DIR")"
}
