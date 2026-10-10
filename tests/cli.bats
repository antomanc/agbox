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

@test "setup: answering no aborts before changing anything" {
  printf 'n\n' >"$BATS_TEST_TMPDIR/answers"
  AGBOX_TTY="$BATS_TEST_TMPDIR/answers" run "$AGBOX" setup --set USER=agbox-dryrun-user
  [ "$status" -ne 0 ] && [[ "$output" == *"error: aborted"* ]]
  ! id agbox-dryrun-user 2>/dev/null
}

@test "setup: customize updates the plan, then asks again" {
  # profile, agents (toggle codex off), agent mode, services, components (gh off), user,
  # hostname, timezone, git name, git email; then decline.
  printf '%s\n' c vps 2 "" "" "" 4 "" "" "" "" "" "" n >"$BATS_TEST_TMPDIR/answers"
  AGBOX_TTY="$BATS_TEST_TMPDIR/answers" run "$AGBOX" setup --set USER=agbox-dryrun-user
  [ "$status" -ne 0 ] && [[ "$output" == *"error: aborted"* ]]
  [[ "$output" == *"(homelab profile"* && "$output" == *"(vps profile"* ]]
  [[ "$output" == *'AGENTS="claude"'* && "$output" == *'GH="false"'* ]]
  [[ "$output" == *"coding agents (claude) in yolo mode"* ]]
  [[ "$output" == *"✓ firewall"* ]]
  [[ "$output" == *"devtools   git defaults, Playwright"* ]]
  [ "$(grep -c 'Apply?' <<<"$output")" -eq 2 ]
  ! id agbox-dryrun-user 2>/dev/null
}

@test "setup works with passwordless sudo when sudo -v would prompt" {
  [ "$EUID" -ne 0 ] || skip "root never calls sudo"
  # Fake sudo: NOPASSWD for commands, but -v demands a password (Debian's %sudo rule).
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\n[ "$1" = -v ] && exit 1\n[ "$1" = -n ] && shift\n[ "$1" = -- ] && shift\nexec "$@"\n' \
    >"$BATS_TEST_TMPDIR/bin/sudo"
  chmod +x "$BATS_TEST_TMPDIR/bin/sudo"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$AGBOX" setup --dry-run --yes --set USER=agbox-dryrun-user --only system
  [ "$status" -eq 0 ]
  [[ "$output" != *"sudo authentication failed"* ]]
}
