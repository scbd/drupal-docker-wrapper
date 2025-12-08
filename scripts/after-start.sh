#!/usr/bin/env bash
set -euo pipefail

# After-start script: Runs ~60 seconds after Apache starts
# Handles module reinstall, cleanup, cache rebuild, and privilege management
# This script is forked from entrypoint.sh and runs in the background

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1090
source "${SCRIPT_DIR}/lib/common.sh"

LOG_PREFIX="after-start"

# Version tag for this release
AFTER_START_VERSION="11.2.9-v10"
MARKER_FILE="/tmp/after-start-${AFTER_START_VERSION}.complete"

# Reinstall specific modules with exact versions
reinstall_modules() {
  local project_root
  project_root="$(find_project_root)" || return 0

  log "Reinstalling modules with exact versions..."
  cd "${project_root}" || return 0
  
  # Run composer require as www-data to avoid permission issues
  gosu www-data composer require \
    'drupal/linkit:7.0.11' \
    'drupal/menu_link_attributes:1.6' \
    --no-interaction --no-progress 2>&1 || log "Composer require had issues; continuing."
}

# Clean up deprecated paths
cleanup_deprecated_paths() {
  local project_root
  project_root="$(find_project_root)" || return 0

  local web_root="${project_root}/web"
  local paths=(
    "modules/contrib/login_destination"
    # "modules/contrib/ckeditor_templates"
    "modules/contrib/ckeditor_templates_ui"
    "modules/contrib/ctools"
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

# Ensure correct permissions on sites/files directories
ensure_sites_files_permissions() {
  local project_root
  project_root="$(find_project_root)" || return 0

  local sites_base="${project_root}/web/sites"

  # Default site files directory
  mkdir -p "${sites_base}/default/files"
  chmod -R 775 "${sites_base}/default/files" 2>/dev/null || true
  chown -R www-data:www-data "${sites_base}/default/files" 2>/dev/null || true

  # Multisite files directories from sites.php if present
  if [[ -f "${sites_base}/sites.php" ]]; then
    DRUPAL_SITES_FILE="${sites_base}/sites.php" php -r '$sites = []; include getenv("DRUPAL_SITES_FILE"); foreach (array_unique(array_values($sites)) as $dir) { echo $dir . PHP_EOL; }' \
      | while read -r site_dir; do
          [[ -z "${site_dir}" ]] && continue
          mkdir -p "${sites_base}/${site_dir}/files"
          chmod -R 775 "${sites_base}/${site_dir}/files" 2>/dev/null || true
          chown -R www-data:www-data "${sites_base}/${site_dir}/files" 2>/dev/null || true
        done
  fi
}

# Rebuild Drupal cache
rebuild_cache() {
  local project_root
  project_root="$(find_project_root)" || return 0

  if [[ -f "${project_root}/web/sites/default/settings.php" ]]; then
    log "Rebuilding Drupal cache..."
    if command -v /opt/drupal/vendor/bin/drush >/dev/null 2>&1; then
      gosu www-data /opt/drupal/vendor/bin/drush -r "${project_root}/web" cache:rebuild || log "drush cr failed; continuing."
    elif [[ -f "${project_root}/web/core/rebuild.php" ]]; then
      gosu www-data php "${project_root}/web/core/rebuild.php" || log "core rebuild.php failed; continuing."
    fi
  else
    log "No Drupal settings.php found, skipping cache rebuild."
  fi
}

main() {
  # Skip if already completed for this version
  if [[ -f "${MARKER_FILE}" ]]; then
    log "After-start for ${AFTER_START_VERSION} already complete, exiting."
    exit 0
  fi

  log "Starting after-start tasks for ${AFTER_START_VERSION}..."

  # 1. Reinstall modules (runs as www-data via gosu)
  reinstall_modules

  # 2. Cleanup deprecated paths (important after install)
  cleanup_deprecated_paths

  # 3. Fix permissions on sites/files
  ensure_sites_files_permissions

  # 4. Rebuild cache (runs as www-data via gosu)
  rebuild_cache

  # Mark complete
  touch "${MARKER_FILE}"
  log "After-start tasks for ${AFTER_START_VERSION} complete."
}

main "$@"
