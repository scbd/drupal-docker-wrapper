# Generic logic for applying Drupal patches at container start.
# shellcheck shell=bash
#
# Patches are applied with `git apply -p1` only. Strip level -p0 is not
# supported: drupal.org and composer-patches files are -p1, and probing both
# doubles the boot-time cost for a format we do not ship.
#
# Expects ROOT_CANDIDATES, log(), find_project_root() from common.sh

# Discovered patch file locations (populated at runtime).
# We intentionally ignore any files under a "patches/old" subdirectory.
PATCH_CANDIDATES=()

# A patch is root-executed input: it is applied as root, before Apache starts.
# Only accept files this user owns and that nobody else can write, so a patch
# dropped by a less-privileged process is never applied.
patch_file_is_trusted() {
  local pf="$1"
  if [[ ! -O "${pf}" ]]; then
    log "Refusing patch ${pf}: not owned by the current user."
    return 1
  fi

  # POSIX symbolic modes, not GNU's /022: BSD find rejects /022 as an illegal
  # mode string, and since it still exits 0 the test would silently pass and
  # accept the very file it exists to refuse. Capture stderr and refuse on any
  # noise so an unsupported find fails closed rather than open.
  local out
  out="$(find "${pf}" -maxdepth 0 \( -perm -g+w -o -perm -o+w \) -print 2>&1)"
  if [[ -n "${out}" ]]; then
    log "Refusing patch ${pf}: group- or world-writable, or its permissions could not be read."
    return 1
  fi
  return 0
}

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
      patch_file_is_trusted "${pf}" || continue
      PATCH_CANDIDATES+=("${pf}")
    done < <(find "${patches_dir}" -type f -name "*.patch" -print0 2>/dev/null || true)
  done
}

# True when every file section in the patch creates a new file. Such a patch
# applies cleanly to any directory that happens not to contain those paths, so
# probing cannot tell the intended target from an unrelated one -- including the
# project root, which would drop the new file straight into the docroot.
patch_is_all_new_files() {
  local pf="$1"
  ! grep -qE '^--- (a/|[^/])' "${pf}"
}

# git is the only supported applier. patch(1) applies hunk-by-hunk, so a failure
# part-way through leaves the tree partially patched, and a permissive --fuzz
# retry can then re-apply the hunks that already landed. git apply is atomic.
apply_patch() {
  local target_dir="$1"
  local patch_file="$2"

  if git -C "${target_dir}" apply --reverse --check -p1 "${patch_file}" >/dev/null 2>&1; then
    log "Patch ${patch_file} already present in ${target_dir}."
    return 0
  fi

  if ! git -C "${target_dir}" apply --check -p1 "${patch_file}" >/dev/null 2>&1; then
    log "Patch ${patch_file} does not apply to ${target_dir}."
    return 1
  fi

  git -C "${target_dir}" apply -p1 "${patch_file}"

  # Verify by content rather than by exit status. Inside a git work tree
  # `git apply` can skip a rejected path and still exit 0, and an apply that
  # dies part-way (read-only mount, ENOSPC) must not be logged as success.
  if ! git -C "${target_dir}" apply --reverse --check -p1 "${patch_file}" >/dev/null 2>&1; then
    log "ERROR: patch ${patch_file} passed --check but is not present in ${target_dir} afterwards; the tree may be partially modified."
    return 1
  fi

  log "Patch ${patch_file} applied successfully to ${target_dir}."
  return 0
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

# Enumerate candidate base directories a patch could target: each contrib/custom
# module and theme (for composer-patches-style, module-root-relative patches),
# then the Drupal project root (for core / docroot-relative patches). Most
# specific first, so a module patch can never bind to the project root instead.
patch_target_dirs() {
  local project_root="$1"
  local sub
  for sub in web/modules/contrib web/modules/custom web/themes/contrib web/themes/custom; do
    [[ -d "${project_root}/${sub}" ]] || continue
    # -L so a symlinked module directory (composer path repo, mount
    # indirection) is enumerated rather than silently skipped.
    find -L "${project_root}/${sub}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true
  done
  echo "${project_root}"
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
    log "ERROR: git is not installed; cannot apply patches. Patches found: ${#PATCH_CANDIDATES[@]}."
    return 1
  fi

  local project_root
  if ! project_root="$(find_project_root)"; then
    log "No Drupal project root found; skipping patch application."
    return 0
  fi

  # Resolve candidate base directories once (every module/theme, then root).
  local target_dirs=()
  local d
  while IFS= read -r d; do
    [[ -n "${d}" ]] && target_dirs+=("${d}")
  done < <(patch_target_dirs "${project_root}")

  local failed=0
  local pf
  for pf in "${PATCH_CANDIDATES[@]}"; do
    if [[ ! -f "${pf}" ]]; then
      continue
    fi

    if patch_is_all_new_files "${pf}"; then
      log "ERROR: patch ${pf} only creates new files, so its target cannot be identified; skipping."
      failed=1
      continue
    fi

    # Apply to every directory the patch fits, not just the first: a module can
    # exist in more than one place (contrib plus a vendored custom copy), and
    # patching only one leaves the other live and unpatched.
    local matched=0
    for d in "${target_dirs[@]}"; do
      if patch_fits_dir "${d}" "${pf}"; then
        matched=$((matched + 1))
        apply_patch "${d}" "${pf}" || failed=1
      fi
    done

    if [[ "${matched}" -eq 0 ]]; then
      log "No target directory matched patch ${pf}; skipping."
    elif [[ "${matched}" -gt 1 ]]; then
      log "Patch ${pf} matched ${matched} directories; all were patched."
    fi
  done

  # Report failures to the caller. The entrypoint keeps this non-fatal, but a
  # patch that did not land must not share an exit status with one that did.
  if [[ "${failed}" -ne 0 ]]; then
    log "ERROR: one or more patches failed to apply."
    return 1
  fi
}
