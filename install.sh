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
# admin API) — running it again stops the old container, pulls the new
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

info()  { printf '%s\n' "$1"; }
error() { printf 'Error: %s\n' "$1" >&2; }

info "WITStream Connect installer"
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

# 2. Pull the image. Tried anonymously first, since whether this image
#    needs sign-in depends on how it's published — no need to prompt a
#    customer for credentials they may not need.
info "Pulling ${IMAGE}:${VERSION}..."
if ! docker pull "${IMAGE}:${VERSION}" 2>/tmp/witstream-pull-error.log; then
  if grep -qi "denied\|unauthorized" /tmp/witstream-pull-error.log; then
    info ""
    info "This image needs sign-in. Use the GitHub username and access token from your WITStream Connect account."
    read -r -p "GitHub username: " GH_USER
    read -r -s -p "Access token: " GH_TOKEN
    echo ""
    echo "$GH_TOKEN" | docker login "$REGISTRY" -u "$GH_USER" --password-stdin
    docker pull "${IMAGE}:${VERSION}"
  else
    error "Could not pull ${IMAGE}:${VERSION}. Details:"
    cat /tmp/witstream-pull-error.log >&2
    rm -f /tmp/witstream-pull-error.log
    exit 1
  fi
fi
rm -f /tmp/witstream-pull-error.log

# 3. First run only: create a starter config file and ask for the
#    licence key. Never overwrites an existing config on a re-run, so
#    real connections and settings survive every update.
if [ ! -f "$CONFIG_FILE" ]; then
  info ""
  info "No ${CONFIG_FILE} found in this folder — setting one up now."
  read -r -p "Licence key (from your WITStream Connect account): " LICENCE_KEY
  API_KEY=$(env LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 32 || true)
  if [ -z "$API_KEY" ]; then API_KEY="changeme-please-set-a-real-key"; fi

  cat > "$CONFIG_FILE" <<EOF
{
  "apiKey": "${API_KEY}",
  "licence": {
    "licenceKey": "${LICENCE_KEY}",
    "licenceServerUrl": "https://licence.witstreamconnect.com"
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

info "Starting WITStream Connect on port ${PORT}..."
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p "${PORT}:8080" \
  -v "$(pwd)/${CONFIG_FILE}:/app/witstream-config.json" \
  "${IMAGE}:${VERSION}"

info ""
info "WITStream Connect is running: http://localhost:${PORT}"
info "To update later, run this same script again (optionally with a version, e.g. ./install.sh v1.4.2)."
