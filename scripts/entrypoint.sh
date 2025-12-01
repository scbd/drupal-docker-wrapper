#!/usr/bin/env bash
set -euo pipefail

# Thin entrypoint wrapper that orchestrates optional patching, cleanup,
# permissions, and cache rebuild by delegating to smaller helper scripts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1090
source "${SCRIPT_DIR}/entrypoint-common.sh"
# shellcheck disable=SC1090
source "${SCRIPT_DIR}/entrypoint-patches.sh"
# shellcheck disable=SC1090
source "${SCRIPT_DIR}/entrypoint-cleanup.sh"
# shellcheck disable=SC1090
source "${SCRIPT_DIR}/entrypoint-cache-rebuild.sh"

main() {
  # Apply any available patches (if present); otherwise this is a no-op
  entrypoint_apply_patches_if_present

  # Perform image hygiene and runtime-safe permission fixes
  cleanup_deprecated_paths
  ensure_sites_files_permissions

  # If a Drupal site is present, attempt a non-fatal cache rebuild
  entrypoint_maybe_rebuild_cache

  # Chain to the upstream Drupal entrypoint if present
  if [[ -x /usr/local/bin/docker-entrypoint ]]; then
    exec /usr/local/bin/docker-entrypoint "$@"
  else
    exec "$@"
  fi
}

main "$@"
