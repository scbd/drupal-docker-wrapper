#!/usr/bin/env bash
set -euo pipefail

# After-start script: runs once the web server answers (see entrypoint.sh)
# Handles deprecated-path cleanup and image-code permission hardening
# This script is forked from entrypoint.sh and runs in the background

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared helpers are REQUIRED; fail with a diagnostic rather than a bare bash
# error, matching entrypoint.sh.
if [[ ! -r "${SCRIPT_DIR}/lib/common.sh" ]]; then
  echo "[after-start] FATAL: missing or unreadable ${SCRIPT_DIR}/lib/common.sh" >&2
  exit 1
fi
# shellcheck source=lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

# Consumed by log() in lib/common.sh.
# shellcheck disable=SC2034
LOG_PREFIX="after-start"

# Clean up deprecated paths
#
# Defense in depth only. The build excludes robots.txt from drupal-scaffold and
# deletes the upstream image's copy, so this is normally a no-op. It stays as
# cheap insurance against a base-image bump or a future composer operation
# re-scaffolding the file and shadowing the drupal/robotstxt module.
cleanup_deprecated_paths() {
  local project_root
  project_root="$(find_project_root)" || return 0

  local web_root="${project_root}/web"
  local paths=(
    "robots.txt"
  )

  local rel
  for rel in "${paths[@]}"; do
    local target="${web_root}/${rel}"
    if [[ -e "${target}" ]]; then
      log "Removing deprecated path ${target}"
      rm -rf "${target}" || log "Failed to remove ${target}; continuing."
    fi
  done
}

# Harden permissions on the code that ships in the image
# Makes code read-only (root:www-data), directories 755, files 644
# EFS bind mounts (php/custom.ini, modules/custom, sites, drush, temp) are never
# touched here; their permissions are owned by the deploy that mounts them.
harden_image_code() {
  # Must be root to change ownership
  [[ "$(id -u)" -eq 0 ]] || return 0

  local project_root
  project_root="$(find_project_root)" || return 0

  log "Hardening image code permissions..."

  # All code directories that should be locked down (root:www-data, read-only)
  # NOTE: web/modules/custom, web/sites, drush and temp are EFS bind mounts and
  # are deliberately absent from this list.
  local code_paths=(
    "${project_root}/web/core"
    "${project_root}/web/modules/contrib"
    "${project_root}/web/themes"
    "${project_root}/web/profiles"
    "${project_root}/web/libraries"
    "${project_root}/vendor"
  )

  for code_path in "${code_paths[@]}"; do
    if [[ -d "${code_path}" ]]; then
      log "Securing ${code_path} (root:www-data, dirs=755, files=644)..."
      chown -R root:www-data "${code_path}" 2>/dev/null || true
      # Directories: 755 (rwxr-xr-x) - need execute for traversal
      find "${code_path}" -type d -exec chmod 755 {} + 2>/dev/null || true
      # Files: 644 (rw-r--r--) - no execute bit
      find "${code_path}" -type f -exec chmod 644 {} + 2>/dev/null || true
    fi
  done

  # Restore execute permissions on vendor/bin executables (drush, phpunit, etc.)
  # These are wrapper scripts that call actual executables elsewhere in vendor
  if [[ -d "${project_root}/vendor/bin" ]]; then
    log "Restoring execute permissions on vendor/bin..."
    chmod 755 "${project_root}/vendor/bin"/* 2>/dev/null || true
  fi

  # Restore execute permissions on actual CLI tools in vendor (drush, etc.)
  # The vendor/bin wrappers call these actual executables
  local cli_executables=(
    "${project_root}/vendor/drush/drush/drush"
    "${project_root}/vendor/drush/drush/drush.php"
  )
  for exe in "${cli_executables[@]}"; do
    if [[ -f "${exe}" ]]; then
      chmod 755 "${exe}" 2>/dev/null || true
    fi
  done

  # Root-level web files (index.php, update.php, etc.)
  log "Securing root-level web files (root:www-data, 644)..."
  find "${project_root}/web" -maxdepth 1 -type f -exec chown root:www-data {} + 2>/dev/null || true
  find "${project_root}/web" -maxdepth 1 -type f -exec chmod 644 {} + 2>/dev/null || true

  # No blanket .htaccess pass here. Finding them meant walking every directory
  # under the project root, including the EFS-backed sites/ tree and its upload
  # directories, on every container start. The .htaccess files that this pass
  # actually protected durably are already covered: the ones inside the code
  # paths above by their own `-type f` chmod, and web/.htaccess by the
  # root-level pass above. Per-site .htaccess hardening is handled by an
  # external script that traverses each site. See adr/0008.

  log "Image code hardening complete."
}

main() {
  log "Starting after-start tasks..."

  # 1. Cleanup deprecated paths (acts on the image's web root)
  cleanup_deprecated_paths

  # 2. Harden image code permissions in the background (non-blocking).
  # Nothing here touches an EFS bind mount (php/custom.ini, modules/custom,
  # sites, drush, temp), so there is no version marker and no gating: the pass
  # only ever walks paths that ship in the image and is cheap to repeat.
  (
    harden_image_code
    log "Background permission hardening complete."
  ) &

  log "After-start tasks dispatched."
}

main "$@"
