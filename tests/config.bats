#!/usr/bin/env bats
# Configuration parsing, precedence and validation.

setup() {
  load test_helper
  clean_env
  load_agbox
  AGBOX_USER=tester # avoid depending on who runs the tests
  export AGBOX_USER
}

@test "parse_config_line: blank lines and comments produce nothing" {
  run parse_config_line ""
  [ "$status" -eq 0 ] && [ -z "$output" ]
  run parse_config_line "   # just a comment"
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "parse_config_line: strips prefix, quotes, export and inline comments" {
  run parse_config_line 'AGBOX_DOCKER="false"'
  [ "$output" = "DOCKER=false" ]
  run parse_config_line "export AGBOX_AGENTS='claude opencode'"
  [ "$output" = "AGENTS=claude opencode" ]
  run parse_config_line "ZRAM_PERCENT=75   # comment"
  [ "$output" = "ZRAM_PERCENT=75" ]
  run parse_config_line 'GIT_NAME="Ada # Lovelace"'
  [ "$output" = "GIT_NAME=Ada # Lovelace" ]
  run parse_config_line 'docker=true'
  [ "$output" = "DOCKER=true" ]
}

@test "parse_config_line: rejects lines that aren't KEY=VALUE" {
  run parse_config_line 'rm -rf /'
  [ "$status" -eq 2 ]
}

@test "load_config: defaults" {
  load_config ""
  [ "$AGBOX_PROFILE" = homelab ]
  [ "$AGBOX_DOCKER" = true ]
  [ "$AGBOX_FIREWALL" = false ]
  [ "$AGBOX_AGENTS" = "claude codex" ]
}

@test "load_config: vps profile turns on firewall and SSH hardening" {
  load_config "" PROFILE=vps
  [ "$AGBOX_FIREWALL" = true ]
  [ "$AGBOX_SSH_HARDEN" = true ]
}

@test "load_config: file overrides profile, env overrides file, flags override env" {
  export AGBOX_HOSTNAME=from-env
  load_config "$FIXTURES/sample.conf" DOCKER=true
  [ "$AGBOX_HOSTNAME" = from-env ]   # env > file
  [ "$AGBOX_DOCKER" = true ]         # flag > file
  [ "$AGBOX_AGENTS" = "claude opencode" ]
  [ "$AGBOX_ZRAM_PERCENT" = 75 ]
  [ "$AGBOX_GIT_NAME" = "Ada # Lovelace" ]
}

@test "load_config: profile set in the config file is honoured" {
  local f="$BATS_TEST_TMPDIR/p.conf"
  echo 'AGBOX_PROFILE=vps' >"$f"
  load_config "$f"
  [ "$AGBOX_PROFILE" = vps ]
  [ "$AGBOX_FIREWALL" = true ]
}

@test "load_config: explicit setting beats the profile preset" {
  load_config "" PROFILE=vps FIREWALL=false
  [ "$AGBOX_FIREWALL" = false ]
}

@test "load_config: booleans are normalised" {
  load_config "" DOCKER=yes GH=OFF
  [ "$AGBOX_DOCKER" = true ]
  [ "$AGBOX_GH" = false ]
}

@test "load_config: unknown keys warn but don't fail" {
  run load_config "" NOT_A_SETTING=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown setting 'NOT_A_SETTING'"* ]]
}

@test "load_config: invalid values fail with a clear message" {
  run load_config "" DOCKER=maybe
  [ "$status" -ne 0 ] && [[ "$output" == *"DOCKER must be true or false"* ]]
  run load_config "" AGENTS="claude cursor"
  [ "$status" -ne 0 ] && [[ "$output" == *"unknown value 'cursor'"* ]]
  run load_config "" AGENT_MODE=wild
  [ "$status" -ne 0 ]
  run load_config "" PROFILE=desktop
  [ "$status" -ne 0 ] && [[ "$output" == *"unknown profile"* ]]
  run load_config "" ZRAM_PERCENT=500
  [ "$status" -ne 0 ]
  run load_config "" HOSTNAME=Bad_Name
  [ "$status" -ne 0 ]
  run load_config "" DOCKER_DATA_ROOT=relative/path
  [ "$status" -ne 0 ]
}

@test "load_config: refuses root as the agent user" {
  run load_config "" USER=root
  [ "$status" -ne 0 ] && [[ "$output" == *"must not be root"* ]]
}

@test "load_config: codex needs node in MISE_TOOLS" {
  run load_config "" MISE_TOOLS="python@3.13" AGENTS=codex
  [ "$status" -ne 0 ] && [[ "$output" == *"must include node"* ]]
  run load_config "" MISE_TOOLS="python@3.13" AGENTS=claude
  [ "$status" -eq 0 ]
}

@test "load_config: malformed config file reports file and line" {
  local f="$BATS_TEST_TMPDIR/bad.conf"
  printf 'AGBOX_DOCKER=true\nthis is not valid\n' >"$f"
  run load_config "$f"
  [ "$status" -ne 0 ] && [[ "$output" == *"bad.conf:2"* ]]
}

@test "print_config output round-trips through the parser" {
  load_config "" GIT_NAME='Ada "the countess" Lovelace' MISE_TOOLS="node@22 uv"
  local f="$BATS_TEST_TMPDIR/roundtrip.conf"
  print_config >"$f"
  AGBOX_GIT_NAME='' AGBOX_MISE_TOOLS=''
  load_config "$f"
  [ "$AGBOX_GIT_NAME" = 'Ada "the countess" Lovelace' ]
  [ "$AGBOX_MISE_TOOLS" = "node@22 uv" ]
}

@test "print_config masks secrets" {
  load_config "" TAILSCALE_AUTHKEY=tskey-super-secret
  run print_config
  [[ "$output" != *"tskey-super-secret"* ]]
  [[ "$output" == *'AGBOX_TAILSCALE_AUTHKEY="********"'* ]]
}

@test "expand_home uses the target user's home" {
  AGBOX_USER=nonexistent-user-xyz
  [ "$(expand_home '~/dev')" = /home/nonexistent-user-xyz/dev ]
  [ "$(expand_home /srv/code)" = /srv/code ]
}
