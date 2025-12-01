# Generic logic for applying Drupal patches at container start.
# shellcheck shell=bash

# Expects ROOT_CANDIDATES, PATCH_CANDIDATES, discover_patch_candidates, and
# log() from entrypoint-common.sh

apply_patch() {
  local target_dir="$1"
  local patch_file="$2"

  # Use a marker file derived from the patch filename so multiple patches can
  # be tracked independently.
  local patch_basename
  patch_basename="$(basename "${patch_file}")"
  local marker_file="${target_dir}/.${patch_basename}.applied"

  if [[ -f "${marker_file}" ]]; then
    log "Patch already applied at ${target_dir} (marker ${marker_file} exists)."
    return 0
  fi

  # If the patch can be reversed cleanly, it is already applied.
  if patch -p1 -R --dry-run -d "${target_dir}" < "${patch_file}" >/dev/null 2>&1; then
    touch "${marker_file}"
    log "Patch ${patch_file} already present in ${target_dir} (reverse dry-run succeeded)."
    return 0
  fi

  # Try a series of increasingly permissive strategies.
  if patch -p1 --dry-run -d "${target_dir}" < "${patch_file}" >/dev/null 2>&1; then
    patch -p1 -d "${target_dir}" < "${patch_file}"
    touch "${marker_file}"
    log "Patch ${patch_file} applied successfully to ${target_dir} with -p1."
    return 0
  fi

  if patch -p1 -l --fuzz=3 --dry-run -d "${target_dir}" < "${patch_file}" >/dev/null 2>&1; then
    patch -p1 -l --fuzz=3 -d "${target_dir}" < "${patch_file}"
    touch "${marker_file}"
    log "Patch ${patch_file} applied successfully to ${target_dir} with -p1 -l --fuzz=3."
    return 0
  fi

  if patch -p0 --dry-run -d "${target_dir}" < "${patch_file}" >/dev/null 2>&1; then
    patch -p0 -d "${target_dir}" < "${patch_file}"
    touch "${marker_file}"
    log "Patch ${patch_file} applied successfully to ${target_dir} with -p0."
    return 0
  fi

  if patch -p0 -l --fuzz=3 --dry-run -d "${target_dir}" < "${patch_file}" >/dev/null 2>&1; then
    patch -p0 -l --fuzz=3 -d "${target_dir}" < "${patch_file}"
    touch "${marker_file}"
    log "Patch ${patch_file} applied successfully to ${target_dir} with -p0 -l --fuzz=3."
    return 0
  fi

  log "Failed to apply patch ${patch_file} to ${target_dir}."
  return 1
}

entrypoint_apply_patches_if_present() {
  # Refresh the list of available patches
  discover_patch_candidates

  if [[ ${#PATCH_CANDIDATES[@]} -eq 0 ]]; then
    log "No patch files found; skipping patch application."
    return 0
  fi

  local project_root
  if ! project_root="$(find_project_root)"; then
    log "No Drupal project root found; skipping patch application."
    return 0
  fi

  local any_applied=0
  local pf
  for pf in "${PATCH_CANDIDATES[@]}"; do
    if [[ ! -f "${pf}" ]]; then
      continue
    fi
    log "Attempting patch: root=${project_root}, patch=${pf}"
    if apply_patch "${project_root}" "${pf}"; then
      any_applied=1
    fi
  done

  if [[ "${any_applied}" -eq 0 ]]; then
    log "No patches applied; all were either already present or failed dry-run checks."
  fi
}
