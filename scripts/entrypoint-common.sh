# Shared helpers for Drupal entrypoint scripts.
# shellcheck shell=bash

# Candidate roots where the Drupal project may live
ROOT_CANDIDATES=("/opt/drupal" "/var/www/html")

# Discovered patch file locations (populated at runtime).
#
# We intentionally ignore any files under a "patches/old" subdirectory so
# deprecated patches can remain in the repo without being applied.
PATCH_CANDIDATES=()

discover_patch_candidates() {
  PATCH_CANDIDATES=()

  local root
  for root in "${ROOT_CANDIDATES[@]}"; do
    local patches_dir="${root}/patches"
    if [[ ! -d "${patches_dir}" ]]; then
      continue
    fi

    # Find all .patch files directly under patches/ (and any non-old
    # subdirectories, just in case), but skip anything under patches/old.
    while IFS= read -r -d '' pf; do
      if [[ "${pf}" == *"/patches/old/"* ]]; then
        continue
      fi
      PATCH_CANDIDATES+=("${pf}")
    done < <(find "${patches_dir}" -type f -name "*.patch" -print0 2>/dev/null || true)
  done
}

log() {
  echo "[entrypoint] $*"
}

find_project_root() {
  for root in "${ROOT_CANDIDATES[@]}"; do
    if [[ -d "${root}/web" ]]; then
      echo "${root}"
      return 0
    fi
  done
  return 1
}
