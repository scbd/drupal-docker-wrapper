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
  project_root="$(find_project_root)" || {
    log "Could not locate the project root; skipping deprecated-path cleanup."
    return 0
  }

  local web_root="${project_root}/web"
  local paths=(
    "robots.txt"
  )

  local rel
  for rel in "${paths[@]}"; do
    local target="${web_root}/${rel}"
    # rm -f, not rm -rf: every entry above is a regular file, and a recursive
    # delete driven by an array is the shape ADR 0005 exists to keep out of the
    # runtime. A future entry that genuinely needs a directory gets its own
    # explicitly guarded branch.
    if [[ -f "${target}" ]]; then
      log "Removing deprecated file ${target}"
      rm -f "${target}" || log "Failed to remove ${target}; continuing."
    fi
  done
}

# Harden permissions on the code that ships in the image
# Makes code read-only (root:www-data), directories 755, files 644
# EFS bind mounts (php/custom.ini, modules/custom, sites, drush, temp) are never
# touched here; their permissions are owned by the deploy that mounts them.
harden_image_code() {
  # Must be root to change ownership
  [[ "$(id -u)" -eq 0 ]] || {
    log "Not running as root (uid $(id -u)); skipping image code hardening."
    return 0
  }

  local project_root
  project_root="$(find_project_root)" || {
    log "Could not locate the project root; skipping image code hardening."
    return 0
  }

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

  # Failures stay non-fatal - a half-hardened tree must never stop the container
  # serving - but they are counted and reported. Silently swallowing them would
  # make "code is still www-data-writable" look identical to a clean run, which
  # is the one outcome worth knowing about.
  local code_path
  local failed_paths=0
  for code_path in "${code_paths[@]}"; do
    if [[ -d "${code_path}" ]]; then
      log "Securing ${code_path} (root:www-data, dirs=755, files=644)..."
      local failed=0
      chown -R root:www-data "${code_path}" || failed=1
      # Directories: 755 (rwxr-xr-x) - need execute for traversal
      find "${code_path}" -type d -exec chmod 755 {} + || failed=1
      # Files: 644 (rw-r--r--) - no execute bit
      find "${code_path}" -type f -exec chmod 644 {} + || failed=1
      if (( failed )); then
        log "WARNING: hardening ${code_path} reported errors; continuing."
        failed_paths=$(( failed_paths + 1 ))
      fi
    fi
  done

  # The files pass above stripped the execute bit from every real CLI target
  # under vendor/, so restore it on vendor/bin and on whatever each entry points
  # at. Composer writes these as symlinks on Linux today, but it can emit proxy
  # files instead; deriving the target covers both, where a hard-coded tool list
  # (drush, phpunit, ...) goes stale the moment a dependency is added.
  if [[ -d "${project_root}/vendor/bin" ]]; then
    log "Restoring execute permissions on vendor/bin..."
    local entry target
    for entry in "${project_root}/vendor/bin"/*; do
      [[ -e "${entry}" ]] || continue
      chmod 755 "${entry}" || log "WARNING: could not chmod ${entry}; continuing."
      if [[ -L "${entry}" ]]; then
        target="$(readlink -f "${entry}" 2>/dev/null)" || continue
        if [[ -f "${target}" ]]; then
          chmod 755 "${target}" || log "WARNING: could not chmod ${target}; continuing."
        fi
      fi
    done
  fi

  # Root-level web files (index.php, update.php, etc.)
  log "Securing root-level web files (root:www-data, 644)..."
  find "${project_root}/web" -maxdepth 1 -type f -exec chown root:www-data {} + \
    || log "WARNING: chown of root-level web files reported errors; continuing."
  find "${project_root}/web" -maxdepth 1 -type f -exec chmod 644 {} + \
    || log "WARNING: chmod of root-level web files reported errors; continuing."

  # No blanket .htaccess pass here. Finding them meant walking every directory
  # under the project root, including the EFS-backed sites/ tree and its upload
  # directories, on every container start. The .htaccess files that this pass
  # actually protected durably are already covered: the ones inside the code
  # paths above by their own `-type f` chmod, and web/.htaccess by the
  # root-level pass above. Per-site .htaccess hardening is handled by an
  # external script that traverses each site. See adr/0008.

  if (( failed_paths )); then
    log "Image code hardening complete with ${failed_paths} path(s) reporting errors."
  else
    log "Image code hardening complete."
  fi
}

main() {
  log "Starting after-start tasks..."

  # 1. Cleanup deprecated paths (acts on the image's web root)
  cleanup_deprecated_paths

  # 2. Harden image code permissions. Runs in the FOREGROUND: this script is
  # already forked by entrypoint.sh, which captures its exit status so a failed
  # run is distinguishable from a slow one. Forking again would report success
  # before the work happened, and would orphan a subshell onto Apache as PID 1.
  #
  # Nothing here touches an EFS bind mount (php/custom.ini, modules/custom,
  # sites, drush, temp), so there is no version marker and no gating: the pass
  # only ever walks paths that ship in the image and is cheap to repeat.
  harden_image_code

  log "After-start tasks complete."
}

main "$@"
