# shellcheck shell=bash
# mise: per-user toolchains (node, python, uv, pnpm...) that work in every kind of shell:
#   interactive  -> `mise activate` in ~/.bashrc / ~/.zshrc
#   agents/login -> shims on PATH via ~/.profile
#   systemd      -> shims on PATH via ~/.config/environment.d

mise::describe() { echo "mise toolchains ($AGBOX_MISE_TOOLS), wired into interactive, agent and systemd shells"; }
mise::enabled() { [[ -n ${AGBOX_MISE_TOOLS// /} ]]; }

MISE_BIN_REL=.local/bin/mise

mise::apply() {
  local home
  home=$(target_home)
  [[ -n $home ]] || home=/home/$AGBOX_USER # dry-run before the user exists

  if as_user_test_x "$home/$MISE_BIN_REL"; then
    log_skip "mise already installed"
  else
    log_info "installing mise"
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
  local home
  home=$(target_home)
  if ! as_user_test_x "$home/$MISE_BIN_REL"; then
    check_fail "mise installed" "agbox setup --only mise"
    return 0
  fi
  check_pass "mise installed"
  local tool name
  for tool in $AGBOX_MISE_TOOLS; do
    name=${tool%%@*}
    name=${name##*:}
    [[ $name == python ]] && name=python3
    # A login shell is what agents use; this is the check that failed before agbox.
    check as_user bash -lc "command -v $name" -- "$name available in agent (login) shells" "agbox setup --only mise"
  done
  check grep -q 'mise/shims' "$home/.config/environment.d/10-agbox-path.conf" -- "mise on PATH for systemd user services"
}
