# shellcheck shell=bash
# Module registry. A module is modules/<name>.sh defining four functions:
#   <name>::describe   one-line description
#   <name>::enabled    success if the current config wants it
#   <name>::apply      make the system match the config (idempotent, dry-run safe)
#   <name>::check      doctor checks via check_pass/check_warn/check_fail

# Execution order matters: later modules rely on earlier ones (e.g. agents needs mise).
MODULES=(system user ssh firewall tailscale docker mise agents devtools services snapshots)

load_modules() {
  local name file fn
  for name in "${MODULES[@]}"; do
    file="$AGBOX_ROOT/modules/$name.sh"
    [[ -r $file ]] || die "missing module file: $file"
    # shellcheck source=/dev/null
    source "$file"
    for fn in describe enabled apply check; do
      declare -F "$name::$fn" >/dev/null || die "module '$name' does not define $name::$fn"
    done
  done
}

is_module() {
  local m
  for m in "${MODULES[@]}"; do [[ $m == "$1" ]] && return 0; done
  return 1
}

# select_modules ONLY SKIP -> prints the modules to run, in order.
# ONLY/SKIP are comma or space separated lists of module names.
select_modules() {
  local only=" ${1//,/ } " skip=" ${2//,/ } " m
  for m in ${only} ${skip}; do is_module "$m" || die "unknown module '$m' (see: agbox modules)"; done
  for m in "${MODULES[@]}"; do
    [[ $only != "  " && $only != *" $m "* ]] && continue
    [[ $skip == *" $m "* ]] && continue
    printf '%s\n' "$m"
  done
}
