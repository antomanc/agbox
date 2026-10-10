# shellcheck shell=bash
# Host detection. Populates OS_* globals once; read-only, safe in dry-run.
# shellcheck disable=SC2034 # OS_* globals are read by the modules

OS_ID='' OS_VERSION_ID='' OS_CODENAME='' OS_PRETTY='' OS_ARCH=''

# Supported "id:version" pairs. Others run with a warning.
SUPPORTED_OS=("debian:12" "debian:13" "ubuntu:24.04" "ubuntu:26.04")

detect_os() {
  local file=${AGBOX_OS_RELEASE:-/etc/os-release}
  [[ -r $file ]] || die "cannot read $file: agbox supports Debian and Ubuntu only"
  # Parse instead of sourcing to keep the global namespace clean.
  local line key value
  while IFS= read -r line; do
    [[ $line =~ ^([A-Z_]+)=(.*)$ ]] || continue
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    value=${value#\"} value=${value%\"}
    case $key in
      ID) OS_ID=$value ;;
      VERSION_ID) OS_VERSION_ID=$value ;;
      VERSION_CODENAME) OS_CODENAME=$value ;;
      PRETTY_NAME) OS_PRETTY=$value ;;
    esac
  done <"$file"
  OS_ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
  case $OS_ID in
    debian | ubuntu) ;;
    *) die "unsupported distribution '$OS_ID': agbox supports Debian and Ubuntu" ;;
  esac
  [[ -n $OS_CODENAME ]] || die "could not determine the release codename from $file"
}

os_is_supported() {
  local pair
  for pair in "${SUPPORTED_OS[@]}"; do [[ $pair == "$OS_ID:$OS_VERSION_ID" ]] && return 0; done
  return 1
}

root_fstype() { findmnt -no FSTYPE / 2>/dev/null || true; }
mem_total_gb() { awk '/^MemTotal:/ { printf "%d", ($2 + 524288) / 1048576 }' /proc/meminfo 2>/dev/null; }
cpu_model() { awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo 2>/dev/null; }
cpu_count() { nproc 2>/dev/null || echo 1; }

# Is systemd the running init? (false in plain containers)
has_systemd() { [[ -d /run/systemd/system ]]; }

# Does AppArmor restrict unprivileged user namespaces (Ubuntu 24.04+)?
apparmor_restricts_userns() {
  [[ $(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null) == 1 ]]
}
