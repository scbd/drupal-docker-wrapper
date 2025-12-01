# Logic for applying the jsonapi_extras patch at container start.
# shellcheck shell=bash

# Expects ROOT_CANDIDATES, PATCH_CANDIDATES, and log() from entrypoint-common.sh

apply_patch() {
  local target_dir="$1"
  local patch_file="$2"
  local marker_file="${target_dir}/.patch-3452036-applied"

  if [[ -f "${marker_file}" ]]; then
    log "Patch already applied at ${target_dir} (marker exists)."
    return 0
  fi

  # If the patch can be reversed cleanly, it is already applied
  if patch -p1 -R --dry-run -d "${target_dir}" < "${patch_file}" >/dev/null 2>&1; then
    touch "${marker_file}"
    log "Patch already present in ${target_dir} (reverse dry-run succeeded)."
    return 0
  fi

  if patch -p1 --dry-run -d "${target_dir}" < "${patch_file}" >/dev/null 2>&1; then
    patch -p1 -d "${target_dir}" < "${patch_file}"
    touch "${marker_file}"
    log "Patch applied successfully to ${target_dir}."
    return 0
  fi

  # Retry with whitespace and fuzz options
  if patch -p1 -l --fuzz=3 --dry-run -d "${target_dir}" < "${patch_file}" >/dev/null 2>&1; then
    patch -p1 -l --fuzz=3 -d "${target_dir}" < "${patch_file}"
    touch "${marker_file}"
    log "Patch applied successfully with -p1 -l --fuzz=3 to ${target_dir}."
    return 0
  fi

  # Try with different strip level
  if patch -p0 --dry-run -d "${target_dir}" < "${patch_file}" >/dev/null 2>&1; then
    patch -p0 -d "${target_dir}" < "${patch_file}"
    touch "${marker_file}"
    log "Patch applied successfully with -p0 to ${target_dir}."
    return 0
  fi

  if patch -p0 -l --fuzz=3 --dry-run -d "${target_dir}" < "${patch_file}" >/dev/null 2>&1; then
    patch -p0 -l --fuzz=3 -d "${target_dir}" < "${patch_file}"
    touch "${marker_file}"
    log "Patch applied successfully with -p0 -l --fuzz=3 to ${target_dir}."
    return 0
  fi

  log "Dry-run failed for ${target_dir} with ${patch_file}; attempting composer update drupal/jsonapi_extras."
  if command -v composer >/dev/null 2>&1; then
    composer config --no-plugins allow-plugins.cweagans/composer-patches true || true
    COMPOSER_ALLOW_SUPERUSER=1 composer update drupal/jsonapi_extras -W -n -q || true
    if patch -p1 --dry-run -d "${target_dir}" < "${patch_file}" >/dev/null 2>&1; then
      patch -p1 -d "${target_dir}" < "${patch_file}"
      touch "${marker_file}"
      log "Patch applied successfully after composer update to ${target_dir}."
      return 0
    fi
  else
    log "Composer not found; cannot attempt dependency re-resolve."
  fi

  log "Failed to apply patch to ${target_dir}."
  return 1
}

entrypoint_run_jsonapi_extras_patch() {
  local patch_exists=0
  local pf

  # Check if any patch files exist before attempting to apply
  for pf in "${PATCH_CANDIDATES[@]}"; do
    if [[ -f "${pf}" ]]; then
      patch_exists=1
      break
    fi
  done

  if [[ "${patch_exists}" -eq 0 ]]; then
    log "No patch files found; skipping patch application."
    return 0
  fi

  local found=0
  local root
  for root in "${ROOT_CANDIDATES[@]}"; do
    local module_dir="${root}/web/modules/contrib/jsonapi_extras"
    if [[ -d "${module_dir}" ]]; then
      for pf in "${PATCH_CANDIDATES[@]}"; do
        if [[ -f "${pf}" ]]; then
          log "Attempting patch: module=${module_dir}, patch=${pf}"
          if apply_patch "${module_dir}" "${pf}"; then
            found=1
            break
          fi
        fi
      done
    fi
    if [[ "${found}" -eq 1 ]]; then
      break
    fi
  done

  if [[ "${found}" -eq 0 ]]; then
    log "Patch or module directory not found; skipping. Checked roots: ${ROOT_CANDIDATES[*]}"
  fi
}
