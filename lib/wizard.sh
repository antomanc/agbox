# shellcheck shell=bash
# The "customize" step of `agbox setup`: a few questions about the settings that differ from
# machine to machine. Answers become KEY=VALUE overrides, exactly like --set, so validation,
# --dry-run and the saved config all work unchanged. Nothing here changes the system.

WIZ_ANSWER=''
WIZARD_SETS=()

# ask_apply : the question after the plan. Sets WIZ_ANSWER to yes, no or customize.
# Non-interactive runs answer yes.
ask_apply() {
  WIZ_ANSWER=yes
  is_interactive || return 0
  local reply
  while :; do
    tty_printf '\nApply? [Y]es / [n]o / [c]ustomize: '
    if ! tty_read reply; then
      tty_printf '\n'
      WIZ_ANSWER=no
      return 0
    fi
    case ${reply,,} in
      '' | y | yes) WIZ_ANSWER=yes ;;
      n | no) WIZ_ANSWER=no ;;
      c | customize) WIZ_ANSWER=customize ;;
      *) continue ;;
    esac
    return 0
  done
}

# run_wizard : ask, then leave the overrides in WIZARD_SETS (KEY=VALUE, only real changes).
run_wizard() {
  WIZARD_SETS=()
  tty_printf '\n%sCustomize%s  %s(Enter keeps the current value, - clears a text one; Ctrl-C quits, nothing has changed yet)%s\n' \
    "$_C_BOLD" "$_C_RESET" "$_C_DIM" "$_C_RESET"

  _ask_choice "Profile" PROFILE \
    "homelab|machine on a network you trust" \
    "vps|public server: firewall on, key-only SSH"
  _ask_words "Coding agents" AGENTS \
    "claude|Claude Code" \
    "codex|OpenAI Codex CLI" \
    "opencode|opencode"
  if [[ -n $(_wizard_value AGENTS) ]]; then
    _ask_choice "Agent permissions" AGENT_MODE \
      "yolo|no prompts, no sandbox: the machine is the sandbox" \
      "sandboxed|keep each agent's own prompts and sandbox"
  fi
  _ask_words "Always-on services" SERVICES \
    "t3code|web UI for coding agents, on your tailnet" \
    "hermes|Nous Research's Hermes Agent"
  _ask_components
  _ask_text "User the agents run as" USER '' _wizard_valid_user \
    "lowercase letters, digits, '-' and '_'; not root"
  _ask_text "Hostname" HOSTNAME "keep $(uname -n)" is_valid_hostname \
    "lowercase letters, digits and '-'"
  _ask_text "Timezone, e.g. Europe/Rome" TIMEZONE "keep $(_current_timezone)" _wizard_valid_timezone \
    "unknown timezone (see: timedatectl list-timezones)"
  _ask_text "git user.name" GIT_NAME "keep current"
  _ask_text "git user.email" GIT_EMAIL "keep current" _wizard_valid_email "expected name@domain"

  if ((${#WIZARD_SETS[@]} == 0)); then
    tty_printf '\nNo changes.\n'
    return 0
  fi
  local kv
  tty_printf '\n%sChanges:%s\n' "$_C_BOLD" "$_C_RESET"
  for kv in "${WIZARD_SETS[@]}"; do tty_printf '  %s="%s"\n' "${kv%%=*}" "${kv#*=}"; done
}

# ----------------------------------------------------------- pure helpers ----

# wizard_pick INPUT OPTION... -> the option INPUT names, by number or by name. Fails if none.
wizard_pick() {
  local input=${1,,} opt
  shift
  if [[ $input =~ ^[1-9][0-9]*$ ]] && ((input <= $#)); then
    printf '%s' "${!input}"
    return 0
  fi
  for opt in "$@"; do
    if [[ $opt == "$input" ]]; then
      printf '%s' "$opt"
      return 0
    fi
  done
  return 1
}

# wizard_toggle "CURRENT WORDS" INPUT OPTION... -> CURRENT with each option named in INPUT
# (numbers or names, separated by spaces or commas) switched on or off, in OPTION order.
# Fails without output if INPUT names an unknown option.
wizard_toggle() {
  local current=" $1 " opt out='' token
  local -a tokens=()
  read -ra tokens <<<"${2//,/ }"
  shift 2
  for token in "${tokens[@]}"; do
    opt=$(wizard_pick "$token" "$@") || return 1
    if [[ $current == *" $opt "* ]]; then current=${current/" $opt "/ }; else current+="$opt "; fi
  done
  for opt in "$@"; do
    if [[ $current == *" $opt "* ]]; then out+="$opt "; fi
  done
  printf '%s' "${out% }"
}

_wizard_valid_user() { is_valid_username "$1" && [[ $1 != root ]]; }
_wizard_valid_email() { [[ $1 =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]]; }
_wizard_valid_timezone() {
  [[ $1 =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && -f /usr/share/zoneinfo/$1 ]]
}

# --------------------------------------------------------------- prompts ----

# _wizard_set KEY VALUE : record an override, unless it's what the config already says.
_wizard_set() {
  local var="AGBOX_$1"
  if [[ $2 != "${!var}" ]]; then WIZARD_SETS+=("$1=$2"); fi
}

# _wizard_value KEY -> the answer given so far, else the current value.
_wizard_value() {
  local var="AGBOX_$1" value i
  value=${!var}
  for ((i = 0; i < ${#WIZARD_SETS[@]}; i++)); do
    if [[ ${WIZARD_SETS[i]%%=*} == "$1" ]]; then value=${WIZARD_SETS[i]#*=}; fi
  done
  printf '%s' "$value"
}

_wizard_eof() {
  tty_printf '\n'
  die "aborted: no answer"
}

_wizard_warn() { tty_printf '  %s! %s%s\n' "$_C_YELLOW" "$1" "$_C_RESET"; }

_current_timezone() {
  local tz
  tz=$(timedatectl show -p Timezone --value 2>/dev/null) || tz=''
  if [[ -z $tz && -r /etc/timezone ]]; then tz=$(</etc/timezone); fi
  printf '%s' "${tz:-unset}"
}

# _ask_choice TITLE KEY VALUE|HINT... : pick exactly one value.
_ask_choice() {
  local title=$1 key=$2 var="AGBOX_$2" entry reply value i=1 default=1
  shift 2
  local -a values=()
  tty_printf '\n%s%s%s\n' "$_C_BOLD" "$title" "$_C_RESET"
  for entry in "$@"; do
    values+=("${entry%%|*}")
    if [[ ${entry%%|*} == "${!var}" ]]; then default=$i; fi
    tty_printf '  %d) %-10s %s%s%s\n' "$i" "${entry%%|*}" "$_C_DIM" "${entry#*|}" "$_C_RESET"
    i=$((i + 1))
  done
  while :; do
    tty_printf '  choice [%d]: ' "$default"
    tty_read reply || _wizard_eof
    if [[ -z ${reply// /} ]]; then reply=$default; fi
    if value=$(wizard_pick "${reply// /}" "${values[@]}"); then break; fi
    _wizard_warn "choose 1-${#values[@]}"
  done
  _wizard_set "$key" "$value"
}

# _ask_multi TITLE "CURRENT WORDS" VALUE|HINT... : toggle any number of values.
# Sets WIZ_ANSWER to the chosen values, in option order.
_ask_multi() {
  local title=$1 selected=$2 entry reply next mark i
  shift 2
  local -a values=()
  for entry in "$@"; do values+=("${entry%%|*}"); done
  selected=$(wizard_toggle "$selected" '' "${values[@]}") # drop unknowns, normalize order
  tty_printf '\n%s%s%s  %s(type numbers to toggle, Enter to accept)%s\n' \
    "$_C_BOLD" "$title" "$_C_RESET" "$_C_DIM" "$_C_RESET"
  while :; do
    i=1
    for entry in "$@"; do
      mark=' '
      if [[ " $selected " == *" ${entry%%|*} "* ]]; then mark=x; fi
      tty_printf '  %d [%s] %-10s %s%s%s\n' "$i" "$mark" "${entry%%|*}" "$_C_DIM" "${entry#*|}" "$_C_RESET"
      i=$((i + 1))
    done
    tty_printf '  toggle: '
    tty_read reply || _wizard_eof
    if [[ -z ${reply// /} ]]; then break; fi
    if next=$(wizard_toggle "$selected" "$reply" "${values[@]}"); then
      selected=$next
    else
      _wizard_warn "choose from 1-${#values[@]}"
    fi
  done
  WIZ_ANSWER=$selected
}

# _ask_words TITLE KEY VALUE|HINT... : a space-separated list setting (AGENTS, SERVICES).
_ask_words() {
  local title=$1 key=$2 var="AGBOX_$2" entry current
  shift 2
  local -a values=()
  for entry in "$@"; do values+=("${entry%%|*}"); done
  current=$(wizard_toggle "${!var}" '' "${values[@]}")
  _ask_multi "$title" "$current" "$@"
  if [[ $WIZ_ANSWER != "$current" ]]; then WIZARD_SETS+=("$key=$WIZ_ANSWER"); fi
}

# Optional components, each an on/off setting.
_ask_components() {
  local -a keys=(DOCKER TAILSCALE PLAYWRIGHT GH)
  local key var current=''
  for key in "${keys[@]}"; do
    var="AGBOX_$key"
    if [[ ${!var} == true ]]; then current+="${key,,} "; fi
  done
  _ask_multi "Components" "$current" \
    "docker|Docker Engine + Compose, for databases and services" \
    "tailscale|Tailscale + Tailscale SSH: reach the machine from anywhere" \
    "playwright|headless Chromium for web testing" \
    "gh|GitHub CLI"
  for key in "${keys[@]}"; do
    if [[ " $WIZ_ANSWER " == *" ${key,,} "* ]]; then _wizard_set "$key" true; else _wizard_set "$key" false; fi
  done
}

# _ask_text TITLE KEY EMPTY_LABEL [VALIDATOR ERROR] : free text.
# Enter keeps the current value, '-' clears it.
_ask_text() {
  local title=$1 key=$2 empty_label=$3 validator=${4:-} error=${5:-} var="AGBOX_$2" reply
  tty_printf '\n'
  while :; do
    tty_printf '%s%s%s [%s]: ' "$_C_BOLD" "$title" "$_C_RESET" "${!var:-$empty_label}"
    tty_read reply || _wizard_eof
    reply=${reply#"${reply%%[![:space:]]*}"}
    reply=${reply%"${reply##*[![:space:]]}"}
    if [[ -z $reply ]]; then return 0; fi
    if [[ $reply == - ]]; then reply=''; fi
    if [[ -z $reply || -z $validator ]] || "$validator" "$reply"; then break; fi
    _wizard_warn "$error"
  done
  _wizard_set "$key" "$reply"
}
