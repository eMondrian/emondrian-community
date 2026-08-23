#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DOCKER=(docker)

# ============================================================
# Helpers
# ============================================================

header() {
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
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
        return
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo "$@"
        return
    fi

    fail "Administrator/root privileges are required, but sudo is not available."
}

# ============================================================
# Host tools
# ============================================================

install_host_tools() {
    header "Checking host tools"

    local missing=0

    for command_name in curl unzip; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            echo "$command_name: not found"
            missing=1
        else
            echo "$command_name: OK"
        fi
    done

    if [ "$missing" -eq 0 ]; then
        echo "Host tools: OK"
        return
    fi

    echo
    echo "Installing required host tools..."

    if command -v apt-get >/dev/null 2>&1; then
        run_as_root apt-get update
        run_as_root apt-get install -y \
            curl \
            unzip \
            ca-certificates

    elif command -v dnf >/dev/null 2>&1; then
        run_as_root dnf install -y \
            curl \
            unzip \
            ca-certificates

    elif command -v yum >/dev/null 2>&1; then
        run_as_root yum install -y \
            curl \
            unzip \
            ca-certificates

    elif command -v zypper >/dev/null 2>&1; then
        run_as_root zypper --non-interactive install \
            curl \
            unzip \
            ca-certificates

    elif command -v pacman >/dev/null 2>&1; then
        run_as_root pacman -Sy --noconfirm \
            curl \
            unzip \
            ca-certificates

    elif command -v apk >/dev/null 2>&1; then
        run_as_root apk add \
            curl \
            unzip \
            ca-certificates

    else
        fail "Could not detect a supported package manager. Install curl, unzip and ca-certificates manually."
    fi

    for command_name in curl unzip; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            fail "$command_name is still unavailable after installation."
        fi
    done

    echo "Host tools installed successfully."
}

# ============================================================
# Docker
# ============================================================

install_docker() {
    header "Installing Docker"

    local installer

    installer="$(mktemp)"

    echo "Downloading the official Docker installation script..."

    if ! curl -fsSL https://get.docker.com -o "$installer"; then
        rm -f "$installer"
        fail "Failed to download the Docker installation script."
    fi

    echo "Installing Docker..."

    if [ "$(id -u)" -eq 0 ]; then
        if ! sh "$installer"; then
            rm -f "$installer"
            fail "Docker installation failed."
        fi
    else
        if ! command -v sudo >/dev/null 2>&1; then
            rm -f "$installer"
            fail "Docker installation requires administrator/root privileges."
        fi

        if ! sudo sh "$installer"; then
            rm -f "$installer"
            fail "Docker installation failed."
        fi
    fi

    rm -f "$installer"

    if ! command -v docker >/dev/null 2>&1; then
        fail "Docker installation completed, but the docker command was not found."
    fi

    echo "Docker installed successfully."
}

start_docker_daemon() {
    if docker info >/dev/null 2>&1; then
        return
    fi

    echo "Starting Docker daemon..."

    if command -v systemctl >/dev/null 2>&1; then
        run_as_root systemctl start docker || true
    elif command -v service >/dev/null 2>&1; then
        run_as_root service docker start || true
    fi

    local attempt

    for attempt in $(seq 1 30); do
        if docker info >/dev/null 2>&1; then
            return
        fi

        if command -v sudo >/dev/null 2>&1; then
            if sudo docker info >/dev/null 2>&1; then
                return
            fi
        fi

        sleep 1
    done
}

configure_docker_command() {
    if docker info >/dev/null 2>&1; then
        DOCKER=(docker)
        return
    fi

    if command -v sudo >/dev/null 2>&1; then
        if sudo docker info >/dev/null 2>&1; then
            DOCKER=(sudo docker)
            return
        fi
    fi

    if [ -S /var/run/docker.sock ]; then
        fail "Docker is installed and running, but this user is not allowed to talk to it.
If Docker was just installed, add yourself to the docker group and start a new session:

    sudo usermod -aG docker \$USER
    newgrp docker

Then run ./setup.sh again."
    fi

    fail "The Docker daemon is not available.
Start it and run ./setup.sh again, for example:

    sudo systemctl start docker"
}

ensure_docker() {
    header "Checking Docker"

    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker: not found"
        install_docker
    else
        echo "Docker: found"
    fi

    start_docker_daemon
    configure_docker_command

    echo "Docker daemon: OK"

    if ! "${DOCKER[@]}" compose version >/dev/null 2>&1; then
        fail "Docker Compose plugin is not available."
    fi

    echo "Docker: $("${DOCKER[@]}" --version)"
    echo "Docker Compose: $("${DOCKER[@]}" compose version --short)"
}

# ============================================================
# Start
# ============================================================

header "eMondrian Community Quick Start"

echo "Operating system: $(uname -s)"
echo "Architecture: $(uname -m)"

# ============================================================
# Host dependencies
# ============================================================

install_host_tools

# ============================================================
# Validate project files
# ============================================================

header "Checking project files"

REQUIRED_FILES=(
    ".env.example"
    "docker-compose.yml"
    "datasources.xml"
    "schema/Foodmart.xml"
    "schema/OnTime.xml"
    "clickhouse/init-scripts/init-ontime.sh"
    "clickhouse/scripts/setup-ontime.sh"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        fail "$file was not found."
    fi
done

echo "Project files: OK"

# ============================================================
# Prepare environment file
# ============================================================

if [ ! -f ".env" ]; then
    echo "Creating .env from .env.example..."

    cp .env.example .env

    echo ".env: created"
else
    echo ".env: already exists"
fi

# ============================================================
# Make scripts executable
# ============================================================

chmod +x \
    clickhouse/scripts/setup-ontime.sh \
    clickhouse/init-scripts/init-ontime.sh

# ============================================================
# Docker
# ============================================================

ensure_docker

# ============================================================
# Validate Docker Compose
# ============================================================

header "Checking Docker Compose configuration"

if ! "${DOCKER[@]}" compose config >/dev/null; then
    fail "docker-compose.yml is invalid."
fi

echo "Docker Compose configuration: OK"

# ============================================================
# Download OnTime sample
# ============================================================

header "Preparing OnTime sample dataset"

if ! ./clickhouse/scripts/setup-ontime.sh --sample; then
    fail "Failed to prepare the OnTime sample dataset."
fi

# ============================================================
# Start containers
# ============================================================

header "Starting containers"

# Create the bind-mounted log directory first. Left to Docker it is created as
# root, and then the clone cannot be deleted without sudo.
mkdir -p logs


if ! "${DOCKER[@]}" compose up -d; then
    echo
    echo "Docker Compose failed."

    echo
    echo "ClickHouse logs:"
    "${DOCKER[@]}" compose logs --tail=50 clickhouse || true

    echo
    echo "OnTime initialization logs:"
    "${DOCKER[@]}" compose logs ontime-init || true

    echo
    echo "eMondrian logs:"
    "${DOCKER[@]}" compose logs --tail=50 eMondrian || true

    fail "Failed to start eMondrian Community."
fi

# ============================================================
# Verify ClickHouse
# ============================================================

header "Checking ClickHouse"

if ! "${DOCKER[@]}" compose exec -T clickhouse \
    clickhouse-client \
    --query="SELECT 1" \
    >/dev/null; then

    "${DOCKER[@]}" compose logs --tail=50 clickhouse || true

    fail "ClickHouse is not available."
fi

echo "ClickHouse: OK"

# ============================================================
# Verify OnTime initialization
# ============================================================

echo "Checking OnTime initialization..."

ONTIME_INIT_CONTAINER="$(
    "${DOCKER[@]}" compose ps -aq ontime-init
)"

if [ -z "$ONTIME_INIT_CONTAINER" ]; then
    fail "OnTime initialization container was not created."
fi

ONTIME_EXIT_CODE="$(
    "${DOCKER[@]}" inspect \
        --format='{{.State.ExitCode}}' \
        "$ONTIME_INIT_CONTAINER"
)"

if [ "$ONTIME_EXIT_CODE" != "0" ]; then
    echo
    "${DOCKER[@]}" compose logs ontime-init || true

    fail "OnTime initialization failed with exit code $ONTIME_EXIT_CODE."
fi

echo "OnTime initialization: OK"

# ============================================================
# Verify OnTime data
# ============================================================

ONTIME_ROWS="$(
    "${DOCKER[@]}" compose exec -T clickhouse \
        clickhouse-client \
        --query="SELECT count() FROM ontime" |
        tr -d '[:space:]'
)"

if [ -z "$ONTIME_ROWS" ]; then
    fail "Could not read the OnTime row count."
fi

if ! [[ "$ONTIME_ROWS" =~ ^[0-9]+$ ]]; then
    fail "Unexpected OnTime row count: $ONTIME_ROWS"
fi

if [ "$ONTIME_ROWS" -eq 0 ]; then
    fail "OnTime table does not contain any rows."
fi

echo "OnTime rows: $ONTIME_ROWS"

# ============================================================
# Wait for eMondrian
# ============================================================

header "Waiting for eMondrian"

MAX_ATTEMPTS=120

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    EMONDRIAN_CONTAINER="$(
        "${DOCKER[@]}" compose ps -q eMondrian
    )"

    if [ -z "$EMONDRIAN_CONTAINER" ]; then
        "${DOCKER[@]}" compose logs --tail=100 eMondrian || true
        fail "eMondrian container was not created."
    fi

    HEALTH="$(
        "${DOCKER[@]}" inspect \
            --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
            "$EMONDRIAN_CONTAINER"
    )"

    if [ "$HEALTH" = "healthy" ]; then
        break
    fi

    if \
        [ "$HEALTH" = "unhealthy" ] ||
        [ "$HEALTH" = "exited" ] ||
        [ "$HEALTH" = "dead" ]; then

        echo
        "${DOCKER[@]}" compose logs --tail=100 eMondrian || true

        fail "eMondrian failed to start. Status: $HEALTH."
    fi

    if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
        echo
        "${DOCKER[@]}" compose logs --tail=100 eMondrian || true

        fail "eMondrian did not become healthy after $MAX_ATTEMPTS seconds."
    fi

    sleep 1
done

echo "eMondrian: healthy"

# ============================================================
# Wait for the web front door
# ============================================================

header "Waiting for the web interface"

# Override if the front door was remapped to another port in docker-compose.yml.
WEB_URL="${EMONDRIAN_URL:-http://localhost/}"

MAX_ATTEMPTS=60

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    if curl -fs -o /dev/null "$WEB_URL"; then
        break
    fi

    if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
        echo
        "${DOCKER[@]}" compose logs --tail=50 emondrian_entry || true

        echo
        echo "The engine is running, but $WEB_URL is not responding."
        echo "Common causes: the web container failed to start (see its log above),"
        echo "or another program is already using port 80."

        fail "The web interface did not come up after $MAX_ATTEMPTS seconds."
    fi

    sleep 1
done

echo "Web interface: OK"

# ============================================================
# Finished
# ============================================================

header "eMondrian Community is ready"

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
echo "  $ONTIME_ROWS"
echo

echo "Containers:"
"${DOCKER[@]}" compose ps

echo