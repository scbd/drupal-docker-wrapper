#!/usr/bin/env bash
set -euo pipefail

# Thin entrypoint wrapper that starts Apache immediately and forks
# the after-start script to run heavy operations in the background.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1090
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1090
source "${SCRIPT_DIR}/lib/patches.sh"

LOG_PREFIX="entrypoint"

main() {
  # Apply any available patches (if present); otherwise this is a no-op
  apply_patches_if_present

  # After-start script DISABLED - was removing module files unexpectedly
  # TODO: Re-enable once module repair logic is fixed
  # Fork the after-start script to run 60 seconds after Apache starts
  # This handles: module reinstall, cleanup, permissions, cache rebuild
  # log "Scheduling after-start script to run in 60 seconds..."
  # (sleep 60 && /usr/local/bin/after-start.sh >> /proc/1/fd/1 2>&1) &
  log "After-start script is DISABLED"

  # Chain to the upstream Drupal entrypoint if present
  # Note: Apache must start as root to open logs and bind to port 80,
  # then it drops privileges to www-data internally
  if [[ -x /usr/local/bin/docker-entrypoint ]]; then
    exec /usr/local/bin/docker-entrypoint "$@"
  else
    exec "$@"
  fi
}

main "$@"
