#!/usr/bin/env bash
# agbox installer: downloads agbox to /opt/agbox, links /usr/local/bin/agbox, runs `agbox setup`.
#
#   curl -fsSL https://raw.githubusercontent.com/antomanc/agbox/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --profile vps --yes     # args go to `agbox setup`
#
# Environment: AGBOX_REF (git branch/tag, default main), AGBOX_REPO, AGBOX_PREFIX,
#              AGBOX_TARBALL_URL (mirror/fork tarball), AGBOX_NO_SETUP=1 (install/update only).
set -euo pipefail

# Everything runs from main(), so a partially downloaded script never executes.
main() {
  local repo=${AGBOX_REPO:-antomanc/agbox}
  local ref=${AGBOX_REF:-main}
  local prefix=${AGBOX_PREFIX:-/opt/agbox}
  local url=${AGBOX_TARBALL_URL:-https://codeload.github.com/$repo/tar.gz/$ref}
  local sudo=''

  if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null || fail "run as root, or install sudo first"
    sudo=sudo
  fi
  for cmd in curl tar; do
    command -v "$cmd" >/dev/null || fail "'$cmd' is required: apt-get install -y $cmd"
  done
  [[ $ref =~ ^[A-Za-z0-9._/-]+$ ]] || fail "invalid AGBOX_REF '$ref'"

  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT
  local tmp=$TMP_DIR

  say "downloading agbox from $url"
  curl -fsSL --retry 3 "$url" | tar -xz -C "$tmp" --strip-components=1 ||
    fail "download failed: check AGBOX_REF and your network"
  [[ -x $tmp/bin/agbox ]] || fail "downloaded archive does not contain bin/agbox"

  # Atomic-ish replace: never leave a half-installed agbox behind.
  $sudo rm -rf "$prefix.new"
  $sudo mkdir -p "$(dirname "$prefix")"
  $sudo cp -R "$tmp" "$prefix.new"
  $sudo chmod -R u=rwX,go=rX "$prefix.new" # mktemp dirs are 0700: make it usable by all
  $sudo rm -rf "$prefix.old"
  if [[ -e $prefix ]]; then $sudo mv "$prefix" "$prefix.old"; fi
  $sudo mv "$prefix.new" "$prefix"
  $sudo rm -rf "$prefix.old"
  $sudo ln -sfn "$prefix/bin/agbox" /usr/local/bin/agbox
  rm -rf "$TMP_DIR" # `exec` below skips the EXIT trap
  say "installed $("$prefix/bin/agbox" version) to $prefix"

  if [[ -n ${AGBOX_NO_SETUP:-} ]]; then return 0; fi

  # When piped (curl | bash), stdin is the script: give setup the real terminal if there is one.
  if [[ ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then
    exec /usr/local/bin/agbox setup "$@" </dev/tty
  fi
  exec /usr/local/bin/agbox setup "$@"
}

TMP_DIR=''
if [[ -t 2 && -z ${NO_COLOR:-} ]]; then BOLD=$'\e[1m' RED=$'\e[31m' RESET=$'\e[0m'; else BOLD='' RED='' RESET=''; fi
say() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*" >&2; }
fail() {
  printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}

main "$@"
