#!/usr/bin/env bats

setup() {
  load test_helper
  clean_env
  load_agbox
  load_config "" USER=agbox-test-primary
}

@test "parse_agent_user accepts a username with an optional service unit" {
  run parse_agent_user openbot
  [ "$status" -eq 0 ]
  [ "$output" = openbot ]
  run parse_agent_user openbot:openbot.service
  [ "$status" -eq 0 ]
  [ "$output" = $'openbot\nopenbot.service' ]
  run parse_agent_user agent:worker@agent.service
  [ "$status" -eq 0 ]
}

@test "AGENT_USERS rejects invalid, privileged, primary and duplicate entries" {
  local value
  for value in root agbox-test-primary 'bad/name' 'agent:' 'agent:foo.timer' \
    'agent:../../evil.service' 'agent:foo.service:bar' 'agent:foo service' \
    'agent agent:foo.service'; do
    run load_config "" USER=agbox-test-primary "AGENT_USERS=$value"
    [ "$status" -ne 0 ]
    [[ "$output" == *AGENT_USERS* ]]
  done
  run load_config "" USER=agbox-test-primary 'AGENT_USERS=openbot:openbot.service another-agent'
  [ "$status" -eq 0 ]
}

@test "scoped agent account restores primary user and names dry-run commands" {
  AGBOX_DRY_RUN=true
  run with_agent_user openbot openbot.service run_user echo example
  [ "$status" -eq 0 ]
  [[ "$output" == *'[openbot] echo example'* ]]
  with_agent_user openbot '' target_user >/dev/null
  [ "$AGBOX_USER" = agbox-test-primary ]
  ! declare -p AGBOX_AGENT_UNIT 2>/dev/null
}

@test "missing agent accounts warn and skip callbacks" {
  AGBOX_AGENT_USERS=agbox-nonexistent-92398
  run for_agent_users echo should-not-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not exist; skipping"* ]]
  [[ "$output" != *should-not-run* ]]
}

