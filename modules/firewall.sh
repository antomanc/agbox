# shellcheck shell=bash
# ufw firewall: deny incoming except SSH and the Tailscale interface.
# Note: ports published by Docker (-p 8080:80) bypass ufw. Bind them to 127.0.0.1
# or reach them over Tailscale instead (see docs/security.md).

firewall::describe() { echo "ufw: deny incoming except SSH and Tailscale"; }
firewall::enabled() { [[ $AGBOX_FIREWALL == true ]]; }

_ssh_port() {
  local port=''
  if [[ -x /usr/sbin/sshd ]]; then
    port=$(as_root /usr/sbin/sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }') || port=''
  fi
  printf '%s' "${port:-22}"
}

firewall::apply() {
  apt_install ufw
  local port
  port=$(_ssh_port)
  # Allow rules before enabling, so the current SSH session survives.
  run_root ufw allow "$port/tcp" comment 'ssh (agbox)' >/dev/null
  run_root ufw allow 41641/udp comment 'tailscale direct (agbox)' >/dev/null
  run_root ufw allow in on tailscale0 comment 'tailnet (agbox)' >/dev/null
  run_root ufw default deny incoming >/dev/null
  run_root ufw default allow outgoing >/dev/null
  if as_root ufw status 2>/dev/null | grep -q '^Status: active'; then
    log_skip "ufw already active"
  else
    run_root ufw --force enable >/dev/null
    log_ok "ufw enabled (allowed: ssh/$port, tailscale)"
  fi
}

firewall::check() {
  if as_root ufw status 2>/dev/null | grep -q '^Status: active'; then
    check_pass "firewall (ufw) active"
  else
    check_fail "firewall (ufw) not active" "agbox setup --only firewall"
  fi
}
