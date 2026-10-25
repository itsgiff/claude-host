#!/usr/bin/env bash
# Smoke tests for entrypoint.sh, using a stub `claude` so nothing real starts.
# Runs on any Linux laptop (and the NAS). Run directly or via pre-commit.
#
#   tests/entrypoint_test.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/bin" "${TMP}/home" "${TMP}/work"

# Stub claude: reports its arguments, then waits until it's sent SIGTERM.
# On TERM it also stops its own sleep, so no processes outlive the test.
cat > "${TMP}/bin/claude" <<'STUB'
#!/bin/sh
[ "$1" = "--version" ] && { echo "0.0.0 (stub)"; exit 0; }
echo "stub-args: $*"
sleep 60 &
nap=$!
trap 'echo "stub-got-TERM"; kill "${nap}" 2>/dev/null; exit 0' TERM
wait "${nap}"
STUB
chmod +x "${TMP}/bin/claude"

passed=0
failed=0

# run <seconds> <cwd> [VAR=value ...]
# Starts entrypoint.sh with a clean environment, waits, then sends SIGTERM like `docker stop`.
run() {
  local secs=$1 cwd=$2
  shift 2
  (
    cd "${cwd}"
    env -i PATH="${TMP}/bin:${PATH}" HOME="${TMP}/home" WORK_DIR="${TMP}/work" "$@" \
      bash "${ROOT}/entrypoint.sh"
  ) >"${TMP}/out" 2>&1 &
  local pid=$! _
  sleep "${secs}"
  kill -TERM "${pid}" 2>/dev/null || true
  # Docker gives a container 10 s to stop; we give it 3 s, then kill and record it,
  # so a broken shutdown fails the test instead of hanging the commit.
  for _ in $(seq 1 15); do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.2
  done
  if kill -0 "${pid}" 2>/dev/null; then
    echo "[harness] still running 3s after SIGTERM; killed" >>"${TMP}/out"
    killtree "${pid}"
  fi
  wait "${pid}" 2>/dev/null || true
}

killtree() {   # SIGKILL a process and all its descendants
  local child
  for child in $(pgrep -P "$1" || true); do
    killtree "${child}"
  done
  kill -KILL "$1" 2>/dev/null || true
}

expect() {     # expect <description> <text that must appear in the output>
  if grep -qF -- "$2" "${TMP}/out"; then
    echo "ok   - $1"; passed=$((passed + 1))
  else
    echo "FAIL - $1 (missing: $2)"; sed 's/^/     | /' "${TMP}/out"; failed=$((failed + 1))
  fi
}

reject() {     # reject <description> <text that must NOT appear in the output>
  if grep -qF -- "$2" "${TMP}/out"; then
    echo "FAIL - $1 (unexpected: $2)"; sed 's/^/     | /' "${TMP}/out"; failed=$((failed + 1))
  else
    echo "ok   - $1"; passed=$((passed + 1))
  fi
}

echo "# clean start, then docker stop"
run 1 "${TMP}/work"
expect "starts remote-control with default flags" \
  "stub-args: remote-control --name NAS --spawn same-dir --capacity 4 --permission-mode default"
expect "forwards SIGTERM to claude" "stub-got-TERM"
expect "logs a clean stop" "Signal received, stopping"
reject "stops within 3 s of SIGTERM" "[harness] still running"

echo "# tunables pass through"
run 1 "${TMP}/work" RC_NAME=Test RC_CAPACITY=2 RC_PERMISSION_MODE=acceptEdits
expect "custom flags reach claude" \
  "stub-args: remote-control --name Test --spawn same-dir --capacity 2 --permission-mode acceptEdits"

echo "# forbidden variables block start"
for var in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL DISABLE_GROWTHBOOK; do
  run 1 "${TMP}/work" "${var}=x"
  expect "${var} is reported" "PREFLIGHT: ${var} is set"
  reject "${var} prevents claude from starting" "stub-args:"
done

echo "# unwritable work dir blocks start"
run 1 "${TMP}/work" WORK_DIR=/nonexistent-claude-host-test
expect "reports unwritable directory" "/nonexistent-claude-host-test is not writable"
reject "claude does not start" "stub-args:"

echo "# working in \$HOME blocks start"
run 1 "${TMP}/home"
expect "reports \$HOME as working directory" "working directory is \$HOME"
reject "claude does not start" "stub-args:"

echo
echo "${passed} passed, ${failed} failed"
[[ ${failed} -eq 0 ]]
