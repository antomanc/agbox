#!/usr/bin/env bats
# `agbox preseed`: generated installer answers and the embedded first-boot payload.

HASH='$6$saltsalt$Gn6XnFq3yU1xU5OkSfjQo6m2pQJ1vZ8rD0lYbT1uWv7eY4aA9cJ2xK3nH5mL8pR0sT6wQ9zV1yB4dF7gE2hC.'

setup() {
  load test_helper
  clean_env
  export AGBOX_OS_RELEASE="$FIXTURES/os-release-debian13"
  KEY="$BATS_TEST_TMPDIR/id.pub"
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTests test@laptop" >"$KEY"
}

# Extract and decode the base64 payload written to PATH by the late_command.
payload_for() {
  local path=$1
  grep '^d-i preseed/late_command' <<<"$output" | tr ';' '\n' | grep -F "> $path" |
    sed -E 's/.*echo ([A-Za-z0-9+/=]+) \| base64 -d.*/\1/' | base64 -d
}

@test "preseed: answers every critical question" {
  run "$AGBOX" preseed --hostname box1 --user ada --password-hash "$HASH" --ssh-key "$KEY" --timezone Europe/Rome --keymap it
  [ "$status" -eq 0 ]
  [[ "$output" == *"d-i netcfg/hostname string box1"* ]]
  [[ "$output" == *"d-i passwd/username string ada"* ]]
  [[ "$output" == *"d-i passwd/user-password-crypted password $HASH"* ]]
  [[ "$output" == *"d-i passwd/root-login boolean false"* ]]
  [[ "$output" == *"d-i time/zone string Europe/Rome"* ]]
  [[ "$output" == *"d-i keyboard-configuration/xkb-keymap select it"* ]]
  [[ "$output" == *"filesystem{ btrfs } mountpoint{ / }"* ]]
  [[ "$output" == *"d-i partman-basicfilesystems/no_swap boolean false"* ]]
  [[ "$output" == *"d-i grub-installer/force-efi-extra-removable boolean true"* ]]
  [[ "$output" == *"tasksel/first multiselect standard, ssh-server"* ]]
}

@test "preseed: auto disk prefers NVMe/virtio via early_command" {
  run "$AGBOX" preseed --password-hash "$HASH"
  [[ "$output" == *'d-i partman/early_command string D="$(list-devices disk | grep -E "/dev/(nvme|vd)"'* ]]
  run "$AGBOX" preseed --password-hash "$HASH" --disk /dev/sda
  [[ "$output" == *"d-i partman-auto/disk string /dev/sda"* ]]
  [[ "$output" != *"early_command"* ]]
}

@test "preseed: embeds the SSH key, agbox config and first-boot unit" {
  run "$AGBOX" preseed --user ada --hostname box1 --password-hash "$HASH" --ssh-key "$KEY" \
    --profile vps --set TAILSCALE_AUTHKEY=tskey-abc --set AGENTS="claude opencode" --timezone Etc/UTC
  [ "$status" -eq 0 ]

  [ "$(payload_for /home/ada/.ssh/authorized_keys)" = "$(cat "$KEY")" ]

  local conf
  conf=$(payload_for /etc/agbox/agbox.conf)
  [[ "$conf" == *'AGBOX_USER="ada"'* ]]
  [[ "$conf" == *'AGBOX_HOSTNAME="box1"'* ]]
  [[ "$conf" == *'AGBOX_PROFILE="vps"'* ]]
  [[ "$conf" == *'AGBOX_AGENTS="claude opencode"'* ]]
  [[ "$conf" == *'AGBOX_TAILSCALE_AUTHKEY="tskey-abc"'* ]]

  local unit
  unit=$(payload_for /etc/systemd/system/agbox-firstboot.service)
  [[ "$unit" == *"After=network-online.target"* ]]
  [[ "$unit" == *"ConditionPathExists=!/var/lib/agbox/firstboot.done"* ]]
  [[ "$unit" == *"raw.githubusercontent.com/antomanc/agbox/main/install.sh | bash -s -- --yes"* ]]
}

@test "preseed: the embedded config is valid agbox config" {
  run "$AGBOX" preseed --user ada --password-hash "$HASH" --set DOCKER=false
  local f="$BATS_TEST_TMPDIR/embedded.conf"
  payload_for /etc/agbox/agbox.conf >"$f"
  run "$AGBOX" config --config "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *'AGBOX_USER="ada"'* && "$output" == *'AGBOX_DOCKER="false"'* ]]
}

@test "preseed: --no-firstboot without keys has no late_command" {
  run "$AGBOX" preseed --password-hash "$HASH" --no-firstboot
  [ "$status" -eq 0 ]
  [[ "$output" != *"late_command"* ]]
}

@test "preseed: rejects invalid input before generating anything" {
  run "$AGBOX" preseed --password-hash "$HASH" --set DOCKER=perhaps
  [ "$status" -ne 0 ] && [[ "$output" == *"DOCKER must be true or false"* ]]
  run "$AGBOX" preseed --password-hash "$HASH" --hostname "Not Valid"
  [ "$status" -ne 0 ]
  run "$AGBOX" preseed --password-hash "plaintext"
  [ "$status" -ne 0 ]
  local priv="$BATS_TEST_TMPDIR/id"
  echo "-----BEGIN OPENSSH PRIVATE KEY-----" >"$priv"
  run "$AGBOX" preseed --password-hash "$HASH" --ssh-key "$priv"
  [ "$status" -ne 0 ] && [[ "$output" == *"public"* ]]
}

@test "preseed: --output writes the file and prints Ventoy instructions" {
  run "$AGBOX" preseed --password-hash "$HASH" -o "$BATS_TEST_TMPDIR/preseed.cfg"
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/preseed.cfg" ]
  [[ "$output" == *"auto_install"* ]]
}
