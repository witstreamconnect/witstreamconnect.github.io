#!/usr/bin/env bash
# WITStream Connect installer.
#
# Handles login (only if the image needs it), pull, and run in one
# sequence: a small installer script the customer runs once, not
# several remembered manual commands.
#
# Safe to re-run: this is also the exact command a customer-wide update
# notice tells a deployment to run to redeploy onto a newer version
# (see WITStreamConnect.Licensing's UpdateNotice / the Licence Server's
# admin API) , running it again stops the old container, pulls the new
# image, and starts it back up with the same config file untouched.
#
# Usage:
#   ./install.sh              install/update to the latest version
#   ./install.sh v1.4.2       install/update to a specific version

set -euo pipefail

REGISTRY="ghcr.io"
IMAGE="${REGISTRY}/witstreamconnect/witstream-connect"
CONTAINER_NAME="witstream-connect"
CONFIG_FILE="witstream-config.json"
PORT="${WITSTREAM_PORT:-3000}"
VERSION="${1:-latest}"
LICENCE_SERVER_URL="${WITSTREAM_LICENCE_SERVER_URL:-https://licence.witstreamconnect.com}"

info()  { printf '%s\n' "$1"; }
error() { printf 'Error: %s\n' "$1" >&2; }

# Tiny, dependency-free JSON field reader for the Licence Server's own
# small, fixed response shapes , deliberately not requiring jq, since a
# customer's machine having it installed is not a safe assumption.
json_field() {
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
}

info "WITStream Connect® installer"
info "----------------------------"

# 1. Docker must be installed and running. Both are real, common failure
#    points worth a clear message rather than a raw docker error.
if ! command -v docker >/dev/null 2>&1; then
  error "Docker isn't installed. Install Docker Desktop (macOS/Windows) or Docker Engine (Linux), then run this again: https://docs.docker.com/get-docker/"
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  error "Docker is installed but doesn't seem to be running. Start Docker Desktop (or the Docker service on Linux) and try again."
  exit 1
fi

# 2. The product image is private, kept that way deliberately to protect
#    the real product logic, not left private by accident. The Licence
#    Server itself brokers real pull access using
#    the licence key as the credential, so nobody ever needs a separate
#    GitHub account just to install this. Ask for the licence key once,
#    up front, and reuse it below for the config file too.
if [ -f "$CONFIG_FILE" ]; then
  LICENCE_KEY=$(sed -n 's/.*"licenceKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -1)
fi
if [ -z "${LICENCE_KEY:-}" ]; then
  # Hidden as it is typed or pasted, then confirmed by its last four
  # characters so the customer still knows the paste worked. Read from
  # the terminal itself: under "curl ... | bash" the script's own text
  # arrives on standard input, and would be taken as the key.
  read -r -s -p "Licence key (from your WITStream Connect® account, hidden as you paste it): " LICENCE_KEY </dev/tty
  printf '\n'
  info "Licence key received (ending ${LICENCE_KEY: -4})."
fi

info "Requesting registry access..."
IMAGE_ACCESS_RESPONSE=$(curl -sS -X POST "${LICENCE_SERVER_URL}/image-access" \
  -H "Content-Type: application/json" \
  -d "{\"licenceKey\":\"${LICENCE_KEY}\"}") || {
  error "Could not reach the Licence Server at ${LICENCE_SERVER_URL}. Check your connection and try again."
  exit 1
}

REGISTRY_USER=$(json_field "$IMAGE_ACCESS_RESPONSE" "username")
REGISTRY_TOKEN=$(json_field "$IMAGE_ACCESS_RESPONSE" "token")

if [ -z "$REGISTRY_TOKEN" ]; then
  error "That licence key wasn't accepted. Check it's correct, active, and not expired."
  exit 1
fi

echo "$REGISTRY_TOKEN" | docker login "$REGISTRY" -u "$REGISTRY_USER" --password-stdin

info "Pulling ${IMAGE}:${VERSION}..."
docker pull "${IMAGE}:${VERSION}"

# 3. First run only: create a starter config file. Never overwrites an
#    existing one on a re-run, so real connections and settings survive
#    every update.
if [ ! -f "$CONFIG_FILE" ]; then
  info ""
  info "No ${CONFIG_FILE} found in this folder. Setting one up now."
  API_KEY=$(env LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 32 || true)
  if [ -z "$API_KEY" ]; then API_KEY=$(od -An -tx1 -N24 /dev/urandom 2>/dev/null | tr -d ' \n' || true); fi
  if [ -z "$API_KEY" ]; then
    error "Couldn't generate a random API key on this machine. Please contact support."
    exit 1
  fi

  cat > "$CONFIG_FILE" <<EOF
{
  "apiKey": "${API_KEY}",
  "licence": {
    "licenceKey": "${LICENCE_KEY}",
    "licenceServerUrl": "${LICENCE_SERVER_URL}"
  },
  "connections": []
}
EOF
  info "Created ${CONFIG_FILE} with a generated API key. Add your rig connections through the configuration screen once it's running."
  info ""
  info "Your dashboard API key (the dashboard asks for it the first time you open it):"
  info "  ${API_KEY}"
  info "It is also saved as apiKey in ${CONFIG_FILE}."
fi

# 4. Idempotent (re)start: stop and remove any previous container of
#    the same name first, so re-running this script is exactly the
#    redeploy command an update notice tells a customer to run.
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  info "Stopping the existing container..."
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# 5. A real, persistent data folder on the host, mounted at /app/data
#    inside the container. A genuine, confirmed gap (18 September 2026,
#    the full ecosystem audit): only the config file was ever mounted,
#    so anything a customer configured to write inside the container
#    (CSV or LAS output, an OPC-UA self-signed certificate) lived only
#    in that one container's own writable layer and was silently lost
#    on every redeploy, a fresh certificate and an empty output folder
#    every update, never disclosed anywhere a customer would see it
#    before now. The configuration screen's own defaults for these
#    already point inside this same folder, so a customer who never
#    touches those settings gets real persistence automatically; a
#    customer who sets a custom path should keep it under here too.
DATA_DIR="witstream-data"
mkdir -p "$DATA_DIR"

# 6. Networking. Every output (WITSML, WITS0, ETP, OPC-UA, Modbus)
#    listens on whatever port the customer sets on the configuration
#    screen, so the container shares the host's own network: each of
#    those ports is reachable from other machines as soon as it is
#    saved and applied, with nothing to re-run here. Docker Desktop
#    (macOS/Windows) only supports host networking once its own
#    "Enable host networking" setting is on; if the dashboard doesn't
#    answer in host mode there, the container is started again with
#    just the dashboard port published, and the output ports explained.
start_container() {
  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    "$@" \
    -e "ASPNETCORE_URLS=http://+:${PORT}" \
    -v "$(pwd)/${CONFIG_FILE}:/app/witstream-config.json" \
    -v "$(pwd)/${DATA_DIR}:/app/data" \
    "${IMAGE}:${VERSION}" >/dev/null
}

# 7. A health check, not just a declared "it's running" message: the
#    container must still be running (catches an immediate crash on
#    startup) and the dashboard must answer over HTTP (catches the app
#    failing to bind), retried for up to 30 seconds, a generous window
#    for a cold start, before pointing at the container's own logs.
wait_until_healthy() {
  HEALTHY=""
  for i in $(seq 1 30); do
    if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
      return
    fi
    if curl -sS -o /dev/null -w '%{http_code}' "http://localhost:${PORT}" 2>/dev/null | grep -qE '^[23]'; then
      HEALTHY="1"
      return
    fi
    sleep 1
  done
}

info "Starting WITStream Connect® on port ${PORT}..."
start_container --network host
info "Waiting for it to come up..."
wait_until_healthy

PUBLISHED_PORT_ONLY=""
if [ -z "$HEALTHY" ] && [ "$(docker info --format '{{.OperatingSystem}}' 2>/dev/null)" = "Docker Desktop" ] \
  && docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  info "Host networking isn't switched on in Docker Desktop. Starting with just the dashboard port instead..."
  start_container -p "${PORT}:${PORT}"
  wait_until_healthy
  PUBLISHED_PORT_ONLY="1"
fi

# The address other computers use to reach this one. A server usually
# has no browser of its own, so "localhost" is no use to the person
# reading this. Taken from the machine's own network settings (the
# address it uses for outgoing traffic), with no outside lookup.
server_address() {
  ADDR=""
  if command -v ip >/dev/null 2>&1; then
    ADDR=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
  fi
  if [ -z "$ADDR" ] && command -v hostname >/dev/null 2>&1; then
    ADDR=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  if [ -z "$ADDR" ] && command -v ipconfig >/dev/null 2>&1; then
    ADDR=$(ipconfig getifaddr en0 2>/dev/null || true)
  fi
  if [ -z "$ADDR" ]; then ADDR="<this server's address>"; fi
  printf '%s' "$ADDR"
}

info ""
if [ -n "$HEALTHY" ]; then
  # Bold green (and the address in bold) only when writing to a
  # terminal, so a saved log has no stray colour codes in it.
  if [ -t 1 ]; then GREEN_BOLD=$'\033[1;32m'; BOLD=$'\033[1m'; PLAIN=$'\033[0m'; else GREEN_BOLD=""; BOLD=""; PLAIN=""; fi
  info "${GREEN_BOLD}✓ WITStream Connect® is running.${PLAIN}"
  info ""
  info "1. Open a web browser on any computer that can reach this server and go to:"
  info ""
  info "     ${BOLD}http://$(server_address):${PORT}${PLAIN}"
  info ""
  info "2. The dashboard asks for your API key the first time you open it. It is saved as apiKey in ${CONFIG_FILE}."
  info "   If the page doesn't open from another computer, check that port ${PORT} is allowed through this server's firewall."
  info ""
  info "Note: CSV/LAS output and any OPC-UA certificate are kept in ./${DATA_DIR}, on this machine, so they survive the next update too."
  info "To update later, run this same script again (optionally with a version, e.g. ./install.sh v1.4.2)."
  if [ -n "$PUBLISHED_PORT_ONLY" ]; then
    info ""
    info "Note: only the dashboard is reachable from other machines on this Docker Desktop install."
    info "For the output ports (WITSML, WITS0, ETP, OPC-UA, Modbus), switch on Docker Desktop's"
    info "\"Enable host networking\" setting (Settings, Resources, Network), then run this script again."
  fi
else
  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    error "The container is running, but the dashboard at http://localhost:${PORT} never answered. Check ${CONFIG_FILE} for a mistake, then look at the real startup logs: docker logs ${CONTAINER_NAME}"
  else
    error "The container stopped unexpectedly right after starting. Look at the real startup logs to see why: docker logs ${CONTAINER_NAME}"
  fi
  exit 1
fi
