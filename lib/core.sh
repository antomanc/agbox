# shellcheck shell=bash
# Core helpers: logging, privilege, dry-run aware execution and idempotent file edits.
# Every mutating operation in agbox goes through run_root / run_user / write_file /
# ensure_block, so --dry-run is honoured everywhere by construction.

# ---------------------------------------------------------------- logging ----

if [[ -t 2 && -z ${NO_COLOR:-} ]]; then
  _C_RESET=$'\e[0m' _C_DIM=$'\e[2m' _C_BOLD=$'\e[1m'
  _C_RED=$'\e[31m' _C_GREEN=$'\e[32m' _C_YELLOW=$'\e[33m' _C_BLUE=$'\e[34m'
else
  _C_RESET='' _C_DIM='' _C_BOLD='' _C_RED='' _C_GREEN='' _C_YELLOW='' _C_BLUE=''
fi

log_section() { printf '\n%s==> %s%s\n' "$_C_BOLD$_C_BLUE" "$*" "$_C_RESET" >&2; }
log_info() { printf '  %s\n' "$*" >&2; }
log_ok() { printf '  %s✓%s %s\n' "$_C_GREEN" "$_C_RESET" "$*" >&2; }
log_skip() { printf '  %s· %s%s\n' "$_C_DIM" "$*" "$_C_RESET" >&2; }
log_warn() { printf '  %s! %s%s\n' "$_C_YELLOW" "$*" "$_C_RESET" >&2; }
log_error() { printf '%serror:%s %s\n' "$_C_RED$_C_BOLD" "$_C_RESET" "$*" >&2; }
die() {
  log_error "$*"
  exit 1
}

# Follow-up actions printed at the end of `agbox setup` (logins etc.).
NEXT_STEPS=()
add_next_step() { NEXT_STEPS+=("$*"); }

# ---------------------------------------------------------------- helpers ----

has_cmd() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ $EUID -eq 0 ]]; }
is_dry_run() { [[ ${AGBOX_DRY_RUN:-false} == true ]]; }

# Questions are read from the terminal, even under `curl | bash`. AGBOX_TTY points
# elsewhere only in tests, which feed answers from a file.
AGBOX_TTY=${AGBOX_TTY:-/dev/tty}

# Can we ask the operator a question?
is_interactive() { [[ ${AGBOX_YES:-false} != true ]] && [[ -r $AGBOX_TTY ]] && { : <"$AGBOX_TTY"; } 2>/dev/null; }

# tty_printf FORMAT ARGS... : print a prompt where the operator sees it.
tty_printf() {
  # shellcheck disable=SC2059 # FORMAT is the caller's format string
  if [[ $AGBOX_TTY == /dev/tty ]]; then printf "$@" >/dev/tty; else printf "$@" >&2; fi
}

# tty_read VAR : read one answer line. Fails on end of input. The descriptor stays open,
# so answers fed from a file are consumed in order.
_TTY_FD=''
tty_read() {
  if [[ -z $_TTY_FD ]]; then exec {_TTY_FD}<"$AGBOX_TTY"; fi
  IFS= read -r "$1" <&"$_TTY_FD"
}

# Render a command line for display, shell-quoted.
_quote_cmd() {
  local out='' arg
  for arg in "$@"; do
    if [[ $arg =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then out+="$arg "; else out+="$(printf '%q' "$arg") "; fi
  done
  printf '%s' "${out% }"
}

# ------------------------------------------------------------- privileges ----

# Target user resolved by config.sh (AGBOX_USER). Cached lookups below.
target_user() { printf '%s' "$AGBOX_USER"; }
# These print nothing (and still succeed) when the user doesn't exist yet, e.g. in a dry-run.
target_uid() { id -u "$AGBOX_USER" 2>/dev/null || true; }
target_home() {
  local entry
  entry=$(getent passwd "$AGBOX_USER") || return 0
  cut -d: -f6 <<<"$entry"
}
target_exists() { id "$AGBOX_USER" >/dev/null 2>&1; }

# as_root CMD... : run with root privileges (no dry-run handling; use run_root for changes).
as_root() {
  if is_root; then "$@"; else sudo -- "$@"; fi
}

# as_user CMD... : run as the target user with a predictable environment
# (HOME, user-level PATH incl. mise shims, systemd --user bus). The caller's XDG dirs are
# dropped: they point into the invoking user's home, which the target user can't read.
as_user() {
  local user home uid
  user=$(target_user) home=$(target_home) uid=$(target_uid)
  [[ -n $home && -n $uid ]] || die "target user '$user' does not exist"
  local -a env=(
    env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME -u XDG_STATE_HOME
    "HOME=$home" "USER=$user" "LOGNAME=$user"
    "PATH=$home/.local/bin:$home/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    "XDG_RUNTIME_DIR=/run/user/$uid"
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus"
  )
  if [[ $(id -u) == "$uid" ]]; then
    (cd "$home" && "${env[@]}" "$@")
  elif is_root; then
    (cd "$home" && runuser -u "$user" -- "${env[@]}" "$@")
  else
    (cd "$home" && sudo -u "$user" -- "${env[@]}" "$@")
  fi
}

# run_root / run_user: like as_root / as_user, but only print the command in dry-run mode.
run_root() {
  if is_dry_run; then
    printf '  %s[root]%s %s\n' "$_C_DIM" "$_C_RESET" "$(_quote_cmd "$@")" >&2
    return 0
  fi
  as_root "$@"
}

run_user() {
  if is_dry_run; then
    printf '  %s[%s]%s %s\n' "$_C_DIM" "$(target_user)" "$_C_RESET" "$(_quote_cmd "$@")" >&2
    return 0
  fi
  as_user "$@"
}

# _run_as root|user CMD...
_run_as() {
  local who=$1
  shift
  case $who in
    root) run_root "$@" ;;
    user) run_user "$@" ;;
    *) die "internal: unknown owner '$who'" ;;
  esac
}

_read_as() {
  local who=$1 path=$2
  case $who in
    root) as_root cat -- "$path" 2>/dev/null ;;
    user) if target_exists; then as_user cat -- "$path" 2>/dev/null; else return 1; fi ;;
  esac
}

# ------------------------------------------------------------ file edits ----

# write_file root|user PATH MODE  <<< content
# Atomically writes PATH only if its content differs. Sets FILE_CHANGED=true|false.
# A symlinked PATH (e.g. a dotfiles-managed ~/.bashrc) is written through, never replaced.
FILE_CHANGED=false
write_file() {
  local who=$1 path=$2 mode=$3 content current
  content=$(cat)
  current=$(_read_as "$who" "$path") || current=$'\x01missing'
  if [[ $current == "$content" ]]; then
    FILE_CHANGED=false
    return 0
  fi
  FILE_CHANGED=true
  if is_dry_run; then
    printf '  %s[%s]%s write %s\n' "$_C_DIM" "$who" "$_C_RESET" "$path" >&2
    return 0
  fi
  # shellcheck disable=SC2016 # expanded by the inner shell
  printf '%s\n' "$content" | _run_as "$who" sh -c '
    set -e
    dest=$(readlink -f -- "$1" 2>/dev/null) || dest=$1
    mkdir -p "$(dirname "$dest")"
    tmp="$dest.agbox.$$"
    cat >"$tmp"
    chmod "$2" "$tmp"
    mv -f "$tmp" "$dest"
  ' agbox-write "$path" "$mode"
}

# render_block CURRENT NEW_BODY COMMENT [COMMENT_END] -> CURRENT with the managed block
# replaced in place, or appended. Pure function (no I/O) so it is unit-testable.
render_block() {
  local current=$1 body=$2 comment=$3 suffix=${4:+ $4}
  local begin="$comment >>> agbox managed block >>>$suffix"
  local end="$comment <<< agbox managed block <<<$suffix"
  local block="$begin"$'\n'"$body"$'\n'"$end"
  if [[ $current == *"$begin"* && $current == *"$end"* ]]; then
    local before=${current%%"$begin"*}
    local after=${current#*"$end"}
    printf '%s%s%s' "$before" "$block" "$after"
  elif [[ -z $current ]]; then
    printf '%s' "$block"
  else
    printf '%s\n\n%s' "${current%$'\n'}" "$block"
  fi
}

# ensure_block root|user PATH MODE COMMENT [COMMENT_END] <<< body
# Keeps a delimited, agbox-owned block inside a file the user may also edit.
ensure_block() {
  local who=$1 path=$2 mode=$3 comment=$4 suffix=${5:-} body current
  body=$(cat)
  current=$(_read_as "$who" "$path") || current=''
  render_block "$current" "$body" "$comment" "$suffix" | write_file "$who" "$path" "$mode"
}

# ------------------------------------------------------------------- apt ----

# apt_get ARGS... : non-interactive apt-get that waits for the dpkg lock instead of failing
# (on a fresh boot or VPS, unattended-upgrades usually holds it for a few minutes).
apt_get() {
  if is_dry_run; then
    printf '  %s[root]%s apt-get %s\n' "$_C_DIM" "$_C_RESET" "$(_quote_cmd "$@")" >&2
    return 0
  fi
  run_root env DEBIAN_FRONTEND=noninteractive apt-get -qq -o DPkg::Lock::Timeout=600 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

_APT_UPDATED=false
apt_update() {
  if [[ $_APT_UPDATED == true && ${1:-} != --force ]]; then return 0; fi
  apt_get update
  _APT_UPDATED=true
}

pkg_installed() { [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == 'install ok installed' ]]; }

# apt_install PKG... : install only what is missing.
apt_install() {
  local pkg missing=()
  for pkg in "$@"; do pkg_installed "$pkg" || missing+=("$pkg"); done
  if ((${#missing[@]} == 0)); then
    log_skip "packages already installed: $*"
    return 0
  fi
  apt_update
  log_info "installing: ${missing[*]}"
  apt_get install -y "${missing[@]}"
}

# apt_add_repo NAME KEY_URL KEY_FORMAT DEB822_BODY : add a signed third-party repository.
# KEY_FORMAT is asc (ASCII-armored) or gpg (binary): apt picks the parser by extension.
apt_add_repo() {
  local name=$1 key_url=$2 format=$3 body=$4
  [[ $format == asc || $format == gpg ]] || die "internal: key format must be asc or gpg"
  local key="/etc/apt/keyrings/$name.$format"
  if ! as_root test -s "$key"; then
    run_root install -m 0755 -d /etc/apt/keyrings
    run_root curl -fsSL -o "$key" "$key_url"
    run_root chmod a+r "$key"
  fi
  printf '%s\nSigned-By: %s\n' "$body" "$key" | write_file root "/etc/apt/sources.list.d/$name.sources" 0644
  if [[ $FILE_CHANGED == true ]]; then apt_update --force; fi
}

# run_script root|user URL [INTERPRETER] : download an install script completely, then run it.
# Unlike `curl | sh`, a failed or truncated download never executes and always fails loudly.
run_script() {
  local who=$1 url=$2 interpreter=${3:-sh}
  if is_dry_run; then
    printf '  %s[%s]%s curl -fsSL %s | %s\n' "$_C_DIM" "$who" "$_C_RESET" "$url" "$interpreter" >&2
    return 0
  fi
  # shellcheck disable=SC2016 # expanded by the inner bash
  _run_as "$who" bash -c '
    set -euo pipefail
    script=$(curl -fsSL --retry 3 "$1")
    [[ -n $script ]] || { echo "empty download: $1" >&2; exit 1; }
    printf "%s\n" "$script" | "$2"
  ' agbox-run-script "$url" "$interpreter"
}

# ------------------------------------------------------------- systemd ----

# Wait until the target user's systemd manager is reachable (needed after enable-linger).
wait_user_bus() {
  is_dry_run && return 0
  local uid i
  uid=$(target_uid)
  for i in {1..20}; do
    [[ -S /run/user/$uid/bus ]] && return 0
    if ((i == 1)); then
      run_root systemctl start "user@$uid.service" 2>/dev/null || true
    fi
    sleep 0.5
  done
  log_warn "systemd user session for $(target_user) not reachable; user services may need a re-login"
  return 1
}

# --------------------------------------------------------------- doctor ----

DOCTOR_FAILS=0
DOCTOR_WARNS=0
check_pass() { printf '  %s✓%s %s\n' "$_C_GREEN" "$_C_RESET" "$1"; }
check_warn() {
  printf '  %s!%s %s%s\n' "$_C_YELLOW" "$_C_RESET" "$1" "${2:+ ${_C_DIM}→ $2$_C_RESET}"
  DOCTOR_WARNS=$((DOCTOR_WARNS + 1))
}
check_fail() {
  printf '  %s✗%s %s%s\n' "$_C_RED" "$_C_RESET" "$1" "${2:+ ${_C_DIM}→ $2$_C_RESET}"
  DOCTOR_FAILS=$((DOCTOR_FAILS + 1))
}
# check COND_CMD... -- label hint : pass/fail helper.
check() {
  local -a probe=()
  while (($#)) && [[ $1 != -- ]]; do
    probe+=("$1")
    shift
  done
  shift
  if "${probe[@]}" >/dev/null 2>&1; then check_pass "$1"; else check_fail "$1" "${2:-}"; fi
}

# ------------------------------------------------------- user toolchain ----

# user_path REL : absolute path under the target user's home (works before the user exists).
user_path() {
  local home
  home=$(target_home)
  printf '%s/%s' "${home:-/home/$AGBOX_USER}" "$1"
}

# user_has CMD : is CMD on the target user's PATH (incl. ~/.local/bin and mise shims)?
# shellcheck disable=SC2016 # $1 is expanded by the inner sh
user_has() { target_exists && as_user sh -c 'command -v "$1"' _ "$1" >/dev/null 2>&1; }

# mise_user ARGS... : run the target user's mise, non-interactively (dry-run aware).
mise_user() { run_user env MISE_YES=1 "$(user_path .local/bin/mise)" "$@"; }
