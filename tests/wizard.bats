#!/usr/bin/env bats
# The setup wizard: pure helpers, then the prompts fed from an answers file.

setup() {
  load test_helper
  clean_env
  load_agbox
  AGBOX_USER=tester
  export AGBOX_USER
  load_config ""
}

# answers LINE... : what the operator will type, one answer per line.
answers() {
  printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/answers"
  AGBOX_TTY="$BATS_TEST_TMPDIR/answers"
  _TTY_FD=''
}

@test "wizard_pick: by number or name, case-insensitive" {
  run wizard_pick 2 homelab vps
  [ "$status" -eq 0 ] && [ "$output" = vps ]
  run wizard_pick VPS homelab vps
  [ "$status" -eq 0 ] && [ "$output" = vps ]
}

@test "wizard_pick: rejects unknown names and out-of-range numbers" {
  run wizard_pick 0 homelab vps
  [ "$status" -eq 1 ]
  run wizard_pick 3 homelab vps
  [ "$status" -eq 1 ]
  run wizard_pick 01 homelab vps
  [ "$status" -eq 1 ]
  run wizard_pick cloud homelab vps
  [ "$status" -eq 1 ] && [ -z "$output" ]
}

@test "wizard_toggle: switches options on and off, keeping option order" {
  run wizard_toggle "claude codex" "3" claude codex opencode
  [ "$output" = "claude codex opencode" ]
  run wizard_toggle "claude codex" "1, codex" claude codex opencode
  [ "$output" = "" ]
  run wizard_toggle "opencode" "1" claude codex opencode
  [ "$output" = "claude opencode" ]
}

@test "wizard_toggle: empty input normalizes order and drops unknown words" {
  run wizard_toggle "opencode bogus claude" "" claude codex opencode
  [ "$status" -eq 0 ] && [ "$output" = "claude opencode" ]
}

@test "wizard_toggle: fails on an unknown option" {
  run wizard_toggle "claude" "1 9" claude codex opencode
  [ "$status" -eq 1 ] && [ -z "$output" ]
}

@test "ask_apply: yes, no and customize" {
  answers ""
  ask_apply 2>/dev/null
  [ "$WIZ_ANSWER" = yes ]
  answers N
  ask_apply 2>/dev/null
  [ "$WIZ_ANSWER" = no ]
  answers what c
  ask_apply 2>/dev/null
  [ "$WIZ_ANSWER" = customize ]
}

@test "ask_apply: end of input means no; --yes means yes without asking" {
  answers
  : >"$AGBOX_TTY"
  ask_apply 2>/dev/null
  [ "$WIZ_ANSWER" = no ]
  AGBOX_YES=true
  AGBOX_TTY=/nonexistent
  ask_apply
  [ "$WIZ_ANSWER" = yes ]
}

@test "run_wizard: Enter everywhere changes nothing" {
  answers "" "" "" "" "" "" "" "" "" ""
  run_wizard 2>/dev/null
  [ "${#WIZARD_SETS[@]}" -eq 0 ]
}

@test "run_wizard: answers become overrides, invalid ones are asked again" {
  answers \
    vps \
    "2 3" "" \
    sandboxed \
    t3code "" \
    "1,4" "" \
    root dev \
    Bad_Host box-1 \
    "" \
    "Ada Lovelace" \
    nope ada@example.com
  run_wizard 2>"$BATS_TEST_TMPDIR/prompts"
  local IFS='|'
  [ "${WIZARD_SETS[*]}" = "PROFILE=vps|AGENTS=claude opencode|AGENT_MODE=sandboxed|SERVICES=t3code|DOCKER=false|GH=false|USER=dev|HOSTNAME=box-1|GIT_NAME=Ada Lovelace|GIT_EMAIL=ada@example.com" ]
  grep -q "not root" "$BATS_TEST_TMPDIR/prompts"
  grep -q "expected name@domain" "$BATS_TEST_TMPDIR/prompts"
}

@test "run_wizard: no agents skips the permissions question; - clears a text value" {
  AGBOX_GIT_NAME="Old Name"
  answers "" "1 2" "" "" "" "" "" "" - ""
  run_wizard 2>/dev/null
  local IFS='|'
  [ "${WIZARD_SETS[*]}" = "AGENTS=|GIT_NAME=" ]
}

@test "run_wizard: running out of answers aborts" {
  answers ""
  run run_wizard
  [ "$status" -ne 0 ] && [[ "$output" == *"aborted"* ]]
}
