# shellcheck shell=bash
# Coding agents (Claude Code, Codex, opencode), their permission mode, and one shared
# AGENTS.md telling every agent what this machine is and how to work on it.

agents::describe() { echo "coding agents ($AGBOX_AGENTS) in $AGBOX_AGENT_MODE mode + shared AGENTS.md"; }
agents::enabled() { [[ -n ${AGBOX_AGENTS// /} ]]; }

_has_agent() { [[ " $AGBOX_AGENTS " == *" $1 "* ]]; }

AGENTS_MD_REL=.config/agents/AGENTS.md

agents::apply() {
  if _has_agent claude; then _agents_install_claude; fi
  if _has_agent codex; then _agents_install_npm codex @openai/codex; fi
  if _has_agent opencode; then _agents_install_npm opencode opencode-ai; fi

  if [[ $AGBOX_AGENT_MODE == sandboxed ]]; then _agents_sandbox_prereqs; fi
  if _has_agent claude; then _agents_configure_claude; fi
  if _has_agent codex; then _agents_configure_codex; fi
  if [[ $AGBOX_AGENT_INSTRUCTIONS == true ]]; then _agents_instructions; fi
}

_agents_install_claude() {
  if user_has claude; then
    log_skip "claude already installed (self-updates)"
    return 0
  fi
  log_info "installing Claude Code (native installer)"
  run_script user https://claude.ai/install.sh bash
  add_next_step "Log in to Claude Code: run 'claude' and open the URL it prints"
}

# Installed through mise so they survive Node upgrades.
_agents_install_npm() {
  local cmd=$1 pkg=$2
  if user_has "$cmd"; then
    log_skip "$cmd already installed (upgrade: mise upgrade npm:$pkg)"
    return 0
  fi
  log_info "installing $cmd"
  mise_user use --global "npm:$pkg"
  case $cmd in
    codex) add_next_step "Log in to Codex: 'codex login --device-auth' (or see docs/troubleshooting.md for headless browser login)" ;;
    opencode) add_next_step "Log in to opencode: 'opencode auth login'" ;;
  esac
}

# Ubuntu 24.04+ blocks the user namespaces bubblewrap needs unless AppArmor allows it.
_agents_sandbox_prereqs() {
  apt_install bubblewrap socat
  apparmor_restricts_userns || return 0
  local profile=/etc/apparmor.d/bwrap-userns-restrict
  if as_root test -f "$profile"; then
    log_skip "AppArmor bwrap profile present"
  else
    apt_install apparmor-profiles apparmor-utils
    run_root cp /usr/share/apparmor/extra-profiles/bwrap-userns-restrict "$profile"
  fi
  run_root apparmor_parser -r "$profile"
}

_agents_configure_claude() {
  local file
  file=$(user_path .claude/settings.json)
  local filter
  if [[ $AGBOX_AGENT_MODE == yolo ]]; then
    filter='.permissions.defaultMode = "bypassPermissions"'
  else
    filter='.sandbox.enabled = true | del(.permissions.defaultMode | select(. == "bypassPermissions"))'
  fi
  _json_merge_user "$file" "$filter"
}

_agents_configure_codex() {
  local file sandbox approval
  file=$(user_path .codex/config.toml)
  if [[ $AGBOX_AGENT_MODE == yolo ]]; then
    sandbox=danger-full-access approval=never
  else
    sandbox=workspace-write approval=on-request
  fi
  local content
  content=$(_read_as user "$file") || content=''
  content=$(toml_set_top "$content" sandbox_mode "\"$sandbox\"")
  content=$(toml_set_top "$content" approval_policy "\"$approval\"")
  printf '%s\n' "$content" | write_file user "$file" 0600
}

# _json_merge_user FILE JQ_FILTER : apply a jq edit to a user JSON file, creating it if needed.
_json_merge_user() {
  local file=$1 filter=$2 current merged
  current=$(_read_as user "$file") || current=''
  [[ -n $current ]] || current='{}'
  if ! has_cmd jq; then
    log_info "would update $file"
    return 0
  fi
  if ! merged=$(jq "$filter" <<<"$current" 2>/dev/null); then
    log_warn "$file is not valid JSON; leaving it untouched"
    return 0
  fi
  printf '%s\n' "$merged" | write_file user "$file" 0600
}

# toml_set_top CONTENT KEY VALUE -> CONTENT with a top-level `KEY = VALUE`: replaced in
# place if present, else inserted after the last top-level line (before any [table]).
# Pure, unit-tested.
toml_set_top() {
  local content=$1 key=$2 value=$3
  if [[ -z $content ]]; then
    printf '%s = %s\n' "$key" "$value"
    return 0
  fi
  awk -v key="$key" -v value="$value" '
    { line[NR] = $0 }
    END {
      top_end = NR
      for (i = 1; i <= NR; i++) if (line[i] ~ /^[[:space:]]*\[/) { top_end = i - 1; break }
      for (i = 1; i <= top_end; i++) {
        if (line[i] ~ "^[[:space:]]*" key "[[:space:]]*=") { line[i] = key " = " value; found = 1; break }
      }
      after = 0
      if (!found) for (i = top_end; i >= 1; i--) if (line[i] !~ /^[[:space:]]*$/) { after = i; break }
      if (!found && after == 0) { print key " = " value; if (NR > 0 && line[1] !~ /^[[:space:]]*$/) print "" }
      for (i = 1; i <= NR; i++) {
        print line[i]
        if (!found && i == after) print key " = " value
      }
    }
  ' <<<"$content"
}

# One instruction file, linked into each agent's global location.
# Claude imports it when the user already has a CLAUDE.md, so there is still one copy.
_agents_instructions() {
  local home canonical
  home=$(target_home)
  [[ -n $home ]] || { log_info "would write ~/$AGENTS_MD_REL"; return 0; }
  canonical="$home/$AGENTS_MD_REL"

  render_agents_md | ensure_block user "$canonical" 0644 '<!--' '-->'
  if _has_agent claude; then _link_instructions "$home/.claude/CLAUDE.md" "$canonical" "@$canonical"; fi
  if _has_agent codex; then _link_instructions "$home/.codex/AGENTS.md" "$canonical"; fi
  if _has_agent opencode; then _link_instructions "$home/.config/opencode/AGENTS.md" "$canonical"; fi
}

# _link_instructions LINK CANONICAL [BODY] : symlink LINK to CANONICAL. If the user has their
# own file there, add a managed block instead: BODY (e.g. an import line), or a full copy.
_link_instructions() {
  local link=$1 canonical=$2 body=${3:-} current
  if as_root test -L "$link"; then
    current=$(as_root readlink "$link")
    [[ $current == "$canonical" ]] && return 0
  fi
  if as_root test -e "$link" && ! as_root test -L "$link"; then
    # The user has their own file: add our block to it instead of replacing it.
    if [[ -n $body ]]; then
      printf '%s\n' "$body" | ensure_block user "$link" 0644 '<!--' '-->'
    else
      render_agents_md | ensure_block user "$link" 0644 '<!--' '-->'
    fi
    return 0
  fi
  run_user mkdir -p "$(dirname "$link")"
  run_user ln -sfn "$canonical" "$link"
}

# instructions_pointer PATH -> a paragraph for agents that only load a global identity
# file (Hermes' SOUL.md), sending them to the shared AGENTS.md. Pure, unit-tested.
instructions_pointer() {
  printf '%s\n' "This machine's conventions (toolchains, services, ports, where projects live) are in $1. Read it before installing software, starting services, or changing anything outside the current project."
}

render_agents_md() {
  local projects sudo_line tools docker_line mode_line
  projects=$(expand_home "$AGBOX_PROJECTS_DIR")
  if [[ $AGBOX_PASSWORDLESS_SUDO == true ]]; then
    sudo_line="- You have passwordless sudo: install system packages with \`sudo apt-get install -y\` when needed."
  else
    sudo_line="- sudo needs a password: ask the human before system-level changes."
  fi
  if [[ $AGBOX_DOCKER == true ]]; then
    docker_line="- Databases and services (Postgres, MongoDB, Redis...) run with \`docker compose\`, not on the host. Bind published ports to 127.0.0.1 unless asked otherwise."
  else
    docker_line="- Docker is not installed."
  fi
  if [[ $AGBOX_AGENT_MODE == yolo ]]; then
    mode_line="- You run without permission prompts. This machine is disposable, but never touch files outside the project unless asked, and never print secrets."
  else
    mode_line="- Commands run in a sandbox; ask when you need access outside the workspace."
  fi
  tools=$AGBOX_MISE_TOOLS
  cat <<EOF
<!-- Generated by agbox (https://github.com/antomanc/agbox). Edit outside the markers. -->
# Machine: $(hostname 2>/dev/null || echo unknown)

Headless $OS_PRETTY server, $(cpu_count) CPUs, $(mem_total_gb) GB RAM. No display: everything is CLI.

## Environment
$sudo_line
- Toolchains are managed by mise (global: $tools). Pin per-project versions with \`mise use node@22\` (writes mise.toml). Never \`sudo npm\` or \`sudo pip\`.
- Python: use \`uv\`. JavaScript: \`pnpm\` unless the project uses another package manager.
$docker_line
- Browser testing: Playwright with headless Chromium.
- Dev servers: bind to 0.0.0.0 so the human can open them over Tailscale (http://$(hostname 2>/dev/null || echo this-host):PORT).

## Working agreements
- Projects live in $projects.
$mode_line
- Commit early and often with clear messages; git history is the undo button.
- RAM is limited: avoid running several heavy builds or test suites in parallel.
EOF
}

agents::check() {
  local agent
  for agent in $AGBOX_AGENTS; do
    if user_has "$agent"; then check_pass "$agent installed"; else check_fail "$agent installed" "agbox setup --only agents"; fi
  done
  if [[ $AGBOX_AGENT_INSTRUCTIONS == true ]]; then
    check as_root test -f "$(target_home)/$AGENTS_MD_REL" -- "shared AGENTS.md (~/$AGENTS_MD_REL)"
  fi
  if [[ $AGBOX_AGENT_MODE == sandboxed ]] && apparmor_restricts_userns; then
    check as_user bwrap --ro-bind / / true -- "bubblewrap can create sandboxes (AppArmor ok)" "agbox setup --only agents"
  fi
}
