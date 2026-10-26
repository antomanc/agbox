# shellcheck shell=bash
# Docker Engine + Compose from Docker's apt repo. Databases & services run here, not on the host.

DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

docker::describe() { echo "Docker Engine + Compose (official repo), log rotation, user in docker group"; }
docker::enabled() { [[ $AGBOX_DOCKER == true ]]; }

docker::apply() {
  # Distro packages conflict with Docker's; remove them if present.
  local pkg conflicting=()
  for pkg in docker.io docker-compose docker-doc podman-docker; do
    if pkg_installed "$pkg"; then conflicting+=("$pkg"); fi
  done
  if ((${#conflicting[@]})); then
    log_info "removing conflicting packages: ${conflicting[*]}"
    apt_get remove -y "${conflicting[@]}"
  fi

  apt_add_repo docker "https://download.docker.com/linux/$OS_ID/gpg" asc "Types: deb
URIs: https://download.docker.com/linux/$OS_ID
Suites: $OS_CODENAME
Components: stable
Architectures: $OS_ARCH"
  apt_install "${DOCKER_PACKAGES[@]}"

  _docker_daemon_json

  _docker_user_group
  for_agent_users _docker_user_group
}

_docker_user_group() {
  if id -nG "$AGBOX_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    log_skip "$AGBOX_USER already in docker group"
  else
    run_root usermod -aG docker "$AGBOX_USER"
    add_next_step "Start a new session for '$AGBOX_USER' to pick up the docker group (restart its service when idle)"
  fi
}

_docker_user_check() {
  check as_user id -nG -- "$AGBOX_USER account accessible" "agbox setup --only docker"
  if id -nG "$AGBOX_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    check_pass "$AGBOX_USER in docker group"
  else
    check_fail "$AGBOX_USER not in docker group" "agbox setup --only docker"
  fi
}

# Merge agbox settings into daemon.json, preserving anything the user added.
_docker_daemon_json() {
  local file=/etc/docker/daemon.json current merged
  if ! has_cmd jq; then # only possible in a dry-run on a bare system
    log_info "would configure $file (log rotation${AGBOX_DOCKER_DATA_ROOT:+, data-root $AGBOX_DOCKER_DATA_ROOT})"
    return 0
  fi
  current=$(as_root cat "$file" 2>/dev/null) || current='{}'
  [[ -n $current ]] || current='{}'
  if ! merged=$(jq --arg root "$AGBOX_DOCKER_DATA_ROOT" '
      .["log-driver"] //= "json-file"
      | .["log-opts"] = ((.["log-opts"] // {}) + {"max-size": "10m", "max-file": "3"})
      | if $root != "" then .["data-root"] = $root else . end
    ' <<<"$current"); then
    log_warn "$file is not valid JSON; leaving it untouched"
    return 0
  fi
  local old_root
  old_root=$(jq -r '.["data-root"] // "/var/lib/docker"' <<<"$current")
  printf '%s\n' "$merged" | write_file root "$file" 0644
  [[ $FILE_CHANGED == true ]] || return 0

  if [[ -n $AGBOX_DOCKER_DATA_ROOT && $old_root != "$AGBOX_DOCKER_DATA_ROOT" ]]; then
    run_root mkdir -p "$AGBOX_DOCKER_DATA_ROOT"
    if as_root test -d "$old_root/image" && [[ -n $(as_root ls -A "$old_root/image" 2>/dev/null) ]]; then
      log_warn "existing images/volumes stay in $old_root (not migrated automatically)"
    fi
  fi
  if has_systemd; then run_root systemctl restart docker.service; fi
}

docker::check() {
  if ! has_cmd docker; then
    check_fail "docker installed" "agbox setup --only docker"
    return 0
  fi
  check as_root docker info -- "docker daemon running" "sudo systemctl start docker"
  check docker compose version -- "docker compose plugin"
  _docker_user_check
  for_agent_users _docker_user_check
  if [[ -n $AGBOX_DOCKER_DATA_ROOT ]]; then
    local dir
    dir=$(as_root docker info -f '{{.DockerRootDir}}' 2>/dev/null)
    if [[ $dir == "$AGBOX_DOCKER_DATA_ROOT" ]]; then check_pass "docker data in $dir"; else check_fail "docker data in ${dir:-?}, expected $AGBOX_DOCKER_DATA_ROOT" "sudo systemctl restart docker"; fi
  fi
}
