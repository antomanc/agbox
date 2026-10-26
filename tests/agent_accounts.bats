#!/usr/bin/env bats

setup() {
  load test_helper
  clean_env
  load_agbox
  load_config "" USER=agbox-test-primary
}

@test "shared instructions list configured agent homes only when configured" {
  OS_PRETTY=Debian
  run render_agents_md
  [[ "$output" != *'Agent accounts on this machine:'* ]]
  AGBOX_AGENT_USERS='openbot:openbot.service'
  target_home() { if [[ $AGBOX_USER == openbot ]]; then echo /var/lib/openbot; else echo /home/primary; fi; }
  run render_agents_md
  [[ "$output" == *'openbot (home /var/lib/openbot)'* ]]
  [[ "$output" == *"other users' homes are private"* ]]
  [[ "$output" == *'Projects live in /home/primary/dev.'* ]]
}

# Local filesystem integration: all mutations are confined to the bats temp directory.
local_accounts() {
  AGBOX_USER=$(id -un)
  AGBOX_DRY_RUN=false
  AGBOX_AGENTS='claude codex opencode'
  AGBOX_AGENT_USERS=''
  OS_PRETTY=Debian
  AGENTS_MD_PATH="$BATS_TEST_TMPDIR/etc/AGENTS.md"
  target_home() { echo "$BATS_TEST_TMPDIR/home"; }
  as_root() { "$@"; }
  as_user() { "$@"; }
  mkdir -p "$(target_home)/.config/agents"
}

@test "instruction migration preserves notes byte for byte and is idempotent" {
  local_accounts
  local legacy="$(target_home)/$AGENTS_MD_REL" canonical=$AGENTS_MD_PATH expected actual
  printf 'old managed text' | ensure_block user "$legacy" 0644 '<!--' '-->'
  printf '\n\n## This machine\nhand-written\tspaces  \n\n\n' >>"$legacy"
  expected=$(cat "$legacy"; printf '\001')
  expected=${expected#*'<!-- <<< agbox managed block <<< -->'}
  mkdir -p "$(target_home)/.claude" "$(target_home)/.codex"
  ln -s "$legacy" "$(target_home)/.claude/CLAUDE.md"
  ln -s "$legacy" "$(target_home)/.codex/AGENTS.md"
  _agents_instructions
  [ "$(readlink "$legacy")" = "$canonical" ]
  [ "$(readlink "$(target_home)/.claude/CLAUDE.md")" = "$canonical" ]
  [ "$(readlink "$(target_home)/.codex/AGENTS.md")" = "$canonical" ]
  [ "$(stat -c %a "$canonical")" = 644 ]
  [ "$(stat -c %U "$canonical")" = "$AGBOX_USER" ]
  actual=$(cat "$canonical"; printf '\001')
  [ "${actual#*'<!-- <<< agbox managed block <<< -->'}" = "$expected" ]
  cp "$canonical" "$BATS_TEST_TMPDIR/before"
  run _agents_instructions
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cmp "$canonical" "$BATS_TEST_TMPDIR/before"
}

@test "migration refuses to overwrite differing canonical and legacy files" {
  local_accounts
  mkdir -p "$(dirname "$AGENTS_MD_PATH")"
  printf 'new notes' >"$AGENTS_MD_PATH"
  printf 'old notes' >"$(target_home)/$AGENTS_MD_REL"
  run _agents_instructions
  [ "$status" -ne 0 ]
  [[ "$output" == *'exist and differ'* ]]
  [ "$(cat "$AGENTS_MD_PATH")" = 'new notes' ]
  [ ! -L "$(target_home)/$AGENTS_MD_REL" ]
}

@test "existing instruction files get pointers and keep user content without copies" {
  local_accounts
  local path="$(target_home)/.codex/AGENTS.md"
  mkdir -p "$(dirname "$path")"
  printf 'user notes\n\n' >"$path"
  _link_instructions "$path" "$AGENTS_MD_PATH"
  [ ! -L "$path" ]
  [[ "$(cat "$path")" == 'user notes'* ]]
  grep -qF "$AGENTS_MD_PATH" "$path"
  ! grep -qF '# Machine:' "$path"
  cp "$path" "$BATS_TEST_TMPDIR/before"
  _link_instructions "$path" "$AGENTS_MD_PATH"
  cmp "$path" "$BATS_TEST_TMPDIR/before"
}

@test "foreign instruction symlinks are left untouched" {
  local_accounts
  ln -s "$BATS_TEST_TMPDIR/custom.md" "$(target_home)/CLAUDE.md"
  run _link_instructions "$(target_home)/CLAUDE.md" "$AGENTS_MD_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *user-managed* ]]
  [ "$(readlink "$(target_home)/CLAUDE.md")" = "$BATS_TEST_TMPDIR/custom.md" ]
}

@test "exact file writes and managed blocks preserve final newlines" {
  local_accounts
  local path="$BATS_TEST_TMPDIR/bytes"
  printf 'before\n\n' >"$path"
  ensure_block root "$path" 0644 '<!--' '-->' --exact <<<'body'
  printf '\nafter\n\n\n' >>"$path"
  cp "$path" "$BATS_TEST_TMPDIR/before"
  ensure_block root "$path" 0644 '<!--' '-->' --exact <<<'body'
  [ "$FILE_CHANGED" = false ]
  cmp "$path" "$BATS_TEST_TMPDIR/before"
  ensure_block root "$path" 0644 '<!--' '-->' --exact <<<'updated'
  [ "$FILE_CHANGED" = true ]
  local content
  content=$(cat "$path"; printf '\001')
  [[ "$content" == $'before\n\n'* ]]
  [[ "$content" == *$'after\n\n\n\001' ]]
}

@test "service account dry-run includes PATH, all instruction links, Docker and timers" {
  # nobody exists on Debian/Ubuntu; no app installer or host config is required.
  run "$AGBOX" setup --dry-run --yes --only mise,agents,docker \
    --set USER=agbox-test-primary --set AGENT_USERS=nobody:agbox-test.service
  [ "$status" -eq 0 ]
  [[ "$output" == *'installing mise for nobody'* ]]
  [[ "$output" == *'/etc/systemd/system/agbox-test.service.d/10-agbox-path.conf'* ]]
  [[ "$output" == *'[nobody] ln -sfn /etc/agbox/AGENTS.md'* ]]
  [[ "$output" == *'.claude/CLAUDE.md'* && "$output" == *'.codex/AGENTS.md'* && "$output" == *'.config/opencode/AGENTS.md'* ]]
  [[ "$output" == *'usermod -aG docker nobody'* ]]
  [[ "$output" == *'agbox-tool-updates@agbox-test-primary.timer'* ]]
  [[ "$output" == *'agbox-tool-updates@nobody.timer'* ]]
  [[ "$output" == *'restart agbox-test.service when idle'* ]]
  [[ "$output" != *'systemctl restart agbox-test.service'* ]]
}

@test "nightly units serialize accounts and generated script fails before pruning on upgrade error" {
  local_accounts
  has_systemd() { return 0; }
  run_root() { printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/root-commands"; }
  # Capture the exact generated artifacts without accessing any system path.
  write_file() {
    cat >"$BATS_TEST_TMPDIR/${2##*/}"
    FILE_CHANGED=true
  }
  _mise_update_units
  grep -qF 'ExecStart=/usr/bin/flock /var/lib/agbox/tool-updates.lock' "$BATS_TEST_TMPDIR/agbox-tool-updates@.service"
  grep -qF 'User=%i' "$BATS_TEST_TMPDIR/agbox-tool-updates@.service"
  grep -qF 'Restart=on-failure' "$BATS_TEST_TMPDIR/agbox-tool-updates@.service"
  grep -qF 'Nice=10' "$BATS_TEST_TMPDIR/agbox-tool-updates@.service"
  grep -qF 'IOSchedulingClass=idle' "$BATS_TEST_TMPDIR/agbox-tool-updates@.service"
  grep -qF 'RandomizedDelaySec=1h' "$BATS_TEST_TMPDIR/agbox-tool-updates@.timer"
  grep -qF 'systemctl daemon-reload' "$BATS_TEST_TMPDIR/root-commands"
  bash -n "$BATS_TEST_TMPDIR/tool-updates"
  mkdir -p "$BATS_TEST_TMPDIR/home/.local/bin"
  cat >"$BATS_TEST_TMPDIR/home/.local/bin/mise" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$*" >>"$HOME/calls"
if [[ $1 == upgrade && ${FAIL_UPGRADE:-false} == true ]]; then exit 42; fi
SCRIPT
  chmod +x "$BATS_TEST_TMPDIR/home/.local/bin/mise"
  getent() { return 0; }
  export -f getent
  HOME="$BATS_TEST_TMPDIR/home" run bash "$BATS_TEST_TMPDIR/tool-updates"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/home/calls")" = $'self-update --yes\nupgrade --yes --jobs 1\nprune --yes' ]
  rm "$BATS_TEST_TMPDIR/home/calls"
  HOME="$BATS_TEST_TMPDIR/home" FAIL_UPGRADE=true run bash "$BATS_TEST_TMPDIR/tool-updates"
  [ "$status" -eq 42 ]
  ! grep -q prune "$BATS_TEST_TMPDIR/home/calls"
}

@test "service PATH drop-in reloads only when changed and never restarts the app" {
  local_accounts
  AGBOX_AGENT_UNIT=app.service
  _mise_apply_user() { :; }
  has_systemd() { return 0; }
  write_file() {
    [ "$2" = /etc/systemd/system/app.service.d/10-agbox-path.conf ]
    cat >"$BATS_TEST_TMPDIR/drop-in"
    FILE_CHANGED=${TEST_CHANGED:-true}
  }
  run_root() { printf '%s\n' "$*"; }
  run _mise_apply_agent
  [ "$status" -eq 0 ]
  [ "$output" = 'systemctl daemon-reload' ]
  grep -qF "PATH=$(target_home)/.local/bin:$(target_home)/.local/share/mise/shims:" "$BATS_TEST_TMPDIR/drop-in"
  TEST_CHANGED=false run _mise_apply_agent
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "doctor warns for an enabled legacy timer and clears after it is disabled" {
  local_accounts
  target_exists() { return 0; }
  as_user() { return 1; } # User bus unavailable, as with headless service accounts.
  mkdir -p "$(user_path .config/systemd/user/timers.target.wants)"
  touch "$(user_path .config/systemd/user/agent-tool-updates.timer)"
  ln -s ../agent-tool-updates.timer "$(user_path .config/systemd/user/timers.target.wants/agent-tool-updates.timer)"
  run _mise_check_timer
  [[ "$output" == *'double updates'* ]]
  [[ "$output" == *'systemctl --user disable --now agent-tool-updates.timer'* ]]
  rm "$(user_path .config/systemd/user/timers.target.wants/agent-tool-updates.timer)"
  run _mise_check_timer
  [[ "$output" != *'double updates'* ]]
}
