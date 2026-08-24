#!/usr/bin/env bash
set -euo pipefail

# After-start tasks. Forked by entrypoint.sh once the web server answers, so
# heavy work never delays the container starting to serve.
#
# This file currently carries module repair only: it compares the contrib tree
# against composer.lock and restores anything stale or structurally broken.
# Permission hardening and cache rebuild land separately.
#
# OPT-IN. This routine moves and reinstalls module directories on a live site,
# and earlier revisions of it caused two reproducible mass-deletion incidents.
# It therefore does nothing unless DRUPAL_ENABLE_MODULE_REPAIR=1 is set, and
# DRUPAL_AFTER_START_DRY_RUN=1 reports every decision without touching a file.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

# Consumed by log() in lib/common.sh.
# shellcheck disable=SC2034
LOG_PREFIX="after-start"

QUARANTINE_NAME=".after-start-quarantine"
DRY_RUN="${DRUPAL_AFTER_START_DRY_RUN:-0}"

# --- version handling -------------------------------------------------------

# Normalize a version for comparison: strip a leading "v", convert Drupal
# legacy "8.x-1.6" to "1.6", then pad to three components so "1.6" and "1.6.0"
# compare equal.
normalize_version() {
  local ver="${1:-}"
  ver="${ver#v}"
  if [[ "${ver}" =~ ^[0-9]+\.x-(.+)$ ]]; then
    ver="${BASH_REMATCH[1]}"
  fi
  ver="${ver%%+*}"
  case "$(tr -cd '.' <<<"${ver}" | wc -c | tr -d ' ')" in
    0) ver="${ver}.0.0" ;;
    1) ver="${ver}.0" ;;
  esac
  echo "${ver}"
}

# True only for a plain numeric dotted version that can be compared literally.
#
# Dev branches ("3.x-dev", "dev-3.x") and pre-releases ("1.0.0-rc1") cannot be:
# composer.lock records one form while the module on disk reports another, so a
# string comparison reports a mismatch that is not real. This image pins several
# modules exactly that way, and a false mismatch here means a module is moved
# and reinstalled on every fresh image version.
#
# Pre-release suffixes are deliberately NOT stripped to force comparability:
# that would make "1.0.0-rc1" and "1.0.0" compare equal and hide a genuine
# upgrade. Refusing to judge is the safe answer - a module wrongly judged
# healthy costs nothing, a module wrongly judged stale gets moved.
is_comparable_version() {
  [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)*$ ]]
}

# Expected version of drupal/<module> per composer.lock, or empty.
# Reads packages-dev too, so a dev-only module is not misreported as absent.
expected_module_version() {
  local composer_lock="$1" module_name="$2"
  jq -r --arg name "drupal/${module_name}" \
    '((.packages // []) + (."packages-dev" // []))[] | select(.name == $name) | .version' \
    "${composer_lock}" 2>/dev/null || echo ""
}

# Version actually installed, most authoritative source first.
#
# vendor/composer/installed.json is what composer itself believes and is the
# only record it maintains. A module's own composer.json "version" is NOT
# written by composer - it is whatever the maintainer hard-coded, and it is
# routinely stale, so trusting it turns a stale field into a permanent
# mismatch. .info.yml is rewritten by drupal.org packaging on every release and
# is a reliable second choice.
installed_module_version() {
  local project_root="$1" module_path="$2" module_name="$3"
  local version="" installed_json="${project_root}/vendor/composer/installed.json"

  if [[ -f "${installed_json}" ]]; then
    version="$(jq -r --arg name "drupal/${module_name}" \
      '((.packages // .) // [])[]? | select(.name == $name) | .version // empty' \
      "${installed_json}" 2>/dev/null | head -1 || echo "")"
  fi

  if [[ -z "${version}" ]]; then
    local info_file="${module_path}/${module_name}.info.yml"
    if [[ ! -f "${info_file}" ]]; then
      info_file="$(find "${module_path}" -maxdepth 1 -name '*.info.yml' -print -quit 2>/dev/null || true)"
    fi
    if [[ -n "${info_file}" && -f "${info_file}" ]]; then
      version="$(sed -n "s/^version:[[:space:]]*['\"]\?\([^'\"]*\)['\"]\?[[:space:]]*$/\1/p" \
        "${info_file}" 2>/dev/null | head -1 | tr -d ' ' || true)"
    fi
  fi

  echo "${version}"
}

# --- repair decision --------------------------------------------------------

# Decide whether one module directory needs repair, echoing the reason.
#
# Deliberately does NOT inspect ownership. An ownership heuristic cannot be
# reconciled with permission hardening (which intentionally leaves code owned
# root:www-data, not www-data:www-data): the two disagree about what "correct"
# means, so every hardened tree looks broken on the next boot and gets moved
# and reinstalled. Version and structural integrity are the checks that
# actually indicate a stale or corrupt module.
module_repair_reason() {
  local project_root="$1" module_path="$2" module_name="$3" composer_lock="$4"

  local expected installed exp_n ins_n
  expected="$(expected_module_version "${composer_lock}" "${module_name}")"
  if [[ -n "${expected}" ]]; then
    installed="$(installed_module_version "${project_root}" "${module_path}" "${module_name}")"
    if [[ -n "${installed}" ]]; then
      exp_n="$(normalize_version "${expected}")"
      ins_n="$(normalize_version "${installed}")"
      if is_comparable_version "${exp_n}" && is_comparable_version "${ins_n}"; then
        if [[ "${exp_n}" != "${ins_n}" ]]; then
          echo "version mismatch (installed=${installed}, expected=${expected})"
          return 0
        fi
      fi
    fi
  fi

  if [[ ! -f "${module_path}/composer.json" ]]; then
    echo "missing composer.json"
    return 0
  fi
  if [[ -z "$(find "${module_path}" -maxdepth 1 -name '*.info.yml' -print -quit 2>/dev/null)" ]]; then
    echo "missing .info.yml"
    return 0
  fi
  if [[ -z "$(find "${module_path}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    echo "empty directory"
    return 0
  fi

  return 1
}

# --- quarantine -------------------------------------------------------------

# Move anything left in a previous run's quarantine back into place.
#
# The quarantine path is FIXED, not mktemp'd, precisely so this can happen: if
# the container is killed between the move and the reinstall, a random-named
# directory would strand the modules where nothing could ever find them, and
# the site would stay broken until a human went looking.
recover_orphaned_quarantine() {
  local project_root="$1" contrib_dir="$2"
  local quarantine="${project_root}/${QUARANTINE_NAME}"

  [[ -d "${quarantine}" ]] || return 0

  local entry module_name recovered=0
  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    module_name="$(basename "${entry}")"
    if [[ ! -e "${contrib_dir}/${module_name}" ]]; then
      if mv "${entry}" "${contrib_dir}/${module_name}" 2>/dev/null; then
        log "Recovered ${module_name} from an interrupted previous run."
        recovered=$((recovered + 1))
      else
        log "WARNING: could not recover ${module_name} from ${quarantine}."
      fi
    fi
  done < <(find "${quarantine}" -mindepth 1 -maxdepth 1 2>/dev/null || true)

  (( recovered > 0 )) && log "Recovered ${recovered} module(s) from a previous run."
  rmdir "${quarantine}" 2>/dev/null || true
  return 0
}

# Restore flagged modules from composer.lock.
#
# Ordering is the whole point: modules are moved aside, NOT deleted, and are
# discarded only once the reinstall has demonstrably put them back. Deleting
# first and trusting the reinstall means one transient failure destroys them.
restore_modules_from_lock() {
  local project_root="$1" contrib_dir="$2"
  shift 2
  local -a repair_names=("$@")

  local quarantine="${project_root}/${QUARANTINE_NAME}"
  mkdir -p "${quarantine}" || {
    log "Could not create ${quarantine}; skipping module repair."
    return 1
  }

  local name path
  local -a moved=()
  for name in "${repair_names[@]}"; do
    path="${contrib_dir}/${name}"
    [[ -d "${path}" ]] || continue
    if mv "${path}" "${quarantine}/${name}" 2>/dev/null; then
      moved+=("${name}")
    else
      log "WARNING: could not move ${path} aside; leaving it in place."
    fi
  done

  if (( ${#moved[@]} == 0 )); then
    log "Nothing was moved aside; skipping reinstall."
    rmdir "${quarantine}" 2>/dev/null || true
    return 0
  fi

  # `composer reinstall <packages>`, never a bare `composer install`.
  #
  # Two reasons. First, correctness: composer install diffs the lock against
  # vendor/composer/installed.json and does NOT stat package directories, so
  # after moving a directory aside it sees nothing to do, reports success, and
  # restores nothing - which would make the discard below a permanent deletion.
  # reinstall re-fetches the named packages unconditionally. Second, blast
  # radius: a bare install also re-runs drupal-scaffold (which fights this
  # image over robots.txt), re-applies patches, and rewrites the whole
  # autoloader. Scoping to the named packages keeps a module repair a module
  # repair.
  #
  # HOME is set explicitly because gosu does not reset it, so composer would
  # otherwise run as www-data with HOME=/root and fail to create its cache.
  local -a packages=()
  for name in "${moved[@]}"; do packages+=("drupal/${name}"); done

  log "Reinstalling ${#packages[@]} package(s) from composer.lock..."
  local status=0
  (
    cd "${project_root}" || exit 90
    env HOME=/tmp COMPOSER_HOME=/tmp/.composer \
      gosu www-data composer reinstall "${packages[@]}" \
        --no-interaction --no-progress --prefer-dist
  ) || status=$?

  if (( status == 90 )); then
    log "Could not enter ${project_root}; treating as a repair failure."
  fi

  # Never trust the exit code alone: verify every module actually came back.
  # A zero status from a composer that did nothing is exactly how the previous
  # implementation lost modules permanently.
  local missing=0
  if (( status == 0 )); then
    for name in "${moved[@]}"; do
      if [[ -z "$(find "${contrib_dir}/${name}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        log "Composer did not restore ${name}."
        missing=1
      fi
    done
  fi

  if (( status != 0 || missing != 0 )); then
    log "Reinstall FAILED (status ${status}, missing ${missing}); rolling back."
    for name in "${moved[@]}"; do
      if [[ -d "${quarantine}/${name}" && ! -d "${contrib_dir}/${name}" ]]; then
        mv "${quarantine}/${name}" "${contrib_dir}/${name}" 2>/dev/null \
          || log "WARNING: could not roll back ${name}; it remains in ${quarantine}."
      fi
    done
    rmdir "${quarantine}" 2>/dev/null || log "Quarantine retained at ${quarantine}."
    return 1
  fi

  log "Reinstall succeeded; discarding ${#moved[@]} quarantined module(s)."
  rm -rf "${quarantine}"
  return 0
}

# --- main repair routine ----------------------------------------------------

repair_composer_managed_modules() {
  if [[ "${DRUPAL_ENABLE_MODULE_REPAIR:-0}" != "1" ]]; then
    log "Module repair is opt-in and disabled; set DRUPAL_ENABLE_MODULE_REPAIR=1 to enable."
    return 0
  fi

  local project_root
  project_root="$(find_project_root)" || {
    log "No Drupal project root found; skipping module repair."
    return 0
  }

  local contrib_dir="${project_root}/web/modules/contrib"
  local composer_lock="${project_root}/composer.lock"

  if [[ ! -d "${contrib_dir}" ]]; then
    log "Contrib directory not found at ${contrib_dir}; skipping module repair."
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log "jq not available; skipping module repair (cannot parse composer.lock)."
    return 0
  fi
  if [[ ! -f "${composer_lock}" ]]; then
    log "composer.lock not found at ${composer_lock}; skipping module repair."
    return 0
  fi

  recover_orphaned_quarantine "${project_root}" "${contrib_dir}"

  # www-data has to be able to recreate the module directories, and permission
  # hardening deliberately leaves code owned root:www-data. Check before moving
  # anything rather than discovering it after the tree is already aside.
  if [[ "${DRY_RUN}" != "1" ]] && ! gosu www-data test -w "${contrib_dir}"; then
    log "www-data cannot write ${contrib_dir}; skipping module repair."
    return 0
  fi

  local force_repair="${DRUPAL_AFTER_START_FORCE_MODULE_REPAIR:-0}"
  log "Checking contrib modules for repair (force=${force_repair}, dry_run=${DRY_RUN})..."

  local -a repair_names=()
  local module_dir module_name reason

  while IFS= read -r module_dir; do
    [[ -d "${module_dir}" ]] || continue
    module_name="$(basename "${module_dir}")"

    # Only ever touch a module composer actually manages. A hand-placed or
    # non-composer module is invisible to composer, so moving it would strand
    # it with nothing able to restore it.
    if [[ -z "$(expected_module_version "${composer_lock}" "${module_name}")" ]]; then
      log "Module ${module_name} is not in composer.lock; leaving it untouched."
      continue
    fi

    if [[ "${force_repair}" == "1" ]]; then
      log "Module ${module_name} flagged for repair (force mode)."
      repair_names+=("${module_name}")
      continue
    fi

    if reason="$(module_repair_reason "${project_root}" "${module_dir}" "${module_name}" "${composer_lock}")"; then
      log "Module ${module_name} needs repair: ${reason}"
      repair_names+=("${module_name}")
    fi
  done < <(find "${contrib_dir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)

  if (( ${#repair_names[@]} == 0 )); then
    log "All composer-managed modules look healthy; nothing to repair."
    return 0
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    log "DRY RUN: would repair ${#repair_names[@]} module(s): ${repair_names[*]}"
    log "DRY RUN: no files were changed."
    return 0
  fi

  log "Repairing ${#repair_names[@]} composer-managed module(s)."
  restore_modules_from_lock "${project_root}" "${contrib_dir}" "${repair_names[@]}"
}

# --- entry point ------------------------------------------------------------

main() {
  local project_root version marker_file=""
  version="$(read_wrapper_version)"

  if project_root="$(find_project_root)"; then
    # An undetermined version must not gate anything: writing
    # ".after-start-unknown.complete" would silently turn "once per version"
    # into "once, ever".
    if [[ "${version}" != "unknown" ]]; then
      marker_file="${project_root}/.after-start-${version}.complete"
    else
      log "Wrapper version could not be determined; not using a completion marker."
    fi
  fi

  if [[ -n "${marker_file}" && -f "${marker_file}" ]]; then
    log "After-start for ${version} already complete; exiting."
    return 0
  fi

  log "Starting after-start tasks for ${version}..."

  local status=0
  repair_composer_managed_modules || status=$?

  if (( status != 0 )); then
    # No marker on failure: the work did not complete, so the next start must
    # retry rather than skip. Writing it here is how a half-repaired tree
    # becomes permanent.
    log "After-start tasks FAILED (status ${status}); marker not written, will retry next start."
    return "${status}"
  fi

  if [[ -n "${marker_file}" && "${DRY_RUN}" != "1" ]]; then
    # Prune older markers so exactly one exists. Without this, rolling back to
    # an earlier image finds its old marker still present on the volume and
    # skips the repair that a downgrade most needs.
    find "$(dirname "${marker_file}")" -maxdepth 1 -name '.after-start-*.complete' \
      -delete 2>/dev/null || true
    # Marker failure must be loud but not fatal: aborting here after a
    # successful repair would re-arm the whole routine on every restart.
    if ! touch "${marker_file}" 2>/dev/null; then
      log "WARNING: could not write ${marker_file}; repair will re-run next start."
    fi
  fi

  log "After-start tasks for ${version} complete."
}

main "$@"
