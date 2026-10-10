# shellcheck shell=bash
# Optional always-on extras, run as systemd --user services of the target user.
#   t3code : web UI for coding agents, published on the tailnet (t3 pair --tailscale)
#   hermes : Nous Research's Hermes Agent (messaging gateway, cron jobs)

services::describe() { echo "always-on extras: ${AGBOX_SERVICES:-none}"; }
services::enabled() { [[ -n ${AGBOX_SERVICES// /} ]]; }

_has_service() { [[ " $AGBOX_SERVICES " == *" $1 "* ]]; }
_user_unit_exists() {
  target_exists && as_user systemctl --user list-unit-files --no-legend "$1" 2>/dev/null | grep -q .
}

services::apply() {
  wait_user_bus || true
  if _has_service t3code; then _services_t3code; fi
  if _has_service hermes; then _services_hermes; fi
}

_services_t3code() {
  if user_has t3; then
    log_skip "t3 already installed"
  else
    log_info "installing t3code"
    mise_user use --global npm:t3
  fi
  if _user_unit_exists 't3*.service'; then
    log_skip "t3code service already installed"
  else
    run_user t3 service install
  fi
  if [[ $AGBOX_TAILSCALE == true ]]; then
    add_next_step "Pair a device with t3code over Tailscale HTTPS: t3 pair --tailscale"
  else
    add_next_step "Pair a device with t3code: t3 pair"
  fi
}

_services_hermes() {
  if user_has hermes; then
    log_skip "hermes already installed"
  else
    log_info "installing Hermes Agent (official install script)"
    run_script user https://hermes-agent.nousresearch.com/install.sh bash
  fi
  if ! _user_unit_exists 'hermes-gateway.service'; then
    add_next_step "Configure Hermes: run 'hermes' (provider + model), then 'hermes gateway setup' and 'hermes gateway install'"
  fi
}

services::check() {
  if _has_service t3code; then
    if _user_unit_exists 't3*.service'; then
      local unit
      unit=$(as_user systemctl --user list-unit-files --no-legend 't3*.service' | awk 'NR==1 { print $1 }')
      check as_user systemctl --user is-active --quiet "$unit" -- "t3code service ($unit) running" "systemctl --user restart $unit"
    else
      check_fail "t3code service installed" "agbox setup --only services"
    fi
  fi
  if _has_service hermes; then
    if ! user_has hermes; then
      check_fail "hermes installed" "agbox setup --only services"
    elif _user_unit_exists 'hermes-gateway.service'; then
      check as_user systemctl --user is-active --quiet hermes-gateway.service -- "hermes gateway running" "hermes gateway start"
    else
      check_warn "hermes installed, gateway not set up" "hermes gateway setup && hermes gateway install"
    fi
  fi
}
