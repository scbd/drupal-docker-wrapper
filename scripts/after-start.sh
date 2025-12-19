#!/usr/bin/env bash
set -euo pipefail

# After-start script: Runs ~60 seconds after Apache starts
# Handles module reinstall, cleanup, cache rebuild, and privilege management
# This script is forked from entrypoint.sh and runs in the background

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1090
source "${SCRIPT_DIR}/lib/common.sh"

LOG_PREFIX="after-start"

# Version tag for this release (used only to gate one-time startup tasks)
AFTER_START_VERSION="11.2.10-v3"
MARKER_FILE="/tmp/after-start-${AFTER_START_VERSION}.complete"

# Generic module repair for contrib modules that may have stale directories
# Reads from module-repair-list.json to determine which modules need checking
# - If an old module directory is present (commonly from a dev volume mount)
#   move it aside to a temp location
# - Run `composer install` to restore module directories based on composer.lock
# - Cleanup temp backup and fix ownership/permissions
repair_composer_managed_modules() {
  local project_root
  project_root="$(find_project_root)" || return 0

  local module_list_file="${SCRIPT_DIR}/module-repair-list.json"
  
  # Check if module repair list exists
  if [[ ! -f "${module_list_file}" ]]; then
    log "Module repair list not found at ${module_list_file}; skipping module repair."
    return 0
  fi

  # Check if jq is available for JSON parsing
  if ! command -v jq >/dev/null 2>&1; then
    log "jq not available; skipping module repair."
    return 0
  fi

  local modules_to_repair
  modules_to_repair=$(jq -c '.modules[]' "${module_list_file}" 2>/dev/null || echo "")
  
  if [[ -z "${modules_to_repair}" ]]; then
    log "No modules configured for repair; skipping."
    return 0
  fi

  local needs_repair=0
  local modules_needing_repair=()
  
  # Allow manual override
  if [[ "${DRUPAL_AFTER_START_FORCE_MODULE_REPAIR:-}" == "1" ]]; then
    needs_repair=1
  fi

  local www_uid www_gid
  www_uid="$(id -u www-data 2>/dev/null || echo 33)"
  www_gid="$(id -g www-data 2>/dev/null || echo 33)"

  # Check each module in the list
  while IFS= read -r module_json; do
    local module_name module_path module_reason
    module_name=$(echo "${module_json}" | jq -r '.name // empty')
    module_path=$(echo "${module_json}" | jq -r '.path // empty')
    module_reason=$(echo "${module_json}" | jq -r '.reason // "Module upgrade may require repair"')
    
    [[ -z "${module_name}" || -z "${module_path}" ]] && continue
    
    local full_path="${project_root}/${module_path}"
    
    # If directory doesn't exist, skip this module
    if [[ ! -d "${full_path}" ]]; then
      log "Module ${module_name} directory not found at ${full_path}; skipping."
      continue
    fi
    
    # Heuristics to detect a stale/volume-mounted module directory:
    # - wrong ownership (common when created by root on host)
    # - missing composer.json
    # - directory unexpectedly empty
    local module_needs_repair=0
    
    if [[ "${needs_repair}" -eq 0 ]]; then
      local dir_owner
      dir_owner="$(stat -c '%u:%g' "${full_path}" 2>/dev/null || true)"

      if [[ -n "${dir_owner}" && "${dir_owner}" != "${www_uid}:${www_gid}" ]]; then
        log "Module ${module_name} has incorrect ownership; marking for repair."
        module_needs_repair=1
      elif [[ ! -f "${full_path}/composer.json" ]]; then
        log "Module ${module_name} missing composer.json; marking for repair."
        module_needs_repair=1
      elif ! find "${full_path}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
        log "Module ${module_name} directory is empty; marking for repair."
        module_needs_repair=1
      fi
    else
      module_needs_repair=1
    fi
    
    if [[ "${module_needs_repair}" -eq 1 ]]; then
      needs_repair=1
      modules_needing_repair+=("${module_name}:${full_path}")
    fi
  done < <(echo "${modules_to_repair}")

  # If no modules need repair, exit early
  if [[ "${needs_repair}" -eq 0 ]]; then
    log "All configured modules look healthy; skipping module repair."
    return 0
  fi

  local backup_root="/tmp/drupal-module-backups/${AFTER_START_VERSION}"
  
  log "Preparing to repair ${#modules_needing_repair[@]} composer-managed module(s)."
  mkdir -p "${backup_root}"

  # Move problematic modules aside
  for module_entry in "${modules_needing_repair[@]}"; do
    local module_name="${module_entry%%:*}"
    local module_full_path="${module_entry#*:}"
    local backup_dir="${backup_root}/${module_name}"
    
    if mv "${module_full_path}" "${backup_dir}" 2>/dev/null; then
      log "Moved ${module_full_path} -> ${backup_dir}"
    else
      log "Could not move ${module_full_path} to ${backup_dir}; continuing with composer install."
    fi
  done

  log "Running composer install to ensure module tree matches composer.lock..."
  cd "${project_root}" || return 0

  # Run as www-data to keep permissions sane.
  # Note: We intentionally use install (not require) to avoid mutating composer.json/lock at runtime.
  gosu www-data composer install \
    --no-interaction \
    --no-progress \
    --optimize-autoloader \
    --prefer-dist \
    2>&1 || log "Composer install had issues; continuing."

  # Best-effort cleanup of temp backups after composer succeeds.
  # If composer failed, leaving the backup can help with debugging.
  if [[ -d "${backup_root}" ]]; then
    rm -rf "${backup_root}" 2>/dev/null || true
  fi
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

# Best-effort ownership fixups for paths commonly mounted as volumes.
ensure_runtime_ownership() {
  local project_root
  project_root="$(find_project_root)" || return 0

  local paths=(
    "${project_root}/web/sites"
    "${project_root}/web/modules"
    "${project_root}/vendor"
    "/var/www/.composer"
  )

  local p
  for p in "${paths[@]}"; do
    if [[ -e "${p}" ]]; then
      chown -R www-data:www-data "${p}" 2>/dev/null || true
    fi
  done
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

  # 1. Repair composer-managed modules (one-time; runs composer install as www-data)
  repair_composer_managed_modules

  # 2. Cleanup deprecated paths
  cleanup_deprecated_paths

  # 3. Fix permissions on sites/files and common mounted dirs
  ensure_sites_files_permissions
  ensure_runtime_ownership

  # 4. Rebuild cache (runs as www-data via gosu)
  rebuild_cache

  # Mark complete
  touch "${MARKER_FILE}"
  log "After-start tasks for ${AFTER_START_VERSION} complete."
}

main "$@"
