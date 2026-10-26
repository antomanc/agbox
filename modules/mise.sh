# shellcheck shell=bash
# mise: per-user toolchains (node, python, uv, pnpm...) that work in every kind of shell:
#   interactive  -> `mise activate` in ~/.bashrc / ~/.zshrc
#   agents/login -> shims on PATH via ~/.profile
#   systemd      -> shims on PATH via ~/.config/environment.d

mise::describe() { echo "mise toolchains ($AGBOX_MISE_TOOLS), wired into interactive, agent and systemd shells"; }
mise::enabled() { [[ -n ${AGBOX_MISE_TOOLS// /} ]]; }

MISE_BIN_REL=.local/bin/mise

mise::apply() {
  _mise_apply_user
  for_agent_users _mise_apply_agent
  _mise_update_units
  _mise_enable_timer
  for_agent_users _mise_enable_timer
}

_mise_apply_agent() {
  _mise_apply_user
  if [[ -n $AGBOX_AGENT_UNIT ]]; then
    local file="/etc/systemd/system/$AGBOX_AGENT_UNIT.d/10-agbox-path.conf"
    write_file root "$file" 0644 < <(printf '[Service]\nEnvironment="PATH=%s/.local/bin:%s/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n' \
      "$(target_home)" "$(target_home)")
    if [[ $FILE_CHANGED == true ]]; then
      if has_systemd; then run_root systemctl daemon-reload; fi
    fi
    if is_dry_run; then log_info "restart $AGBOX_AGENT_UNIT when idle to pick up the new PATH"; fi
    add_next_step "restart $AGBOX_AGENT_UNIT when idle to pick up the new PATH"
  fi
}

_mise_apply_user() {
  local home
  home=$(target_home)
  [[ -n $home ]] || home=/home/$AGBOX_USER # dry-run before the user exists

  if as_user_test_x "$home/$MISE_BIN_REL"; then
    log_skip "mise already installed for $AGBOX_USER"
  else
    log_info "installing mise for $AGBOX_USER"
    run_script user https://mise.run
  fi

  _mise_shell_hooks
  log_info "global tools: $AGBOX_MISE_TOOLS (mise skips what is already installed)"
  # shellcheck disable=SC2086 # word splitting is intended: tools are space separated
  run_user env MISE_YES=1 "$home/$MISE_BIN_REL" use --global $AGBOX_MISE_TOOLS
  # Respect .nvmrc / .python-version in existing projects.
  if ! run_user "$home/$MISE_BIN_REL" settings set idiomatic_version_file_enable_tools node,python; then
    log_warn "could not enable idiomatic version files (.nvmrc, .python-version)"
  fi
}

# Test for an executable without failing when the user doesn't exist yet (dry-run).
as_user_test_x() { target_exists && as_root test -x "$1"; }

_mise_shell_hooks() {
  local home
  home=$(target_home)
  [[ -n $home ]] || return 0 # dry-run before the user exists: nothing to show

  ensure_block user "$home/.bashrc" 0644 '#' <<'EOF'
if [ -x "$HOME/.local/bin/mise" ]; then eval "$("$HOME/.local/bin/mise" activate bash)"; fi
EOF
  if as_root test -f "$home/.zshrc"; then
    ensure_block user "$home/.zshrc" 0644 '#' <<'EOF'
if [ -x "$HOME/.local/bin/mise" ]; then eval "$("$HOME/.local/bin/mise" activate zsh)"; fi
EOF
  fi
  # Login bash reads ~/.bash_profile or ~/.bash_login instead of ~/.profile when one exists.
  local rc
  for rc in .profile .bash_profile .bash_login; do
    [[ $rc == .profile ]] || as_root test -f "$home/$rc" || continue
    ensure_block user "$home/$rc" 0644 '#' <<'EOF'
# mise shims + user binaries for login shells (what coding agents spawn)
case ":$PATH:" in *":$HOME/.local/share/mise/shims:"*) ;; *) PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH" ;; esac
export PATH
EOF
  done
  write_file user "$home/.config/environment.d/10-agbox-path.conf" 0644 <<'EOF'
# Managed by agbox: PATH for systemd --user services (t3code, hermes...)
PATH=${HOME}/.local/bin:${HOME}/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF
}

mise::check() {
  _mise_check_user
  for_agent_users _mise_check_agent
}

_mise_check_agent() {
  _mise_check_user
  if [[ -n $AGBOX_AGENT_UNIT ]]; then
    check as_root test -f "/etc/systemd/system/$AGBOX_AGENT_UNIT.d/10-agbox-path.conf" -- \
      "$AGBOX_USER PATH drop-in for $AGBOX_AGENT_UNIT" "agbox setup --only mise"
    if as_root systemctl show -p Environment "$AGBOX_AGENT_UNIT" | grep -qF "$(target_home)/.local/share/mise/shims"; then
      check_pass "$AGBOX_AGENT_UNIT loaded PATH includes mise shims"
    else
      check_fail "$AGBOX_AGENT_UNIT loaded PATH missing mise shims" "agbox setup --only mise"
    fi
  fi
}

_mise_check_user() {
  local home
  home=$(target_home)
  _mise_check_timer
  if ! as_user_test_x "$home/$MISE_BIN_REL"; then
    check_fail "$AGBOX_USER mise installed" "agbox setup --only mise"
    return 0
  fi
  check_pass "$AGBOX_USER mise installed"
  local tool name
  for tool in $AGBOX_MISE_TOOLS; do
    name=${tool%%@*}
    name=${name##*:}
    [[ $name == python ]] && name=python3
    # Service accounts launch tools without reading login shell hooks.
    check user_has "$name" -- "$AGBOX_USER: $name available on agent PATH" "agbox setup --only mise"
  done
  check grep -q 'mise/shims' "$home/.config/environment.d/10-agbox-path.conf" -- "mise on PATH for systemd user services"
}

# A single lock serializes all account updates, including retries and persistent timers.
_mise_update_units() {
  local changed=false
  if ! as_root test -d /var/lib/agbox; then run_root install -d -m 0755 /var/lib/agbox; fi
  if ! as_root test -f /var/lib/agbox/tool-updates.lock; then
    run_root install -m 0666 /dev/null /var/lib/agbox/tool-updates.lock
  fi
  write_file root /usr/local/lib/agbox/tool-updates 0755 <<'EOF'
#!/bin/bash
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
cd "$HOME"
# Boot-time timers may fire before DNS is usable. Fail so systemd retries later.
ready=false
for ((attempt=0; attempt<60; attempt++)); do
  if getent ahosts mise.jdx.dev >/dev/null && getent ahosts github.com >/dev/null; then
    ready=true
    break
  fi
  sleep 5
done
if [[ $ready != true ]]; then echo "DNS unavailable; retrying later" >&2; exit 1; fi
"$HOME/.local/bin/mise" self-update --yes
"$HOME/.local/bin/mise" upgrade --yes --jobs 1
"$HOME/.local/bin/mise" prune --yes
EOF
  write_file root /etc/systemd/system/agbox-tool-updates@.service 0644 <<'EOF'
[Unit]
Description=Update agbox toolchains for %i
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=oneshot
User=%i
ExecStart=/usr/bin/flock /var/lib/agbox/tool-updates.lock /usr/local/lib/agbox/tool-updates
Restart=on-failure
RestartSec=5min
TimeoutStartSec=infinity
Nice=10
IOSchedulingClass=idle
EOF
  if [[ $FILE_CHANGED == true ]]; then changed=true; fi
  write_file root /etc/systemd/system/agbox-tool-updates@.timer 0644 <<'EOF'
[Unit]
Description=Nightly agbox toolchain updates for %i

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  if [[ $FILE_CHANGED == true ]]; then changed=true; fi
  if [[ $changed == true ]] && has_systemd; then run_root systemctl daemon-reload; fi
}

_mise_enable_timer() {
  local timer="agbox-tool-updates@$AGBOX_USER.timer"
  if has_systemd; then
    if as_root systemctl is-enabled --quiet "$timer" && as_root systemctl is-active --quiet "$timer"; then
      log_skip "$timer already enabled and active"
    else
      run_root systemctl enable --now "$timer"
    fi
  fi
}

_mise_check_timer() {
  check as_root systemctl is-enabled --quiet "agbox-tool-updates@$AGBOX_USER.timer" -- \
    "$AGBOX_USER nightly tool updates enabled" "agbox setup --only mise"
  if target_exists && { as_user systemctl --user is-enabled --quiet agent-tool-updates.timer 2>/dev/null ||
    as_root test -L "$(user_path .config/systemd/user/timers.target.wants/agent-tool-updates.timer)"; }; then
    check_warn "$AGBOX_USER also has agent-tool-updates.timer (double updates)" \
      "as $AGBOX_USER: systemctl --user disable --now agent-tool-updates.timer"
  fi
}
