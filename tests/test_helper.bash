# shellcheck shell=bash
# Shared setup for bats tests. Loads agbox libraries without running main().
# shellcheck disable=SC2034 # variables are used by the .bats files and the libraries

AGBOX_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
AGBOX="$AGBOX_ROOT/bin/agbox"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"
export AGBOX_ROOT FIXTURES NO_COLOR=1

load_agbox() {
  AGBOX_VERSION='test'
  AGBOX_REPO=antomanc/agbox
  # shellcheck source=lib/core.sh
  source "$AGBOX_ROOT/lib/core.sh"
  # shellcheck source=lib/config.sh
  source "$AGBOX_ROOT/lib/config.sh"
  # shellcheck source=lib/os.sh
  source "$AGBOX_ROOT/lib/os.sh"
  # shellcheck source=lib/modules.sh
  source "$AGBOX_ROOT/lib/modules.sh"
  # shellcheck source=lib/preseed.sh
  source "$AGBOX_ROOT/lib/preseed.sh"
  load_modules
}

# Clear AGBOX_* from the environment so tests don't depend on the caller's shell.
clean_env() {
  local var
  for var in $(compgen -v AGBOX_); do
    [[ $var == AGBOX_ROOT || $var == AGBOX_VERSION || $var == AGBOX_REPO ]] || unset "$var"
  done
  # Never pick up the host's real /etc/agbox/agbox.conf.
  export AGBOX_SYSTEM_CONFIG="$BATS_TEST_TMPDIR/no-system-config"
}
