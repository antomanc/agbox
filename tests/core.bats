#!/usr/bin/env bats
# Pure helpers: managed blocks, TOML edits, module selection, OS detection, AGENTS.md.

setup() {
  load test_helper
  clean_env
  load_agbox
}

@test "render_block: creates a block in an empty file" {
  run render_block "" "hello" "#"
  [ "$output" = $'# >>> agbox managed block >>>\nhello\n# <<< agbox managed block <<<' ]
}

@test "render_block: appends after existing content with a blank line" {
  run render_block $'alias ll=ls\n' "hello" "#"
  [ "$output" = $'alias ll=ls\n\n# >>> agbox managed block >>>\nhello\n# <<< agbox managed block <<<' ]
}

@test "render_block: replaces only the managed block, keeping the user's lines" {
  local first second
  first=$(render_block $'before' "v1" "#")
  first+=$'\nafter'
  second=$(render_block "$first" "v2" "#")
  [ "$second" = $'before\n\n# >>> agbox managed block >>>\nv2\n# <<< agbox managed block <<<\nafter' ]
  # applying the same body again is a no-op
  [ "$(render_block "$second" "v2" "#")" = "$second" ]
}

@test "render_block: supports comment suffixes (markdown)" {
  run render_block "" "body" "<!--" "-->"
  [ "${lines[0]}" = "<!-- >>> agbox managed block >>> -->" ]
  [ "${lines[2]}" = "<!-- <<< agbox managed block <<< -->" ]
}

@test "toml_set_top: creates, inserts before tables, and replaces in place" {
  run toml_set_top "" sandbox_mode '"a"'
  [ "$output" = 'sandbox_mode = "a"' ]

  local cfg=$'model = "gpt-5"\n\n[profiles.fast]\nmodel = "x"'
  cfg=$(toml_set_top "$cfg" sandbox_mode '"a"')
  [ "$cfg" = $'model = "gpt-5"\nsandbox_mode = "a"\n\n[profiles.fast]\nmodel = "x"' ]

  cfg=$(toml_set_top "$cfg" sandbox_mode '"b"')
  [ "$(grep -c sandbox_mode <<<"$cfg")" -eq 1 ]
  [[ "$cfg" == *'sandbox_mode = "b"'* ]]
}

@test "toml_set_top: never touches keys inside tables" {
  local cfg=$'[profiles.x]\nsandbox_mode = "read-only"'
  cfg=$(toml_set_top "$cfg" sandbox_mode '"danger-full-access"')
  [ "$cfg" = $'sandbox_mode = "danger-full-access"\n\n[profiles.x]\nsandbox_mode = "read-only"' ]
}

@test "select_modules: all, --only, --skip, keeps canonical order" {
  run select_modules "" ""
  [ "${#lines[@]}" -eq "${#MODULES[@]}" ]
  run select_modules "agents,system" ""
  [ "$output" = $'system\nagents' ]
  run select_modules "" "docker,services"
  [[ "$output" != *docker* && "$output" != *services* && "$output" == *mise* ]]
}

@test "select_modules: unknown module fails" {
  run select_modules "dockr" ""
  [ "$status" -ne 0 ] && [[ "$output" == *"unknown module 'dockr'"* ]]
}

@test "every module implements the full interface" {
  local m fn
  for m in "${MODULES[@]}"; do
    for fn in describe enabled apply check; do
      declare -F "$m::$fn" >/dev/null
    done
  done
}

@test "detect_os: parses Debian 13" {
  AGBOX_OS_RELEASE="$FIXTURES/os-release-debian13" detect_os
  [ "$OS_ID" = debian ] && [ "$OS_VERSION_ID" = 13 ] && [ "$OS_CODENAME" = trixie ]
  os_is_supported
}

@test "detect_os: refuses non-Debian distributions" {
  AGBOX_OS_RELEASE="$FIXTURES/os-release-fedora" run detect_os
  [ "$status" -ne 0 ] && [[ "$output" == *"unsupported distribution 'fedora'"* ]]
}

@test "render_agents_md reflects the configuration" {
  load_config "" USER=agbox-test-nobody AGENT_MODE=sandboxed PASSWORDLESS_SUDO=false DOCKER=false
  OS_PRETTY="Debian GNU/Linux 13 (trixie)"
  run render_agents_md
  [[ "$output" == *"sudo needs a password"* ]]
  [[ "$output" == *"Docker is not installed"* ]]
  [[ "$output" == *"Commands run in a sandbox"* ]]
  [[ "$output" == *"Projects live in /home/agbox-test-nobody/dev"* ]]
}

@test "instructions_pointer names the shared AGENTS.md" {
  run instructions_pointer /home/me/.config/agents/AGENTS.md
  [[ "$output" == *"are in /home/me/.config/agents/AGENTS.md. Read it before"* ]]
}

@test "dry-run helpers print instead of executing" {
  AGBOX_DRY_RUN=true
  local marker="$BATS_TEST_TMPDIR/should-not-exist"
  run run_root touch "$marker"
  [ "$status" -eq 0 ] && [ ! -e "$marker" ]
  [[ "$output" == *"[root] touch $marker"* ]]
}

@test "write_file: writes once, then reports unchanged" {
  AGBOX_DRY_RUN=false
  is_root || skip "needs root (as_root without sudo)"
  local f="$BATS_TEST_TMPDIR/sub/out.txt"
  write_file root "$f" 0640 <<<"hello"
  [ "$FILE_CHANGED" = true ] && [ "$(cat "$f")" = hello ]
  [ "$(stat -c %a "$f")" = 640 ]
  write_file root "$f" 0640 <<<"hello"
  [ "$FILE_CHANGED" = false ]
}

@test "write_file: writes through symlinks instead of replacing them (dotfiles)" {
  AGBOX_DRY_RUN=false
  is_root || skip "needs root (as_root without sudo)"
  local real="$BATS_TEST_TMPDIR/dotfiles/bashrc" link="$BATS_TEST_TMPDIR/.bashrc"
  mkdir -p "$(dirname "$real")" && echo "alias ll=ls" >"$real" && ln -s "$real" "$link"
  ensure_block root "$link" 0644 '#' <<<"export FOO=1"
  [ -L "$link" ]
  grep -q "export FOO=1" "$real"
  grep -q "alias ll=ls" "$real"
}
