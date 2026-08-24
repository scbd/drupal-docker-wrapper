#!/usr/bin/env bash
# Table tests for the version-comparison logic in after-start.sh.
#
# This logic decides whether a module gets moved aside and reinstalled, so a
# false "mismatch" is a destructive action. These cases exist because earlier
# revisions produced false mismatches on version forms this image actually
# pins (dev branches and release candidates).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${HERE}/../after-start.sh"

# Pull in only the pure functions: source the script with a main() that does
# nothing, so sourcing it cannot run the repair routine.
extract() {
  sed -n '/^normalize_version()/,/^}/p;/^is_comparable_version()/,/^}/p' "${TARGET}"
}
eval "$(extract)"

fail=0
pass=0

# decide <lock-version> <disk-version> -> "repair" | "healthy" | "skip"
decide() {
  local e n_e n_i
  e="$(normalize_version "$1")"
  n_e="${e}"
  n_i="$(normalize_version "$2")"
  if is_comparable_version "${n_e}" && is_comparable_version "${n_i}"; then
    [[ "${n_e}" != "${n_i}" ]] && echo repair || echo healthy
  else
    echo skip
  fi
}

check() {
  local lock="$1" disk="$2" want="$3" got
  got="$(decide "${lock}" "${disk}")"
  if [[ "${got}" == "${want}" ]]; then
    pass=$((pass + 1))
  else
    printf 'FAIL  lock=%-14s disk=%-14s want=%-8s got=%s\n' "${lock}" "${disk}" "${want}" "${got}"
    fail=$((fail + 1))
  fi
}

# Equivalent forms must NOT trigger a repair.
check "8.x-1.6"     "1.6.0"        healthy
check "1.6"         "1.6.0"        healthy
check "v2.0.1"      "2.0.1"        healthy
check "1.41"        "1.41.0"       healthy
check "3.0.2"       "3.0.2"        healthy
check "2.1.0+build" "2.1.0"        healthy

# Genuine mismatches MUST trigger a repair.
check "1.15"        "1.14"         repair
check "13.7.6"      "13.7.5"       repair
check "2.0.0"       "1.9.9"        repair

# Incomparable forms must be SKIPPED, never guessed at. Each of these is
# pinned somewhere in this image's Dockerfile.
check "3.x-dev"     "3.27"         skip
check "3.x-dev"     "3.0.0"        skip
check "dev-3.x"     "3.27.0"       skip
check "1.0.0-rc1"   "1.0.0"        skip
check "1.0.0-rc1"   "8.x-1.0-rc1"  skip
check "2.0.0-rc4"   "2.0.0"        skip
check "1.0-rc5"     "1.0.0"        skip
check "1.2"         "1.2.0-beta1"  skip
check "1.0"         "VERSION"      skip
check "dev-1.x"     "1.x-dev"      skip

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
(( fail == 0 ))
