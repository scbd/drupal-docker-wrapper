# Shared helpers for Drupal entrypoint and after-start scripts.
# shellcheck shell=bash

# Candidate roots where the Drupal project may live
ROOT_CANDIDATES=("/opt/drupal" "/var/www/html")

log() {
  local prefix="${LOG_PREFIX:-entrypoint}"
  echo "[${prefix}] $*"
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
