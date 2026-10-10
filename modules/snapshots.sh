# shellcheck shell=bash
# Snapper timeline snapshots of a btrfs root: roll back anything an agent breaks.

SNAPPER_CONFIG=/etc/snapper/configs/root
SNAPSHOT_BASELINE="agbox: baseline"

snapshots::describe() { echo "snapper hourly/daily snapshots of / (btrfs only) + a baseline snapshot"; }
snapshots::enabled() {
  case $AGBOX_SNAPSHOTS in
    false) return 1 ;;
    true) return 0 ;;
    auto) [[ $(root_fstype) == btrfs ]] ;;
  esac
}

snapshots::apply() {
  if [[ $(root_fstype) != btrfs ]]; then
    log_warn "/ is $(root_fstype), not btrfs: snapshots skipped (reinstall with btrfs to get them)"
    return 0
  fi
  apt_install snapper

  if as_root test -f "$SNAPPER_CONFIG"; then
    log_skip "snapper config for / exists"
  else
    run_root snapper -c root create-config /
  fi
  # Small, bounded history: enough to undo a bad agent session, without filling the disk.
  run_root snapper -c root set-config \
    TIMELINE_CREATE=yes TIMELINE_CLEANUP=yes NUMBER_CLEANUP=yes NUMBER_LIMIT=20 \
    TIMELINE_LIMIT_HOURLY=5 TIMELINE_LIMIT_DAILY=7 TIMELINE_LIMIT_WEEKLY=2 \
    TIMELINE_LIMIT_MONTHLY=0 TIMELINE_LIMIT_YEARLY=0
  if has_systemd; then
    run_root systemctl enable --now snapper-timeline.timer snapper-cleanup.timer >/dev/null
  fi

  if _snapshot_baseline_exists; then
    log_skip "baseline snapshot exists"
  else
    run_root snapper -c root create --description "$SNAPSHOT_BASELINE"
    log_ok "baseline snapshot created (list: sudo snapper list)"
  fi
}

_snapshot_baseline_exists() {
  as_root test -f "$SNAPPER_CONFIG" &&
    as_root snapper -c root --csvout list --columns description 2>/dev/null | grep -qxF "$SNAPSHOT_BASELINE"
}

snapshots::check() {
  if ! as_root test -f "$SNAPPER_CONFIG"; then
    check_fail "snapper configured for /" "agbox setup --only snapshots"
    return 0
  fi
  check_pass "snapper configured for /"
  check systemctl is-active --quiet snapper-timeline.timer -- "hourly snapshot timer active" "sudo systemctl enable --now snapper-timeline.timer"
}
