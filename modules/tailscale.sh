# shellcheck shell=bash
# Tailscale: private access from anywhere, Tailscale SSH, HTTPS for t3code & dev servers.

tailscale::describe() { echo "Tailscale VPN (+ Tailscale SSH), user allowed to run 'tailscale serve'"; }
tailscale::enabled() { [[ $AGBOX_TAILSCALE == true ]]; }

_tailscale_state() {
  tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null
}

tailscale::apply() {
  if has_cmd tailscale; then
    log_skip "tailscale already installed"
  else
    log_info "installing tailscale (official install script)"
    run_script root https://tailscale.com/install.sh
  fi
  if has_systemd && ! is_dry_run; then as_root systemctl enable --now tailscaled >/dev/null 2>&1 || true; fi

  local -a args=()
  if [[ $AGBOX_TAILSCALE_SSH == true ]]; then args+=(--ssh); fi
  if [[ -n $AGBOX_TAILSCALE_HOSTNAME ]]; then args+=("--hostname=$AGBOX_TAILSCALE_HOSTNAME"); fi

  if [[ $(_tailscale_state) == Running ]]; then
    log_skip "already connected to the tailnet"
    # Keep flags in sync without re-authenticating.
    if ((${#args[@]})); then run_root tailscale set "${args[@]}"; fi
  elif [[ -n $AGBOX_TAILSCALE_AUTHKEY ]]; then
    log_info "joining the tailnet with the provided auth key"
    if is_dry_run; then
      run_root tailscale up '--authkey=********' "${args[@]}" # never print the secret
    else
      run_root tailscale up --authkey="$AGBOX_TAILSCALE_AUTHKEY" "${args[@]}"
    fi
  elif is_interactive; then
    log_info "joining the tailnet: open the link below to approve this machine"
    run_root tailscale up "${args[@]}"
  else
    log_warn "tailscale installed but not logged in (no TAILSCALE_AUTHKEY, no terminal)"
    add_next_step "Join Tailscale: sudo tailscale up${args[*]:+ ${args[*]}}"
  fi

  # Lets the user (and t3code) run `tailscale serve` without root.
  run_root tailscale set --operator="$AGBOX_USER"
}

tailscale::check() {
  if ! has_cmd tailscale; then
    check_fail "tailscale installed" "agbox setup --only tailscale"
    return 0
  fi
  local state
  state=$(_tailscale_state)
  if [[ $state == Running ]]; then
    check_pass "tailscale connected as $(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"
  else
    check_fail "tailscale not connected (state: ${state:-unknown})" "sudo tailscale up --ssh"
  fi
}
