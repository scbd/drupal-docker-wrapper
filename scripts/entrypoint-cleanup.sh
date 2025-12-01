# Image hygiene and runtime-safe permission helpers.
# shellcheck shell=bash

# Expects find_project_root() and log() from entrypoint-common.sh

cleanup_deprecated_paths() {
  local project_root
  project_root="$(find_project_root)" || return 0

  local web_root="${project_root}/web"
  local paths=(
    "modules/contrib/login_destination"
    # "modules/contrib/ckeditor_templates"
    "modules/contrib/ckeditor_templates_ui"
    "modules/contrib/ctools"
    "robots.txt"
  )

  local rel
  for rel in "${paths[@]}"; do
    local target="${web_root}/${rel}"
    if [[ -e "${target}" ]]; then
      log "Removing deprecated path ${target}"
      rm -rf "${target}" || log "Failed to remove ${target}; continuing."
    fi
  done
}

ensure_sites_files_permissions() {
  local project_root
  project_root="$(find_project_root)" || return 0

  local sites_base="${project_root}/web/sites"

  # Default site files directory
  mkdir -p "${sites_base}/default/files"
  chmod -R 775 "${sites_base}/default/files" || true
  chown -R www-data:www-data "${sites_base}/default/files" || true

  # Multisite files directories from sites.php if present
  if [[ -f "${sites_base}/sites.php" ]]; then
    DRUPAL_SITES_FILE="${sites_base}/sites.php" php -r '$sites = []; include getenv("DRUPAL_SITES_FILE"); foreach (array_unique(array_values($sites)) as $dir) { echo $dir . PHP_EOL; }' \
      | while read -r site_dir; do
          [[ -z "${site_dir}" ]] && continue
          mkdir -p "${sites_base}/${site_dir}/files"
          chmod -R 775 "${sites_base}/${site_dir}/files" || true
          chown -R www-data:www-data "${sites_base}/${site_dir}/files" || true
        done
  fi
}
