# shellcheck shell=bash
# Developer tooling: GitHub CLI, git defaults, Playwright's headless Chromium.

devtools::describe() {
  local out=''
  if [[ $AGBOX_GH == true ]]; then out+='GitHub CLI, '; fi
  out+='git defaults'
  if [[ $AGBOX_PLAYWRIGHT == true ]]; then out+=', Playwright headless Chromium'; fi
  echo "$out"
}
devtools::enabled() { return 0; } # git defaults always apply; gh/playwright are toggled inside

devtools::apply() {
  if [[ $AGBOX_GH == true ]]; then _devtools_gh; fi
  _devtools_git
  if [[ $AGBOX_PLAYWRIGHT == true ]]; then _devtools_playwright; fi
}

_devtools_gh() {
  if has_cmd gh; then
    log_skip "gh already installed"
  else
    apt_add_repo github-cli https://cli.github.com/packages/githubcli-archive-keyring.gpg gpg "Types: deb
URIs: https://cli.github.com/packages
Suites: stable
Components: main
Architectures: $OS_ARCH"
    apt_install gh
  fi
  if ! target_exists || ! as_user gh auth status >/dev/null 2>&1; then
    add_next_step "Log in to GitHub: gh auth login (choose HTTPS + browser; it shows a one-time code)"
  fi
}

_git_get() { target_exists && as_user git config --global --get "$1" 2>/dev/null; }

_devtools_git() {
  local kv key value
  for kv in "init.defaultBranch=main" "pull.rebase=false" \
    ${AGBOX_GIT_NAME:+"user.name=$AGBOX_GIT_NAME"} ${AGBOX_GIT_EMAIL:+"user.email=$AGBOX_GIT_EMAIL"}; do
    key=${kv%%=*} value=${kv#*=}
    [[ $(_git_get "$key") == "$value" ]] && continue
    run_user git config --global "$key" "$value"
  done
  if [[ -z $(_git_get user.email) && -z $AGBOX_GIT_EMAIL ]]; then
    add_next_step "Set your git identity: git config --global user.name 'You' && git config --global user.email you@example.com"
  fi
}

# shellcheck disable=SC2016 # $1 is expanded by the inner sh
_playwright_ready() {
  target_exists && as_root sh -c 'ls -d "$1"/.cache/ms-playwright/chromium* >/dev/null 2>&1' _ "$(target_home)"
}

_devtools_playwright() {
  if _playwright_ready; then
    log_skip "Playwright Chromium already installed"
    return 0
  fi
  # Use the real npx from mise's node (not the shim), so root can run it for system deps.
  local npx
  npx=$(target_exists && as_user "$(target_home)/.local/bin/mise" which npx 2>/dev/null) || npx=''
  if [[ -z $npx ]]; then
    if is_dry_run; then
      npx='<mise node>/bin/npx'
    else
      log_warn "skipping Playwright: needs node from mise (add node to MISE_TOOLS)"
      return 0
    fi
  fi
  log_info "installing Playwright Chromium + system libraries"
  run_root env "PATH=$(dirname "$npx"):/usr/sbin:/usr/bin:/sbin:/bin" npx -y playwright install-deps chromium
  run_user "$npx" -y playwright install chromium
}

devtools::check() {
  if [[ $AGBOX_GH == true ]]; then
    if ! has_cmd gh; then
      check_fail "gh installed" "agbox setup --only devtools"
    elif as_user gh auth status >/dev/null 2>&1; then
      check_pass "gh logged in"
    else
      check_warn "gh installed but not logged in" "gh auth login"
    fi
  fi
  if [[ -n $(_git_get user.email) ]]; then check_pass "git identity set"; else check_warn "git identity not set" "git config --global user.email you@example.com"; fi
  if [[ $AGBOX_PLAYWRIGHT == true ]]; then
    if _playwright_ready; then check_pass "Playwright Chromium installed"; else check_fail "Playwright Chromium installed" "agbox setup --only devtools"; fi
  fi
}
