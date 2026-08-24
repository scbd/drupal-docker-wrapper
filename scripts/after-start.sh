#!/usr/bin/env bash
set -euo pipefail

# After-start script: runs once the web server answers (see entrypoint.sh)
# Handles deprecated-path cleanup and permission hardening
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

# Version tag for this release (used only to gate one-time startup tasks).
# read_wrapper_version lives in lib/common.sh so the entrypoint and this script
# derive the gate from one implementation.
AFTER_START_VERSION="$(read_wrapper_version)"

# Where the completion marker lives. Prefer the bind-mounted temp/ directory:
# /tmp sits in the container's writable layer, so every redeploy and every
# scale-out saw a fresh /tmp and re-ran the recursive pass over the EFS-backed
# sites/ tree. temp/ is mounted from EFS, so the gate becomes once per wrapper
# version per volume, which is what it was always meant to mean.
#
# Falls back to /tmp when temp/ is absent. The image does not create it, so its
# presence is a reliable signal that the volume is actually mounted.
resolve_marker_dir() {
  local project_root
  if project_root="$(find_project_root)" && [[ -d "${project_root}/temp" ]]; then
    printf '%s\n' "${project_root}/temp"
  else
    printf '%s\n' /tmp
  fi
}
MARKER_DIR="$(resolve_marker_dir)"
MARKER_FILE="${MARKER_DIR}/after-start-${AFTER_START_VERSION}.complete"

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
# Locks down all of sites/ (dirs 755, files 644), tightens settings/services
# files to 440, then unlocks only */files for uploads
ensure_sites_files_permissions() {
  # Must be root to change ownership
  [[ "$(id -u)" -eq 0 ]] || return 0

  local project_root
  project_root="$(find_project_root)" || return 0

  local sites_base="${project_root}/web/sites"
  [[ -d "${sites_base}" ]] || return 0

  log "Locking down sites directory (root:www-data, dirs=755, files=644)..."
  # First: lock down entire sites directory (settings.php, site configs, etc.)
  chown -R root:www-data "${sites_base}" 2>/dev/null || true
  # Directories need the execute bit for traversal; files must not have it. A
  # blanket `chmod -R 755` here left settings.php world-readable and
  # world-executable, exposing the database credentials and the hash salt.
  find "${sites_base}" -type d -exec chmod 755 {} + 2>/dev/null || true
  find "${sites_base}" -type f -exec chmod 644 {} + 2>/dev/null || true

  # Credentials are readable by root and the web server group only.
  log "Restricting settings and services files (root:www-data, 440)..."
  find "${sites_base}" -type f \
    \( -name 'settings*.php' -o -name 'services*.yml' \) \
    -exec chmod 440 {} + 2>/dev/null || true

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

main() {
  # The marker gates only the work that lands on a mounted volume and therefore
  # survives the container that did it. Everything else runs on every start.
  #
  # This is deliberately not a blanket gate. harden_mounted_volumes fixes
  # ownership on web/core, web/themes, web/profiles, web/libraries and vendor,
  # which live in the image, and the build leaves them owned by www-data
  # (Dockerfile: chown -R www-data:www-data /opt/drupal). A fresh container
  # therefore starts with its code writable by the web server. Skipping that on
  # the strength of a persisted marker would leave every container after the
  # first un-hardened, so it stays ungated.
  local skip_volume_work=0
  if [[ -f "${MARKER_FILE}" ]]; then
    log "Volume-backed work for ${AFTER_START_VERSION} already done on this volume; skipping it."
    skip_volume_work=1
  else
    # Purge markers from other versions so an upgrade re-runs. Both locations are
    # swept: a container that ran a pre-move wrapper left its marker in /tmp.
    rm -f "${MARKER_DIR}"/after-start-*.complete 2>/dev/null || true
    if [[ "${MARKER_DIR}" != "/tmp" ]]; then
      rm -f /tmp/after-start-*.complete 2>/dev/null || true
    fi
  fi

  log "Starting after-start tasks for ${AFTER_START_VERSION}..."

  # 1. Cleanup deprecated paths (acts on the image's web root; every start)
  cleanup_deprecated_paths

  # 2. Harden permissions in background (non-blocking for large multisites)
  # 775 on files/ is fine - Apache serves JS/CSS/images as static, execute bit irrelevant
  # Real PHP security is .htaccess blocking execution in files/ directories
  #
  # The marker is written from inside this subshell, after the gated pass
  # returns. Writing it in the foreground would record the work as finished
  # while the recursive walk was still running, and a container killed in that
  # window would leave a marker for work that never completed.
  (
    harden_mounted_volumes
    if (( skip_volume_work == 0 )); then
      ensure_sites_files_permissions
      touch "${MARKER_FILE}" 2>/dev/null \
        || log "WARNING: could not write ${MARKER_FILE}; volume work re-runs next start."
    fi
    log "Background permission hardening complete."
  ) &

  log "After-start tasks for ${AFTER_START_VERSION} dispatched."
}

main "$@"
