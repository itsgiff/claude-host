#!/usr/bin/env bash
# claude-host entrypoint
#
# Runs Claude Code Remote Control in server mode under a small supervisor:
#   - preflight checks catch the known misconfigurations before Claude starts
#   - failures and network outages retry with backoff (30s doubling to 15 min)
#     instead of a tight Docker restart loop
#   - SIGTERM from `docker stop` is forwarded so sessions shut down cleanly
#
# Tunables (set in the claude-host service in storage-compose.yml):
#   RC_NAME             session title in the Claude app            (default: NAS)
#   RC_SPAWN            same-dir | worktree                        (default: same-dir)
#   RC_CAPACITY         max concurrent sessions                    (default: 4)
#   RC_PERMISSION_MODE  starting permission mode for sessions      (default: default)
#   MIN_HEALTHY_SECS    a run this long resets the backoff         (default: 300)
#   WORK_DIR            directory Claude works in                  (default: /work; tests override it)

set -uo pipefail

RC_NAME="${RC_NAME:-NAS}"
RC_SPAWN="${RC_SPAWN:-same-dir}"
RC_CAPACITY="${RC_CAPACITY:-4}"
RC_PERMISSION_MODE="${RC_PERMISSION_MODE:-default}"
MIN_HEALTHY_SECS="${MIN_HEALTHY_SECS:-300}"
WORK_DIR="${WORK_DIR:-/work}"
BACKOFF_START=30
BACKOFF_MAX=900

# Portable timestamp: GNU date in the container, BSD date when tests run on macOS.
log() { printf '%s [claude-host] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }

# Variables that break Remote Control or route around the claude.ai subscription login.
FORBIDDEN_VARS=(
  ANTHROPIC_API_KEY
  ANTHROPIC_AUTH_TOKEN
  CLAUDE_CODE_OAUTH_TOKEN
  ANTHROPIC_BASE_URL
  CLAUDE_CODE_USE_BEDROCK
  CLAUDE_CODE_USE_VERTEX
  CLAUDE_CODE_USE_FOUNDRY
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
  DISABLE_GROWTHBOOK
)

preflight() {
  local failed=0 v d
  for v in "${FORBIDDEN_VARS[@]}"; do
    if [[ -n "${!v:-}" ]]; then
      log "PREFLIGHT: ${v} is set. Remote Control needs a claude.ai login talking to api.anthropic.com; remove it from the claude-host service in storage-compose.yml."
      failed=1
    fi
  done
  for d in "${HOME}" "${WORK_DIR}"; do
    if [[ ! -w "${d}" ]]; then
      log "PREFLIGHT: ${d} is not writable by uid $(id -u). Fix ownership of the volume on the NAS."
      failed=1
    fi
  done
  # Compare physical paths: on macOS $HOME can be reached through a symlink
  # (/var -> /private/var), so a plain string compare misses it.
  if [[ "$(pwd -P)" == "$(cd "${HOME}" 2>/dev/null && pwd -P)" ]]; then
    log "PREFLIGHT: working directory is \$HOME, where workspace trust is never saved. Use ${WORK_DIR}."
    failed=1
  fi
  if ! command -v claude >/dev/null 2>&1; then
    log "PREFLIGHT: claude binary not found on PATH."
    failed=1
  fi
  return "${failed}"
}

child=0
on_term() {
  log "Signal received, stopping"
  if (( child > 0 )); then
    kill -TERM "${child}" 2>/dev/null
    wait "${child}"
  fi
  exit 0
}
trap on_term TERM INT

log "claude-host starting ($(claude --version 2>/dev/null || echo 'claude not found'))"

backoff=${BACKOFF_START}
while true; do
  if preflight; then
    log "Running: claude remote-control --name ${RC_NAME} --spawn ${RC_SPAWN} --capacity ${RC_CAPACITY} --permission-mode ${RC_PERMISSION_MODE}"
    started=$(date +%s)
    # Backgrounded so the trap can forward SIGTERM. In a non-interactive shell a
    # background job's stdin is /dev/null, so an unanswered trust or enable prompt
    # fails fast (and is logged) instead of hanging. Answer those once via bootstrap.
    claude remote-control \
      --name "${RC_NAME}" \
      --spawn "${RC_SPAWN}" \
      --capacity "${RC_CAPACITY}" \
      --permission-mode "${RC_PERMISSION_MODE}" &
    child=$!
    wait "${child}"
    rc=$?
    child=0
    ran=$(( $(date +%s) - started ))
    log "remote-control exited rc=${rc} after ${ran}s"
    if (( ran >= MIN_HEALTHY_SECS )); then
      backoff=${BACKOFF_START}
    fi
  else
    log "Preflight failed. Fix the above, then run './host.sh restart' or wait for the retry."
  fi
  log "Retrying in ${backoff}s"
  sleep "${backoff}" &
  wait $!
  backoff=$(( backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2 ))
done
