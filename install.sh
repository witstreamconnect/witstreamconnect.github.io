#!/usr/bin/env bash
# WITStream Connect installer.
#
# Handles login (only if the image needs it), pull, and run in one
# sequence, matching the delivery mechanism decision in CLAUDE.md: "a
# small installer script the customer runs once... not several
# remembered manual commands."
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

# 2. The product image is private (see CLAUDE.md: kept that way
#    deliberately to protect the real product logic, not left private by
#    accident). The Licence Server itself brokers real pull access using
#    the licence key as the credential, so nobody ever needs a separate
#    GitHub account just to install this. Ask for the licence key once,
#    up front, and reuse it below for the config file too.
if [ -f "$CONFIG_FILE" ]; then
  LICENCE_KEY=$(sed -n 's/.*"licenceKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -1)
fi
if [ -z "${LICENCE_KEY:-}" ]; then
  read -r -p "Licence key (from your WITStream Connect® account): " LICENCE_KEY
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
  error "That licence key wasn't accepted , check it's correct, active, and not expired."
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
  info "No ${CONFIG_FILE} found in this folder , setting one up now."
  API_KEY=$(env LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 32 || true)
  if [ -z "$API_KEY" ]; then API_KEY="changeme-please-set-a-real-key"; fi

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
fi

# 4. Idempotent (re)start: stop and remove any previous container of
#    the same name first, so re-running this script is exactly the
#    redeploy command an update notice tells a customer to run.
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  info "Stopping the existing container..."
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

info "Starting WITStream Connect® on port ${PORT}..."
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p "${PORT}:8080" \
  -v "$(pwd)/${CONFIG_FILE}:/app/witstream-config.json" \
  "${IMAGE}:${VERSION}"

info ""
info "WITStream Connect® is running: http://localhost:${PORT}"
info "To update later, run this same script again (optionally with a version, e.g. ./install.sh v1.4.2)."
