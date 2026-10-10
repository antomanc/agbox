# shellcheck shell=bash
# SSH hardening: key-only login, no root login. Never applied without keys (no lockouts).

SSH_DROPIN=/etc/ssh/sshd_config.d/10-agbox.conf

ssh::describe() { echo "key-only SSH, no root login (only when the user has SSH keys)"; }
ssh::enabled() { [[ $AGBOX_SSH_HARDEN != false ]]; }

_ssh_user_has_keys() {
  target_exists || return 1
  as_root test -s "$(target_home)/.ssh/authorized_keys"
}

ssh::apply() {
  if ! has_cmd sshd && ! [[ -x /usr/sbin/sshd ]]; then
    log_skip "OpenSSH server not installed"
    return 0
  fi
  if ! _ssh_user_has_keys; then
    if [[ $AGBOX_SSH_HARDEN == true ]]; then
      log_warn "not hardening SSH: $AGBOX_USER has no ~/.ssh/authorized_keys (would lock you out)"
      add_next_step "Add your SSH key (ssh-copy-id $AGBOX_USER@<host>), then: agbox setup --only ssh"
    else
      log_skip "no SSH keys for $AGBOX_USER, leaving password login on"
    fi
    return 0
  fi

  # sshd uses the first value it sees; 10- sorts before cloud-init's 50- drop-in.
  write_file root "$SSH_DROPIN" 0644 <<'EOF'
# Managed by agbox
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
  [[ $FILE_CHANGED == true ]] || return 0
  is_dry_run && return 0
  # With socket activation (Ubuntu 24.04+) sshd may not have run yet, and `sshd -t` needs this.
  as_root install -d -m 0755 /run/sshd
  if ! as_root /usr/sbin/sshd -t; then
    as_root rm -f "$SSH_DROPIN"
    die "sshd rejected the new config; reverted $SSH_DROPIN"
  fi
  # try-reload: an inactive socket-activated ssh.service picks up the config on the next connection.
  as_root systemctl try-reload-or-restart ssh.service 2>/dev/null || as_root systemctl try-reload-or-restart sshd.service
  log_ok "SSH now accepts keys only"
}

ssh::check() {
  if as_root test -f "$SSH_DROPIN"; then
    check_pass "SSH hardened (keys only, no root)"
  elif _ssh_user_has_keys; then
    check_warn "SSH still allows passwords" "agbox setup --only ssh"
  else
    check_warn "SSH not hardened: $AGBOX_USER has no authorized_keys" "ssh-copy-id $AGBOX_USER@<host>"
  fi
}
