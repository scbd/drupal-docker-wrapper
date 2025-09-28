#!/usr/bin/env bash
set -euo pipefail

# This script ensures the jsonapi_extras patch is applied at container start.
# It applies the unified diff against the vendor source if the hunks are not present yet.

# Candidate roots where the Drupal project may live
ROOT_CANDIDATES=("/opt/drupal" "/var/www/html")
# Candidate patch file locations
PATCH_CANDIDATES=(
  "/opt/drupal/patches/jsonapi_extras--2025-06-30--3452036--mr-51.patch"
  "/var/www/html/patches/jsonapi_extras--2025-06-30--3452036--mr-51.patch"
)

log() { echo "[entrypoint] $*"; }

apply_patch() {
  local target_dir="$1"
  local patch_file="$2"
  local marker_file="${target_dir}/.patch-3452036-applied"

  if [[ -f "$marker_file" ]]; then
    log "Patch already applied at $target_dir (marker exists)."
    return 0
  fi

  # If the patch can be reversed cleanly, it is already applied
  if patch -p1 -R --dry-run -d "$target_dir" < "$patch_file" >/dev/null 2>&1; then
    touch "$marker_file"
    log "Patch already present in $target_dir (reverse dry-run succeeded)."
    return 0
  fi

  if patch -p1 --dry-run -d "$target_dir" < "$patch_file" >/dev/null 2>&1; then
    patch -p1 -d "$target_dir" < "$patch_file"
    touch "$marker_file"
    log "Patch applied successfully to $target_dir."
    return 0
  fi

  # Retry with whitespace and fuzz options
  if patch -p1 -l --fuzz=3 --dry-run -d "$target_dir" < "$patch_file" >/dev/null 2>&1; then
    patch -p1 -l --fuzz=3 -d "$target_dir" < "$patch_file"
    touch "$marker_file"
    log "Patch applied successfully with -p1 -l --fuzz=3 to $target_dir."
    return 0
  fi

  # Try with different strip level
  if patch -p0 --dry-run -d "$target_dir" < "$patch_file" >/dev/null 2>&1; then
    patch -p0 -d "$target_dir" < "$patch_file"
    touch "$marker_file"
    log "Patch applied successfully with -p0 to $target_dir."
    return 0
  fi

  if patch -p0 -l --fuzz=3 --dry-run -d "$target_dir" < "$patch_file" >/dev/null 2>&1; then
    patch -p0 -l --fuzz=3 -d "$target_dir" < "$patch_file"
    touch "$marker_file"
    log "Patch applied successfully with -p0 -l --fuzz=3 to $target_dir."
    return 0
  fi

  log "Dry-run failed for $target_dir with $patch_file; attempting composer update drupal/jsonapi_extras."
  if command -v composer >/dev/null 2>&1; then
    composer config --no-plugins allow-plugins.cweagans/composer-patches true || true
    COMPOSER_ALLOW_SUPERUSER=1 composer update drupal/jsonapi_extras -W -n -q || true
    if patch -p1 --dry-run -d "$target_dir" < "$patch_file" >/dev/null 2>&1; then
      patch -p1 -d "$target_dir" < "$patch_file"
      touch "$marker_file"
      log "Patch applied successfully after composer update to $target_dir."
      return 0
    fi
  else
    log "Composer not found; cannot attempt dependency re-resolve."
  fi

  log "Failed to apply patch to $target_dir."
  return 1
}

found=0
for root in "${ROOT_CANDIDATES[@]}"; do
  module_dir="$root/web/modules/contrib/jsonapi_extras"
  if [[ -d "$module_dir" ]]; then
    for pf in "${PATCH_CANDIDATES[@]}"; do
      if [[ -f "$pf" ]]; then
        log "Attempting patch: module=$module_dir, patch=$pf"
        if apply_patch "$module_dir" "$pf"; then
          found=1
          break
        fi
      fi
    done
  fi
  if [[ "$found" -eq 1 ]]; then break; fi
done

if [[ "$found" -eq 0 ]]; then
  log "Patch or module directory not found; skipping. Checked roots: ${ROOT_CANDIDATES[*]}"
fi

# If a Drupal site is present, attempt a non-fatal cache rebuild to avoid stale container.
for root in "${ROOT_CANDIDATES[@]}"; do
  if [[ -f "$root/web/sites/default/settings.php" ]]; then
    log "Detected Drupal settings at $root; attempting cache:rebuild (non-fatal)."
    if command -v php >/dev/null 2>&1; then
      # Try Drush if available, otherwise use Drupal's rebuild.php if present.
      if command -v /opt/drupal/vendor/bin/drush >/dev/null 2>&1; then
        /opt/drupal/vendor/bin/drush -r "$root/web" cache:rebuild || log "drush cr failed; continuing."
      elif [[ -f "$root/web/core/rebuild.php" ]]; then
        php "$root/web/core/rebuild.php" || log "core rebuild.php failed; continuing."
      fi
    fi
    break
  fi
done

# Chain to the upstream Drupal entrypoint if present
if [[ -x /usr/local/bin/docker-entrypoint ]]; then
  exec /usr/local/bin/docker-entrypoint "$@"
else
  exec "$@"
fi
