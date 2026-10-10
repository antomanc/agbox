# shellcheck shell=bash
# Configuration: defaults < profile < config file < environment < --set flags.
#
# The config file is parsed, never sourced: only known AGBOX_* keys are accepted,
# so a config file can't execute code.

# Every key, its default and a one-line description (used by `agbox config`).
# Format: KEY|default|description
AGBOX_SCHEMA=(
  "PROFILE|homelab|Preset: homelab (trusted LAN box) or vps (public server)"
  "USER||Target user (default: invoking sudo user, else current user, else 'dev' as root)"
  "HOSTNAME||Set the machine hostname (empty = keep)"
  "TIMEZONE||Set the timezone, e.g. Europe/Rome (empty = keep)"
  "UPGRADE|true|Run a full apt upgrade"
  "AUTO_UPDATES|true|Enable unattended security upgrades"
  "ZRAM|true|Compressed swap in RAM"
  "ZRAM_PERCENT|50|Size of zram swap as % of RAM"
  "PASSWORDLESS_SUDO|true|Let the target user (and its agents) sudo without a password"
  "SSH_HARDEN|auto|Disable SSH passwords/root login: true, false, auto (only if the user has SSH keys)"
  "FIREWALL|false|Enable ufw: deny incoming except SSH and Tailscale"
  "TAILSCALE|true|Install and join Tailscale"
  "TAILSCALE_AUTHKEY||Pre-auth key for unattended join (tskey-...)"
  "TAILSCALE_SSH|true|Enable Tailscale SSH"
  "TAILSCALE_HOSTNAME||Machine name on the tailnet (empty = hostname)"
  "DOCKER|true|Install Docker Engine + Compose from Docker's repo"
  "DOCKER_DATA_ROOT||Move Docker storage, e.g. /home/docker (empty = default)"
  "MISE_TOOLS|node@lts python@3.13 uv pnpm|Global toolchains installed with mise"
  "AGENTS|claude codex|Coding agents: claude codex opencode (space separated, empty = none)"
  "AGENT_MODE|yolo|yolo (no prompts, no sandbox: the machine is the sandbox) or sandboxed"
  "AGENT_INSTRUCTIONS|true|Write global AGENTS.md describing this machine to the agents"
  "PROJECTS_DIR|~/dev|Where projects live (~ = target user's home)"
  "GH|true|Install the GitHub CLI"
  "GIT_NAME||git user.name (empty = keep)"
  "GIT_EMAIL||git user.email (empty = keep)"
  "PLAYWRIGHT|true|Install headless Chromium + system deps for Playwright"
  "SERVICES||Always-on extras: t3code hermes (space separated)"
  "SNAPSHOTS|auto|Snapper timeline snapshots: auto (if / is btrfs), true, false"
)

# Profile presets: applied on top of defaults, below everything else.
profile_values() {
  case $1 in
    homelab) ;;
    vps) printf '%s\n' \
      FIREWALL=true \
      SSH_HARDEN=true \
      DOCKER_DATA_ROOT= ;;
    *) return 1 ;;
  esac
}

# Values that must never be printed.
AGBOX_SECRET_KEYS=(TAILSCALE_AUTHKEY)

schema_keys() {
  local entry
  for entry in "${AGBOX_SCHEMA[@]}"; do printf '%s\n' "${entry%%|*}"; done
}

is_known_key() {
  local entry
  for entry in "${AGBOX_SCHEMA[@]}"; do [[ ${entry%%|*} == "$1" ]] && return 0; done
  return 1
}

# parse_config_line LINE -> prints "KEY=VALUE" (KEY without AGBOX_ prefix), or nothing for
# blank/comment lines. Returns 2 on syntax error. Pure, unit-tested.
parse_config_line() {
  local line=$1 key value
  line=${line%$'\r'}
  # trim leading/trailing whitespace
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  [[ -z $line || $line == \#* ]] && return 0
  line=${line#export }
  [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || return 2
  key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
  key=${key#AGBOX_}
  if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then
    value=${BASH_REMATCH[1]}
  else
    # strip trailing inline comment on unquoted values
    value=${value%%[[:space:]]#*}
    value=${value%"${value##*[![:space:]]}"}
  fi
  printf '%s=%s\n' "${key^^}" "$value"
}

# _cfg_apply SOURCE KEY=VALUE...
_cfg_apply() {
  local source=$1 kv key
  shift
  for kv in "$@"; do
    key=${kv%%=*}
    if ! is_known_key "$key"; then
      log_warn "$source: unknown setting '$key' (ignored)"
      continue
    fi
    printf -v "AGBOX_$key" '%s' "${kv#*=}"
  done
}

_read_config_file() {
  local file=$1 line out n=0 rc content
  if [[ -r $file ]]; then
    content=$(<"$file")
  elif [[ -e $file ]]; then
    content=$(as_root cat -- "$file") || die "cannot read config file $file"
  else
    die "config file not found: $file"
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    rc=0
    out=$(parse_config_line "$line") || rc=$?
    ((rc == 2)) && die "$file:$n: expected KEY=VALUE, got: $line"
    if [[ -n $out ]]; then printf '%s\n' "$out"; fi
  done <<<"$content"
}

# load_config CONFIG_FILE SET_OVERRIDES...
# Resolves AGBOX_<KEY> globals for every schema key.
load_config() {
  local file=$1 entry key
  shift
  local -a from_file=() from_env=() from_flags=("$@")

  # 1. snapshot environment overrides (exported variables only) before assigning anything
  local exported
  exported=" $(compgen -e AGBOX_ | tr '\n' ' ') "
  while IFS= read -r key; do
    local var="AGBOX_$key"
    if [[ $exported == *" $var "* ]]; then from_env+=("$key=${!var}"); fi
  done < <(schema_keys)

  # 2. defaults
  for entry in "${AGBOX_SCHEMA[@]}"; do
    IFS='|' read -r key _ _ <<<"$entry"
    local default=${entry#*|}
    printf -v "AGBOX_$key" '%s' "${default%%|*}"
  done

  # 3. config file
  if [[ -n $file ]]; then
    local parsed
    parsed=$(_read_config_file "$file") || exit 1 # die in a subshell: propagate
    if [[ -n $parsed ]]; then mapfile -t from_file <<<"$parsed"; fi
  fi

  # 4. profile: last explicit value wins (flags > env > file > default)
  local profile=$AGBOX_PROFILE kv
  for kv in "${from_file[@]}" "${from_env[@]}" "${from_flags[@]}"; do
    [[ ${kv%%=*} == PROFILE ]] && profile=${kv#*=}
  done
  profile_values "$profile" >/dev/null || die "unknown profile '$profile' (choose: homelab, vps)"
  local -a from_profile=()
  mapfile -t from_profile < <(profile_values "$profile")
  _cfg_apply "profile $profile" "${from_profile[@]}"

  # 5. file, env, flags
  _cfg_apply "${file:-config}" "${from_file[@]}"
  _cfg_apply environment "${from_env[@]}"
  _cfg_apply --set "${from_flags[@]}"
  AGBOX_PROFILE=$profile

  _resolve_user
  validate_config
}

_resolve_user() {
  if [[ -z $AGBOX_USER ]]; then
    if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
      AGBOX_USER=$SUDO_USER
    elif ! is_root; then
      AGBOX_USER=$(id -un)
    else
      AGBOX_USER=dev
    fi
  fi
}

# Expand a leading ~ against the target user's home (works before the user exists).
expand_home() {
  local path=$1 home
  home=$(target_home)
  [[ -n $home ]] || home=/home/$AGBOX_USER
  [[ $path == "~" ]] && path=$home
  [[ $path == \~/* ]] && path=$home/${path#\~/}
  printf '%s' "$path"
}

_validate_bool() {
  local key=$1 var="AGBOX_$1"
  case ${!var,,} in
    true | yes | on | 1) printf -v "$var" true ;;
    false | no | off | 0) printf -v "$var" false ;;
    *) die "$key must be true or false (got '${!var}')" ;;
  esac
}

_validate_tristate() {
  local key=$1 var="AGBOX_$1"
  [[ ${!var,,} == auto ]] && { printf -v "$var" auto; return 0; }
  _validate_bool "$key"
}

_validate_words() {
  local key=$1 var="AGBOX_$1" allowed=" $2 " word
  for word in ${!var}; do
    [[ $allowed == *" $word "* ]] || die "$key: unknown value '$word' (choose from:$allowed)"
  done
}

# Pure validators, shared with the setup wizard.
is_valid_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
is_valid_hostname() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }

validate_config() {
  local key
  for key in UPGRADE AUTO_UPDATES ZRAM PASSWORDLESS_SUDO FIREWALL TAILSCALE TAILSCALE_SSH \
    DOCKER AGENT_INSTRUCTIONS GH PLAYWRIGHT; do
    _validate_bool "$key"
  done
  _validate_tristate SSH_HARDEN
  _validate_tristate SNAPSHOTS
  _validate_words AGENTS "claude codex opencode"
  _validate_words SERVICES "t3code hermes"
  case $AGBOX_AGENT_MODE in yolo | sandboxed) ;; *) die "AGENT_MODE must be yolo or sandboxed" ;; esac
  is_valid_username "$AGBOX_USER" || die "invalid USER '$AGBOX_USER'"
  [[ $AGBOX_USER != root ]] || die "USER must not be root: agents refuse to run unattended as root"
  if ! [[ $AGBOX_ZRAM_PERCENT =~ ^[0-9]+$ ]] || ((AGBOX_ZRAM_PERCENT < 10 || AGBOX_ZRAM_PERCENT > 150)); then
    die "ZRAM_PERCENT must be a number between 10 and 150"
  fi
  [[ -z $AGBOX_HOSTNAME ]] || is_valid_hostname "$AGBOX_HOSTNAME" ||
    die "invalid HOSTNAME '$AGBOX_HOSTNAME' (lowercase letters, digits and '-')"
  [[ -z $AGBOX_DOCKER_DATA_ROOT || $AGBOX_DOCKER_DATA_ROOT == /* ]] ||
    die "DOCKER_DATA_ROOT must be an absolute path"
  if [[ $AGBOX_SERVICES == *t3code* || $AGBOX_AGENTS == *codex* || $AGBOX_AGENTS == *opencode* ]] &&
    [[ " $AGBOX_MISE_TOOLS " != *" node@"* && " $AGBOX_MISE_TOOLS " != *" node "* ]]; then
    die "MISE_TOOLS must include node when installing codex, opencode or t3code"
  fi
  return 0
}

# Print the effective configuration (secrets masked).
print_config() {
  local entry key desc var value secret
  for entry in "${AGBOX_SCHEMA[@]}"; do
    IFS='|' read -r key _ desc <<<"$entry"
    var="AGBOX_$key" value=${!var}
    for secret in "${AGBOX_SECRET_KEYS[@]}"; do
      [[ $key == "$secret" && -n $value ]] && value='********'
    done
    # Quoted so the output is valid config syntax (parse_config_line strips the quotes).
    if [[ $value == *'"'* ]]; then
      printf "%s# %s%s\nAGBOX_%s='%s'\n" "$_C_DIM" "$desc" "$_C_RESET" "$key" "$value"
    else
      printf '%s# %s%s\nAGBOX_%s="%s"\n' "$_C_DIM" "$desc" "$_C_RESET" "$key" "$value"
    fi
  done
}
