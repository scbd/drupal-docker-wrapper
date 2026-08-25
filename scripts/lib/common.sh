# Shared helpers for the Drupal entrypoint and after-start scripts.
# shellcheck shell=bash

# Candidate roots where the Drupal project may live. Authoritative on purpose:
# re-sourcing this file resets it, so a caller wanting different roots should
# set them after sourcing rather than before.
ROOT_CANDIDATES=("/opt/drupal" "/var/www/html")

log() {
  local prefix="${LOG_PREFIX:-entrypoint}"
  echo "[${prefix}] $*"
}

find_project_root() {
  local root
  for root in "${ROOT_CANDIDATES[@]}"; do
    if [[ -d "${root}/web" ]]; then
      echo "${root}"
      return 0
    fi
  done
  return 1
}

# Read the wrapper version from package.json, falling back to "unknown".
# Used to gate one-time startup tasks per released image version.
read_wrapper_version() {
  local manifest="${1:-/opt/drupal/package.json}"
  if command -v jq >/dev/null 2>&1 && [[ -f "${manifest}" ]]; then
    # `// "unknown"` alone only covers null/absent; an empty string would pass
    # through and collapse distinct versions into one gating bucket.
    jq -r '(.version // "") | if . == "" then "unknown" else . end' \
      "${manifest}" 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}
