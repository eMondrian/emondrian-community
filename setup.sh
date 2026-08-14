#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ONTIME_SETUP="./clickhouse/scripts/setup-ontime.sh"

DOCKER=(docker)
DOCKER_INSTALLED_BY_SCRIPT=0

print_header() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

fail() {
  echo
  echo "ERROR: $1" >&2
  exit 1
}

run_as_root() {
  if (( EUID == 0 )); then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    fail "Root privileges are required, but sudo is not installed."
  fi
}

# ============================================================
# Host tools
# ============================================================

install_host_tools() {
  local need_curl=0
  local need_unzip=0

  command -v curl >/dev/null 2>&1 || need_curl=1
  command -v unzip >/dev/null 2>&1 || need_unzip=1

  if (( need_curl == 0 && need_unzip == 0 )); then
    return
  fi

  echo "Installing missing host tools..."

  if command -v apt-get >/dev/null 2>&1; then

    run_as_root apt-get update

    run_as_root env DEBIAN_FRONTEND=noninteractive \
      apt-get install -y ca-certificates curl unzip

  elif command -v dnf >/dev/null 2>&1; then

    run_as_root dnf install -y ca-certificates curl unzip

  elif command -v yum >/dev/null 2>&1; then

    run_as_root yum install -y ca-certificates curl unzip

  elif command -v zypper >/dev/null 2>&1; then

    run_as_root zypper --non-interactive install \
      ca-certificates curl unzip

  elif command -v pacman >/dev/null 2>&1; then

    run_as_root pacman -Sy --noconfirm \
      ca-certificates curl unzip

  elif command -v apk >/dev/null 2>&1; then

    run_as_root apk add \
      ca-certificates curl unzip

  else

    fail "curl or unzip is missing and no supported package manager was found."

  fi

  command -v curl >/dev/null 2>&1 \
    || fail "curl could not be installed."

  command -v unzip >/dev/null 2>&1 \
    || fail "unzip could not be installed."
}

# ============================================================
# Docker installation
# ============================================================

install_docker() {
  local installer

  print_header "Installing Docker Engine"

  [[ "$(uname -s)" == "Linux" ]] \
    || fail "Automatic Docker installation from this script is supported only on Linux."

  command -v curl >/dev/null 2>&1 \
    || fail "curl is required to install Docker."

  if (( EUID != 0 )) && ! command -v sudo >/dev/null 2>&1; then
    fail "Docker installation requires root privileges or sudo."
  fi

  if [[ -r /etc/os-release ]]; then
    . /etc/os-release

    echo "Detected OS: ${PRETTY_NAME:-${NAME:-Linux}}"
  else
    echo "Detected OS: Linux"
  fi

  echo "Architecture: $(uname -m)"
  echo
  echo "Downloading the official Docker installation script..."

  installer="$(mktemp)"

  if ! curl -fsSL https://get.docker.com -o "$installer"; then
    rm -f "$installer"
    fail "Failed to download the official Docker installation script."
  fi

  echo "Installing Docker..."

  if (( EUID == 0 )); then

    if ! sh "$installer"; then
      rm -f "$installer"
      fail "Docker installation failed."
    fi

  else

    if ! sudo sh "$installer"; then
      rm -f "$installer"
      fail "Docker installation failed."
    fi

  fi

  rm -f "$installer"

  command -v docker >/dev/null 2>&1 \
    || fail "Docker installation completed, but the docker command was not found."

  DOCKER_INSTALLED_BY_SCRIPT=1
}

start_docker_daemon() {
  if command -v systemctl >/dev/null 2>&1; then

    run_as_root systemctl enable --now docker >/dev/null 2>&1 || true

  elif command -v service >/dev/null 2>&1; then

    run_as_root service docker start >/dev/null 2>&1 || true

  fi
}

configure_docker_command() {
  if docker info >/dev/null 2>&1; then

    DOCKER=(docker)
    return

  fi

  start_docker_daemon

  if docker info >/dev/null 2>&1; then

    DOCKER=(docker)
    return

  fi

  if (( EUID != 0 )) \
    && command -v sudo >/dev/null 2>&1 \
    && sudo docker info >/dev/null 2>&1; then

    DOCKER=(sudo docker)
    return

  fi

  fail "Docker is installed, but the Docker daemon is unavailable or cannot be accessed."
}

check_docker_compose() {
  if "${DOCKER[@]}" compose version >/dev/null 2>&1; then
    return
  fi

  fail "Docker is installed, but the Docker Compose plugin is missing."
}

dc() {
  "${DOCKER[@]}" compose "$@"
}

docker_cli() {
  "${DOCKER[@]}" "$@"
}

# ============================================================
# Start
# ============================================================

print_header "eMondrian Community Quick Start"

# ============================================================
# Required tools
# ============================================================

echo "Checking required tools..."

install_host_tools

echo "curl:   OK"
echo "unzip:  OK"

# ============================================================
# Docker
# ============================================================

echo "Checking Docker..."

if ! command -v docker >/dev/null 2>&1; then

  echo "Docker: not found"

  install_docker

fi

configure_docker_command
check_docker_compose

echo "Docker: $("${DOCKER[@]}" --version)"
echo "Docker Compose: $("${DOCKER[@]}" compose version --short)"
echo "Docker daemon: OK"

# ============================================================
# Validate project
# ============================================================

print_header "Checking project files"

[[ -f "docker-compose.yml" ]] \
  || fail "docker-compose.yml was not found."

[[ -f "datasources.xml" ]] \
  || fail "datasources.xml was not found."

[[ -f "schema/OnTime.xml" ]] \
  || fail "schema/OnTime.xml was not found."

[[ -f "clickhouse/init-scripts/init-ontime.sh" ]] \
  || fail "clickhouse/init-scripts/init-ontime.sh was not found."

[[ -f "$ONTIME_SETUP" ]] \
  || fail "$ONTIME_SETUP was not found."

if ! dc config >/dev/null; then
  fail "docker-compose.yml is invalid."
fi

echo "Project files: OK"

# ============================================================
# Script permissions
# ============================================================

chmod +x "$ONTIME_SETUP"
chmod +x clickhouse/init-scripts/init-ontime.sh

# ============================================================
# Download OnTime sample
# ============================================================

print_header "Preparing OnTime sample dataset"

"$ONTIME_SETUP" --sample

# ============================================================
# Start containers
# ============================================================

print_header "Starting containers"

if ! dc up -d; then

  echo
  echo "Docker Compose failed."

  echo
  echo "ClickHouse logs:"
  dc logs --tail=50 clickhouse || true

  echo
  echo "OnTime initialization logs:"
  dc logs ontime-init || true

  echo
  echo "eMondrian logs:"
  dc logs --tail=50 eMondrian || true

  fail "Failed to start eMondrian Community."

fi

# ============================================================
# Verify ClickHouse
# ============================================================

print_header "Checking ClickHouse"

if ! dc exec -T clickhouse \
  clickhouse-client \
  --query="SELECT 1" \
  >/dev/null 2>&1; then

  dc logs --tail=50 clickhouse || true

  fail "ClickHouse is not available."

fi

echo "ClickHouse: OK"

# ============================================================
# Verify OnTime initialization
# ============================================================

echo "Checking OnTime initialization..."

ONTIME_INIT_CONTAINER="$(dc ps -aq ontime-init)"

if [[ -z "$ONTIME_INIT_CONTAINER" ]]; then
  fail "OnTime initialization container was not created."
fi

ONTIME_EXIT_CODE="$(
  docker_cli inspect \
    --format='{{.State.ExitCode}}' \
    "$ONTIME_INIT_CONTAINER"
)"

if [[ "$ONTIME_EXIT_CODE" != "0" ]]; then

  echo

  dc logs ontime-init || true

  fail "OnTime initialization failed with exit code $ONTIME_EXIT_CODE."

fi

echo "OnTime initialization: OK"

# ============================================================
# Verify OnTime data
# ============================================================

ONTIME_ROWS="$(
  dc exec -T clickhouse \
    clickhouse-client \
    --query="SELECT count() FROM ontime" |
  tr -d '[:space:]'
)"

if [[ -z "$ONTIME_ROWS" || "$ONTIME_ROWS" == "0" ]]; then
  fail "OnTime table does not contain any rows."
fi

echo "OnTime rows: $(printf "%'d" "$ONTIME_ROWS")"

# ============================================================
# Wait for eMondrian
# ============================================================

print_header "Waiting for eMondrian"

MAX_ATTEMPTS=120
ATTEMPT=0

while true; do

  EMONDRIAN_CONTAINER="$(dc ps -aq eMondrian)"

  if [[ -z "$EMONDRIAN_CONTAINER" ]]; then

    dc logs --tail=100 eMondrian || true

    fail "eMondrian container was not created."

  fi

  HEALTH="$(
    docker_cli inspect \
      --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
      "$EMONDRIAN_CONTAINER"
  )"

  if [[ "$HEALTH" == "healthy" ]]; then
    break
  fi

  if [[ "$HEALTH" == "unhealthy" \
     || "$HEALTH" == "exited" \
     || "$HEALTH" == "dead" ]]; then

    echo

    dc logs --tail=100 eMondrian || true

    fail "eMondrian failed to start. Status: $HEALTH."

  fi

  ATTEMPT=$((ATTEMPT + 1))

  if (( ATTEMPT >= MAX_ATTEMPTS )); then

    echo

    dc logs --tail=100 eMondrian || true

    fail "eMondrian did not become healthy after ${MAX_ATTEMPTS} seconds."

  fi

  sleep 1

done

echo "eMondrian: healthy"

# ============================================================
# Finished
# ============================================================

print_header "eMondrian Community is ready"

echo "Web interface:"
echo "  http://localhost"
echo

echo "XMLA endpoint:"
echo "  http://localhost/xmla"
echo

echo "Available catalogs:"
echo "  - FoodMart"
echo "  - OnTime"
echo

echo "OnTime rows:"
echo "  $(printf "%'d" "$ONTIME_ROWS")"
echo

echo "Containers:"
dc ps
echo

if (( DOCKER_INSTALLED_BY_SCRIPT == 1 )) \
  && [[ "${DOCKER[0]}" == "sudo" ]]; then

  echo "Docker was installed successfully."
  echo "Docker commands for this setup were executed through sudo."
  echo

fi
