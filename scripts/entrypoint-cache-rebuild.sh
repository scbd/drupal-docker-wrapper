# Non-fatal Drupal cache rebuild helper.
# shellcheck shell=bash

# Expects ROOT_CANDIDATES and log() from entrypoint-common.sh

entrypoint_maybe_rebuild_cache() {
  local root
  for root in "${ROOT_CANDIDATES[@]}"; do
    if [[ -f "${root}/web/sites/default/settings.php" ]]; then
      log "Detected Drupal settings at ${root}; attempting cache:rebuild (non-fatal)."
      if command -v php >/dev/null 2>&1; then
        # Try Drush if available, otherwise use Drupal's rebuild.php if present.
        if command -v /opt/drupal/vendor/bin/drush >/dev/null 2>&1; then
          /opt/drupal/vendor/bin/drush -r "${root}/web" cache:rebuild || log "drush cr failed; continuing."
        elif [[ -f "${root}/web/core/rebuild.php" ]]; then
          php "${root}/web/core/rebuild.php" || log "core rebuild.php failed; continuing."
        fi
      fi
      break
    fi
  done
}
