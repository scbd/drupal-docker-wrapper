# Generic logic for applying Drupal patches at container start.
# shellcheck shell=bash

# Expects ROOT_CANDIDATES, log(), find_project_root() from common.sh

# Discovered patch file locations (populated at runtime).
# We intentionally ignore any files under a "patches/old" subdirectory.
PATCH_CANDIDATES=()

discover_patch_candidates() {
  PATCH_CANDIDATES=()

  local root
  for root in "${ROOT_CANDIDATES[@]}"; do
    local patches_dir="${root}/patches"
    if [[ ! -d "${patches_dir}" ]]; then
      continue
    fi

    # Find all .patch files, but skip anything under patches/old
    while IFS= read -r -d '' pf; do
      if [[ "${pf}" == *"/patches/old/"* ]]; then
        continue
      fi
      PATCH_CANDIDATES+=("${pf}")
    done < <(find "${patches_dir}" -type f -name "*.patch" -print0 2>/dev/null || true)
  done
}

# git is the only supported applier. It is strict, non-interactive, and behaves
# identically across platforms, so idempotency detection is reliable. patch(1)
# is deliberately not used as a fallback: it applies hunk-by-hunk, so a failure
# part-way through leaves the tree partially patched, and a permissive retry can
# then double-apply the hunks that already landed. The image installs git, so
# there is nothing to fall back to.
apply_patch() {
  local target_dir="$1"
  local patch_file="$2"

  local patch_basename
  patch_basename="$(basename "${patch_file}")"
  local marker_file="${target_dir}/.${patch_basename}.applied"

  if [[ -f "${marker_file}" ]]; then
    log "Patch already applied at ${target_dir} (marker ${marker_file} exists)."
    return 0
  fi

  if git -C "${target_dir}" apply --reverse --check -p1 "${patch_file}" >/dev/null 2>&1; then
    touch "${marker_file}"
    log "Patch ${patch_file} already present in ${target_dir} (git apply -R check)."
    return 0
  fi

  if git -C "${target_dir}" apply --check -p1 "${patch_file}" >/dev/null 2>&1; then
    git -C "${target_dir}" apply -p1 "${patch_file}"
    touch "${marker_file}"
    log "Patch ${patch_file} applied successfully to ${target_dir} (git apply -p1)."
    return 0
  fi

  log "Failed to apply patch ${patch_file} to ${target_dir}."
  return 1
}

# Quietly test whether a patch fits a target directory (already applied or
# applies cleanly with -p1). Used to pick the correct base dir for a patch
# whose paths are relative to a module/theme root rather than the Drupal root.
patch_fits_dir() {
  local dir="$1"
  local pf="$2"
  # Already applied (reverse applies) or applies cleanly forward.
  git -C "${dir}" apply --reverse --check -p1 "${pf}" >/dev/null 2>&1 && return 0
  git -C "${dir}" apply --check -p1 "${pf}" >/dev/null 2>&1 && return 0
  return 1
}

# Enumerate candidate base directories a patch could target: the Drupal project
# root (for core / docroot-relative patches) plus each contrib/custom module and
# theme (for composer-patches-style, module-root-relative patches).
patch_target_dirs() {
  local project_root="$1"
  echo "${project_root}"
  local sub
  for sub in web/modules/contrib web/modules/custom web/themes/contrib web/themes/custom; do
    [[ -d "${project_root}/${sub}" ]] || continue
    find "${project_root}/${sub}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true
  done
}

apply_patches_if_present() {
  discover_patch_candidates

  if [[ ${#PATCH_CANDIDATES[@]} -eq 0 ]]; then
    log "No patch files found; skipping patch application."
    return 0
  fi

  # Checked once, here, rather than per-patch: without git nothing below can
  # run, and a silent per-call skip would surface as "no target directory
  # matched" for every patch, which reads like a bad patch rather than a
  # broken image.
  if ! command -v git >/dev/null 2>&1; then
    log "git is not installed; cannot apply patches. Patches found: ${#PATCH_CANDIDATES[@]}."
    return 1
  fi

  local project_root
  if ! project_root="$(find_project_root)"; then
    log "No Drupal project root found; skipping patch application."
    return 0
  fi

  # Resolve candidate base directories once (root + every module/theme).
  local target_dirs=()
  local d
  while IFS= read -r d; do
    [[ -n "${d}" ]] && target_dirs+=("${d}")
  done < <(patch_target_dirs "${project_root}")

  local any_applied=0
  local pf
  for pf in "${PATCH_CANDIDATES[@]}"; do
    if [[ ! -f "${pf}" ]]; then
      continue
    fi

    # Find the one base dir this patch actually targets, then apply there.
    local matched=0
    for d in "${target_dirs[@]}"; do
      if patch_fits_dir "${d}" "${pf}"; then
        log "Attempting patch: target=${d}, patch=${pf}"
        if apply_patch "${d}" "${pf}"; then
          any_applied=1
        fi
        matched=1
        break
      fi
    done

    if [[ "${matched}" -eq 0 ]]; then
      log "No target directory matched patch ${pf}; skipping."
    fi
  done

  if [[ "${any_applied}" -eq 0 ]]; then
    log "No patches applied; all were either already present or found no matching target."
  fi
}
