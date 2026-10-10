#!/usr/bin/env bats
# The CLI as a user sees it. Dry-runs only: nothing on the host is changed.

setup() {
  load test_helper
  clean_env
  export AGBOX_OS_RELEASE="$FIXTURES/os-release-debian13"
}

@test "help and version" {
  run "$AGBOX" --help
  [ "$status" -eq 0 ] && [[ "$output" == *"Usage: agbox <command>"* ]]
  run "$AGBOX" version
  [ "$status" -eq 0 ] && [[ "$output" == "agbox $(cat "$AGBOX_ROOT/VERSION")" ]]
}

@test "unknown command and option fail clearly" {
  run "$AGBOX" frobnicate
  [ "$status" -ne 0 ] && [[ "$output" == *"unknown command 'frobnicate'"* ]]
  run "$AGBOX" setup --frobnicate
  [ "$status" -ne 0 ] && [[ "$output" == *"unknown option '--frobnicate'"* ]]
}

@test "modules lists every module with its state" {
  run "$AGBOX" modules --set FIREWALL=true --set USER=tester
  [ "$status" -eq 0 ]
  [[ "$output" == *"firewall   on"* ]]
  [ "${#lines[@]}" -eq 11 ]
}

@test "--set accepts keys with or without the AGBOX_ prefix" {
  run "$AGBOX" config --set AGBOX_DOCKER=false --set gh=false --set USER=tester
  [[ "$output" == *'AGBOX_DOCKER="false"'* && "$output" == *'AGBOX_GH="false"'* ]]
}

@test "setup --dry-run shows the plan and changes nothing" {
  local before after
  before=$(ls -la /etc /home 2>/dev/null | md5sum)
  run "$AGBOX" setup --dry-run --set USER=agbox-dryrun-user --set SERVICES="t3code hermes" \
    --set AGENTS="claude codex opencode" --profile vps
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run: nothing will be changed."* ]]
  [[ "$output" == *"==> agents"* && "$output" == *"==> services"* ]]
  [[ "$output" == *"Dry run complete."* ]]
  after=$(ls -la /etc /home 2>/dev/null | md5sum)
  [ "$before" = "$after" ]
  ! id agbox-dryrun-user 2>/dev/null
}

@test "setup --dry-run never prints the Tailscale auth key" {
  run "$AGBOX" setup --dry-run --set USER=agbox-dryrun-user --set TAILSCALE_AUTHKEY=tskey-auth-SECRET123
  [ "$status" -eq 0 ]
  [[ "$output" != *"SECRET123"* ]]
}

@test "--only runs just the named modules" {
  run "$AGBOX" setup --dry-run --set USER=agbox-dryrun-user --only system,mise
  [ "$status" -eq 0 ]
  [[ "$output" == *"==> system"* && "$output" == *"==> mise"* ]]
  [[ "$output" != *"==> docker"* ]]
}

@test "unsupported distributions are refused" {
  AGBOX_OS_RELEASE="$FIXTURES/os-release-fedora" run "$AGBOX" setup --dry-run
  [ "$status" -ne 0 ] && [[ "$output" == *"unsupported distribution"* ]]
}
