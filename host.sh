#!/bin/sh
# Ops helper for claude-host on the NAS (DSM has no make).
# Run from /volume1/docker/build/claude-host.
#
# The service itself is defined in /volume1/docker/storage-compose.yml and
# started with compose.sh like every other service. This script covers the
# rest: data folders, the image, the one-time interactive bootstrap, and
# day-to-day inspection.
set -eu
cd "$(dirname "$0")"

# Optional .env with HOST_UID / HOST_GID / DATA_DIR (no secrets).
if [ -f .env ]; then
  # shellcheck disable=SC1091
  . ./.env
fi
HOST_UID="${HOST_UID:-1027}"
HOST_GID="${HOST_GID:-100}"
DATA_DIR="${DATA_DIR:-/volume1/docker/appdata}"
APP_DIR="${DATA_DIR}/claude-host"
IMAGE="claude-host:local"

build() {   # build [extra docker build flags...]
  sudo docker build --pull "$@" \
    --build-arg UID="${HOST_UID}" \
    --build-arg GID="${HOST_GID}" \
    -t "${IMAGE}" .
}

case "${1:-help}" in
  init)
    # Create the data folders and seed settings once; never overwrite a live settings.json.
    sudo mkdir -p "${APP_DIR}/home/.claude" "${APP_DIR}/work"
    if [ ! -f "${APP_DIR}/home/.claude/settings.json" ]; then
      sudo cp settings.template.json "${APP_DIR}/home/.claude/settings.json"
    fi
    sudo chown -R "${HOST_UID}:${HOST_GID}" "${APP_DIR}"
    sudo chmod 0700 "${APP_DIR}/home"
    ;;
  build)     build ;;
  rebuild)   build --no-cache ;;   # picks up a new Claude Code release
  bootstrap)
    # One-time interactive first run. Do this BEFORE the service is started,
    # so two Claude processes never share the home folder during login.
    sudo docker run --rm -it --init \
      -v "${APP_DIR}/home:/home/claude" \
      -v "${APP_DIR}/work:/work" \
      -w /work --entrypoint bash "${IMAGE}"
    ;;
  restart)   sudo docker restart claude-host ;;
  logs)      sudo docker logs -f --tail 200 claude-host ;;
  shell)     sudo docker exec -it claude-host bash ;;
  doctor)    sudo docker exec claude-host claude doctor ;;
  status)    sudo docker ps --filter name=claude-host --format '{{.Names}}  {{.Status}}' ;;
  *)
    echo "usage: $0 {init|build|rebuild|bootstrap|restart|logs|shell|doctor|status}"
    exit 1
    ;;
esac
