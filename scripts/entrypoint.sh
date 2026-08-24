#!/usr/bin/env bash
set -euo pipefail

# Thin entrypoint wrapper. Starts Apache immediately via the upstream Drupal
# entrypoint and defers heavy startup work to after-start.sh so the container
# begins serving without waiting for it.
#
# Optional components are guarded: this script is correct whether or not the
# patch engine and after-start script are present in the image.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared helpers are REQUIRED. An unguarded `source` under `set -e` would kill
# PID 1 with a bare bash error if lib/ were not copied alongside this file, so
# fail with a diagnostic a crash-looping container can actually be debugged from.
if [[ ! -r "${SCRIPT_DIR}/lib/common.sh" ]]; then
  echo "[entrypoint] FATAL: missing or unreadable ${SCRIPT_DIR}/lib/common.sh" >&2
  exit 1
fi
# shellcheck source=lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

# Consumed by log() in lib/common.sh.
# shellcheck disable=SC2034
LOG_PREFIX="entrypoint"

# Optional: the runtime patch engine. Absent until the patch-engine layer ships.
if [[ -r "${SCRIPT_DIR}/lib/patches.sh" ]]; then
  # shellcheck source=lib/patches.sh disable=SC1091
  source "${SCRIPT_DIR}/lib/patches.sh" || log "Could not load the patch engine; continuing."
fi

AFTER_START="${SCRIPT_DIR}/after-start.sh"
[[ -x "${AFTER_START}" ]] || AFTER_START=/usr/local/bin/after-start.sh

# How long to wait for the web server to answer before running after-start, and
# how often to probe. Overridable so CI can drive the deferred work immediately
# instead of waiting out the delay.
READY_TIMEOUT="${DRUPAL_AFTER_START_READY_TIMEOUT:-120}"
READY_INTERVAL="${DRUPAL_AFTER_START_READY_INTERVAL:-2}"
READY_URL="${DRUPAL_AFTER_START_READY_URL:-http://127.0.0.1/}"

# Validate the numeric overrides HERE, while a bad value can still be reported.
# Left unchecked, a non-numeric timeout makes $(( )) fail under `set -u` and a
# non-numeric interval makes `sleep` fail under `set -e`, either of which kills
# the background job after the "deferring" line has already been logged - so the
# log would claim work was scheduled that silently never ran. An interval of 0
# is rejected for a different reason: connection-refused returns instantly, so
# it would spin a hot loop rather than a poll.
if ! [[ "${READY_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  log "Invalid DRUPAL_AFTER_START_READY_TIMEOUT '${READY_TIMEOUT}'; falling back to 120."
  READY_TIMEOUT=120
fi
if ! [[ "${READY_INTERVAL}" =~ ^[1-9][0-9]*$ ]]; then
  log "Invalid DRUPAL_AFTER_START_READY_INTERVAL '${READY_INTERVAL}'; falling back to 2."
  READY_INTERVAL=2
fi

# Block until the local web server answers, or the timeout elapses.
# Returns 0 if it became ready, 1 otherwise, so the caller can log which.
#
# Readiness means "something answered HTTP", not "answered 2xx". A Drupal
# container legitimately replies 301 (canonical-domain redirect), 403, or 500
# mid-install while Apache is perfectly up, which is all this probe needs to
# establish. Failing those would poll out the whole timeout on a healthy boot.
wait_for_http_ready() {
  if ! command -v curl >/dev/null 2>&1; then
    log "curl is not available; cannot probe readiness."
    return 1
  fi

  local deadline=$((SECONDS + READY_TIMEOUT)) remaining
  while (( SECONDS < deadline )); do
    # stderr is suppressed deliberately: every poll before Apache is up would
    # otherwise log a connection error, burying the real startup log. The one
    # error worth seeing - curl missing entirely - is caught by the check above.
    if curl -sS --proto '=http,https' -o /dev/null --max-time 2 "${READY_URL}" 2>/dev/null; then
      return 0
    fi
    # Never sleep past the deadline, so the effective wait matches the logged one.
    remaining=$((deadline - SECONDS))
    (( remaining <= 0 )) && break
    sleep "$(( READY_INTERVAL < remaining ? READY_INTERVAL : remaining ))"
  done
  return 1
}

# Run after-start once the server is up, and report how it went. A fixed sleep
# would either fire before Apache is serving or waste time after it is; and a
# discarded exit status leaves a failed run indistinguishable from a slow one.
run_after_start_when_ready() {
  if wait_for_http_ready; then
    log "Web server is answering; running after-start tasks."
  else
    log "Web server did not answer within ~${READY_TIMEOUT}s; running after-start tasks anyway."
  fi

  local status=0
  "${AFTER_START}" || status=$?
  if (( status == 0 )); then
    log "after-start completed successfully."
  else
    log "after-start FAILED with exit status ${status}."
  fi
  return "${status}"
}

main() {
  # Apply any available patches before Apache starts, so a volume-mounted
  # contrib tree (which shadows the image's build-time composer-patches) is
  # patched too. Idempotent, and a no-op when the engine or patches are absent.
  #
  # A failure here must never stop the container from serving: this is a
  # best-effort step, and `set -e` would otherwise exit before the exec below.
  if declare -F apply_patches_if_present >/dev/null 2>&1; then
    apply_patches_if_present || log "Patch step failed (status $?); continuing to start Apache."
  fi

  if [[ -f "${AFTER_START}" && ! -x "${AFTER_START}" ]]; then
    log "WARNING: ${AFTER_START} exists but is not executable; deferred tasks will be skipped."
  fi

  if [[ -x "${AFTER_START}" ]]; then
    # NOTE: SIGTERM on `docker stop` reaches PID 1 only, so a mid-flight
    # after-start is never notified and is SIGKILLed when the grace period
    # ends. Everything behind this fork must therefore be idempotent and safe
    # to resume on the next start - never put a non-resumable migration here.
    #
    # No redirection: the forked child inherits this script's stdout, and the
    # exec below does not touch the child's descriptors. Redirecting to
    # /proc/1/fd/1 would silently kill the child wherever that path is not
    # openable (docker run --user, a PID 1 owned by another uid, hidepid).
    log "Deferring after-start tasks until the web server answers (timeout ~${READY_TIMEOUT}s)."
    run_after_start_when_ready &
  else
    log "No executable after-start script present; skipping deferred tasks."
  fi

  # Chain to the upstream Drupal entrypoint when present. Apache starts as root
  # to open logs and bind port 80, then drops privileges to www-data itself.
  if [[ -x /usr/local/bin/docker-entrypoint ]]; then
    exec /usr/local/bin/docker-entrypoint "$@"
  else
    exec "$@"
  fi
}

main "$@"
