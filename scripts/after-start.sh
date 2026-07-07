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
# Read from package.json if available, otherwise use a default
if command -v jq >/dev/null 2>&1 && [[ -f "/opt/drupal/package.json" ]]; then
  AFTER_START_VERSION=$(jq -r '.version' /opt/drupal/package.json 2>/dev/null || echo "unknown")
else
  AFTER_START_VERSION="unknown"
fi
MARKER_FILE="/tmp/after-start-${AFTER_START_VERSION}.complete"

# Generic module repair for ALL contrib modules
# Automatically checks every module in web/modules/contrib/ directory
# - Compares each module's version against composer.lock to detect mismatches
# - If module is stale, out of date, or has wrong ownership, move it aside
# - Run `composer install` to restore modules from composer.lock
# - Cleanup temp backup and fix ownership/permissions
repair_composer_managed_modules() {
  local project_root
  project_root="$(find_project_root)" || return 0

  local contrib_dir="${project_root}/web/modules/contrib"
  local composer_lock="${project_root}/composer.lock"
  
  # Check if contrib directory exists
  if [[ ! -d "${contrib_dir}" ]]; then
    log "Contrib modules directory not found at ${contrib_dir}; skipping module repair."
    return 0
  fi

  # Check if jq is available (needed for version comparison)
  if ! command -v jq >/dev/null 2>&1; then
    log "jq not available; skipping module repair (cannot parse composer.lock)."
    return 0
  fi

  # Check if composer.lock exists (source of truth for expected versions)
  if [[ ! -f "${composer_lock}" ]]; then
    log "composer.lock not found at ${composer_lock}; skipping module repair."
    return 0
  fi

  # Check if module repair is disabled (useful for dev environments)
  local skip_repair="${DRUPAL_SKIP_MODULE_REPAIR:-0}"
  if [[ "${skip_repair}" == "1" ]]; then
    log "Module repair disabled via DRUPAL_SKIP_MODULE_REPAIR=1; skipping."
    return 0
  fi

  local force_repair="${DRUPAL_AFTER_START_FORCE_MODULE_REPAIR:-0}"
  local modules_needing_repair=()
  
  local www_uid www_gid
  www_uid="$(id -u www-data 2>/dev/null || echo 33)"
  www_gid="$(id -g www-data 2>/dev/null || echo 33)"

  log "Checking ALL contrib modules for repair (force_repair=${force_repair}, www-data=${www_uid}:${www_gid})..."

  # Iterate through every module in contrib directory
  while IFS= read -r module_dir; do
    local module_name
    module_name=$(basename "${module_dir}")
    
    # Skip . and .. and any non-directories
    [[ "${module_name}" == "." || "${module_name}" == ".." ]] && continue
    [[ ! -d "${module_dir}" ]] && continue
    
    local full_path="${module_dir}"
    
    log "Checking module ${module_name} at ${full_path}..."
    
    # If directory doesn't exist, mark for repair (composer install will create it)
    if [[ ! -d "${full_path}" ]]; then
      log "Module ${module_name} directory not found; marking for repair."
      modules_needing_repair+=("${module_name}:${full_path}")
      continue
    fi
    
    # If force repair is enabled, mark all modules for repair
    if [[ "${force_repair}" == "1" ]]; then
      log "Module ${module_name} marked for repair (force mode)."
      modules_needing_repair+=("${module_name}:${full_path}")
      continue
    fi
    
    # Heuristics to detect a stale/volume-mounted module directory:
    # 1. Version mismatch against composer.lock (PRIMARY CHECK)
    # 2. Wrong ownership on directory or its contents
    # 3. Missing composer.json (corrupted install)
    # 4. Missing .info.yml file (corrupted/incomplete module)
    # 5. Directory unexpectedly empty
    local module_needs_repair=0
    local repair_reason=""
    
    # PRIMARY CHECK: Compare installed version against composer.lock
    # Get expected version from composer.lock for drupal/${module_name}
    local expected_version
    expected_version=$(jq -r --arg name "drupal/${module_name}" \
      '.packages[] | select(.name == $name) | .version' \
      "${composer_lock}" 2>/dev/null || echo "")
    
    if [[ -n "${expected_version}" ]]; then
      # Get installed version from module's composer.json
      local installed_version=""
      if [[ -f "${full_path}/composer.json" ]]; then
        installed_version=$(jq -r '.version // empty' "${full_path}/composer.json" 2>/dev/null || echo "")
      fi
      
      # If we couldn't get version from composer.json, try the .info.yml file
      if [[ -z "${installed_version}" ]]; then
        local info_file
        info_file=$(ls "${full_path}"/*.info.yml 2>/dev/null | head -1 || true)
        if [[ -n "${info_file}" && -f "${info_file}" ]]; then
          # Extract version from .info.yml (format: version: '1.2.3' or version: 1.2.3)
          installed_version=$(grep -E "^version:" "${info_file}" 2>/dev/null | sed "s/version:[[:space:]]*['\"]\\?\\([^'\"]*\\)['\"]\\?/\\1/" | tr -d ' ' || true)
        fi
      fi
      
      # Normalize versions for comparison:
      # - Remove 'v' prefix
      # - Convert Drupal 8.x-Y.Z format to Y.Z.0 (e.g., 8.x-1.6 -> 1.6.0)
      # - Add .0 patch version if missing (e.g., 1.6 -> 1.6.0)
      normalize_version() {
        local ver="$1"
        # Remove 'v' prefix
        ver="${ver#v}"
        # Convert 8.x-Y.Z or 9.x-Y.Z format to Y.Z (Drupal legacy versioning)
        if [[ "${ver}" =~ ^[0-9]+\.x-(.+)$ ]]; then
          ver="${BASH_REMATCH[1]}"
        fi
        # Add .0 if version has only major.minor (e.g., 1.6 -> 1.6.0)
        if [[ "${ver}" =~ ^[0-9]+\.[0-9]+$ ]]; then
          ver="${ver}.0"
        fi
        echo "${ver}"
      }
      
      local expected_normalized
      local installed_normalized
      expected_normalized=$(normalize_version "${expected_version}")
      installed_normalized=$(normalize_version "${installed_version}")
      
      if [[ -n "${installed_version}" && "${installed_normalized}" != "${expected_normalized}" ]]; then
        repair_reason="version mismatch (installed=${installed_version}, expected=${expected_version})"
        module_needs_repair=1
      fi
    fi
    
    # Secondary checks only if version check passed
    if [[ "${module_needs_repair}" -eq 0 ]]; then
      local dir_owner
      dir_owner="$(stat -c '%u:%g' "${full_path}" 2>/dev/null || stat -f '%u:%g' "${full_path}" 2>/dev/null || true)"

      # Check directory ownership
      if [[ -n "${dir_owner}" && "${dir_owner}" != "${www_uid}:${www_gid}" ]]; then
        repair_reason="incorrect directory ownership (${dir_owner} != ${www_uid}:${www_gid})"
        module_needs_repair=1
      # Check if any files inside have wrong ownership (critical for volume-mounted directories)
      elif find "${full_path}" -maxdepth 3 ! -user "${www_uid}" -print -quit 2>/dev/null | grep -q .; then
        repair_reason="files with incorrect ownership found inside module"
        module_needs_repair=1
      elif [[ ! -f "${full_path}/composer.json" ]]; then
        repair_reason="missing composer.json"
        module_needs_repair=1
      elif ! ls "${full_path}"/*.info.yml >/dev/null 2>&1; then
        repair_reason="missing .info.yml file"
        module_needs_repair=1
      elif ! find "${full_path}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
        repair_reason="empty directory"
        module_needs_repair=1
      fi
    fi
    
    if [[ "${module_needs_repair}" -eq 1 ]]; then
      log "Module ${module_name} needs repair: ${repair_reason}"
      modules_needing_repair+=("${module_name}:${full_path}")
    else
      log "Module ${module_name} looks healthy (version OK, ownership=${dir_owner:-unknown})."
    fi
  done < <(find "${contrib_dir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)

  # If no modules need repair, exit early
  if [[ ${#modules_needing_repair[@]} -eq 0 ]]; then
    log "All configured modules look healthy; skipping module repair."
    return 0
  fi

  log "Preparing to repair ${#modules_needing_repair[@]} composer-managed module(s)."

  # Remove problematic modules entirely (composer install will restore them)
  # Note: We use rm -rf instead of mv because moving across filesystems (EFS to local)
  # can fail partially, leaving empty directory structures that break composer install
  for module_entry in "${modules_needing_repair[@]}"; do
    local module_name="${module_entry%%:*}"
    local module_full_path="${module_entry#*:}"
    
    if [[ -d "${module_full_path}" ]]; then
      log "Removing ${module_full_path} for reinstall..."
      rm -rf "${module_full_path}" 2>/dev/null || {
        log "Could not remove ${module_full_path}; trying with find..."
        # Fallback: remove contents first, then directory (handles cross-filesystem edge cases)
        find "${module_full_path}" -mindepth 1 -delete 2>/dev/null || true
        rmdir "${module_full_path}" 2>/dev/null || true
      }
    fi
  done

  log "Running composer install to ensure module tree matches composer.lock..."
  cd "${project_root}" || return 0

  # Prevent the drupal/core-composer-scaffold plugin from (re)creating robots.txt
  # on this and every future composer install. Deleting the file after the fact is
  # a losing race because scaffolding runs on each install; disabling the mapping is
  # the durable fix. Setting the value to false tells scaffold to skip that path.
  log "Disabling robots.txt scaffolding via composer config..."
  gosu www-data composer config --json \
    'extra.drupal-scaffold.file-mapping.[web-root]/robots.txt' false \
    2>&1 || log "Could not set drupal-scaffold robots.txt mapping; continuing."

  # Run as www-data to keep permissions sane.
  # Note: We intentionally use install (not require) to avoid mutating composer.json/lock at runtime.
  gosu www-data composer install \
    --no-interaction \
    --no-progress \
    --optimize-autoloader \
    --prefer-dist \
    2>&1 || log "Composer install had issues; continuing."
}

# Clean up deprecated paths
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

# Harden permissions on mounted volumes for security
# Makes code read-only (root:www-data), directories 755, files 644
# Only sites/*/files remain writable by www-data
harden_mounted_volumes() {
  # Must be root to change ownership
  [[ "$(id -u)" -eq 0 ]] || return 0

  local project_root
  project_root="$(find_project_root)" || return 0

  log "Hardening mounted volume permissions..."

  # All code directories that should be locked down (root:www-data, read-only)
  # NOTE: drush directory excluded - it contains site aliases that may be mounted
  local code_paths=(
    "${project_root}/web/core"
    "${project_root}/web/modules"
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

  # Temp directory: root only, no web server access
  if [[ -d "${project_root}/temp" ]]; then
    log "Securing ${project_root}/temp (root:root, 700)..."
    chown -R root:root "${project_root}/temp" 2>/dev/null || true
    chmod -R 700 "${project_root}/temp" 2>/dev/null || true
  fi

  # Secure ALL .htaccess files across entire Drupal installation (644, root-owned)
  # These are critical security files that control access and block PHP execution
  log "Securing all .htaccess files (root:www-data, 644)..."
  find "${project_root}" -name ".htaccess" -exec chown root:www-data {} + 2>/dev/null || true
  find "${project_root}" -name ".htaccess" -exec chmod 644 {} + 2>/dev/null || true

  log "Volume hardening complete."
}

# Ensure correct permissions on sites directories
# First locks down entire sites/ (settings.php, etc.), then unlocks only */files
ensure_sites_files_permissions() {
  # Must be root to change ownership
  [[ "$(id -u)" -eq 0 ]] || return 0

  local project_root
  project_root="$(find_project_root)" || return 0

  local sites_base="${project_root}/web/sites"
  [[ -d "${sites_base}" ]] || return 0

  log "Locking down sites directory (root:www-data, 755)..."
  # First: lock down entire sites directory (settings.php, site configs, etc.)
  chown -R root:www-data "${sites_base}" 2>/dev/null || true
  chmod -R 755 "${sites_base}" 2>/dev/null || true

  log "Unlocking sites/*/files directories for uploads (www-data:www-data, 775)..."
  # Then: unlock only */files directories for web server uploads
  # Use glob to handle multisite - much faster than parsing sites.php
  for files_dir in "${sites_base}"/*/files; do
    [[ -d "${files_dir}" ]] || continue
    chown -R www-data:www-data "${files_dir}" 2>/dev/null || true
    chmod -R 775 "${files_dir}" 2>/dev/null || true
  done

  # Ensure default/files exists
  mkdir -p "${sites_base}/default/files"
  chown -R www-data:www-data "${sites_base}/default/files" 2>/dev/null || true
  chmod -R 775 "${sites_base}/default/files" 2>/dev/null || true

  log "Sites permissions configured."
}

# NOTE: ensure_runtime_ownership() removed for security
# Code should be root:www-data (read-only), not www-data:www-data (writable)
# Only sites/*/files directories should be writable by www-data

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

  # Clean up old version marker files to ensure fresh runs on upgrades
  rm -f /tmp/after-start-*.complete 2>/dev/null || true

  log "Starting after-start tasks for ${AFTER_START_VERSION}..."

  # 1. Repair composer-managed modules (one-time; runs composer install as www-data)
  #    Detects version mismatches against composer.lock, removes stale module
  #    directories, and runs `composer install` to restore the pinned versions.
  repair_composer_managed_modules

  # 2. Cleanup deprecated paths
  cleanup_deprecated_paths

  # 3. Harden permissions in background (non-blocking for large multisites)
  # 775 on files/ is fine - Apache serves JS/CSS/images as static, execute bit irrelevant
  # Real PHP security is .htaccess blocking execution in files/ directories
  (
    harden_mounted_volumes
    ensure_sites_files_permissions
    log "Background permission hardening complete."
  ) &

  # 4. Rebuild cache (runs as www-data via gosu)
  rebuild_cache

  # Mark complete
  touch "${MARKER_FILE}"
  log "After-start tasks for ${AFTER_START_VERSION} complete."
}

main "$@"
