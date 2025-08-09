## Addon layer: adds pinned contrib modules + Drush on top of base-core
## Expects a previously built base image tagged as scbd/drupal-docker-wrapper-base:latest
FROM scbd/drupal-docker-wrapper-base:latest AS with-modules
## (Alternatively build locally using: docker build -t scbd/drupal-docker-wrapper-base:latest base)

WORKDIR /opt/drupal

RUN --mount=type=cache,target=/root/.composer/cache \
    set -eux; \
    composer require 'drush/drush:13.6.0' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/administerusersbyrole:3.5.0' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/auditfiles:4.2.1' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/admin_toolbar:3.6.2' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/ckeditor_bs_grid:2.0.12' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/ckeditor5_template:1.0.8' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/ckeditor5_fullscreen:1.0' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/editor_paste_plain:1.0.0-rc1' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/decoupled_router:2.0.5' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/forum:1.0.2' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/jsonapi_site:1.0.2' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/key_auth:2.2.0' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/pathauto:1.13' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/token:1.15' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/externalauth:2.0.8' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/redirect:1.11' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/samlauth:3.11' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/mailsystem:4.5' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/robotstxt:1.6' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/symfony_mailer:1.6.2' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/remove_entity_untranslatable_field_validation:1.3' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/jsonapi_include:2.0.0' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/menu_admin_per_menu:1.7' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/menu_link_attributes:1.5' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/quick_node_clone:1.22' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/jsonapi_extras:3.26' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/fpa:4.0.1' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/search_api:1.38' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/facets:3.0' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/jsonapi_resources:1.3' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/jsonapi_search_api:1.0-rc5' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/devel:5.4.0' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'cweagans/composer-patches:1.7.3' --no-update --no-interaction --no-progress; \
    composer require 'drupal/ckeditor5_icons:1.2.1' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/auto_node_translate_deepl:1.0.0-rc2' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/auto_node_translate:3.0.2' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/auto_node_translate_amazon:1.0.0-rc1' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/ant_bulk:2.0.0-rc4' --with-all-dependencies --no-interaction --no-progress; \
    composer require 'drupal/fontawesome:3.0.0' --with-all-dependencies --no-interaction --no-progress; \
    composer show --no-interaction --direct > /opt/drupal/modules-versions.txt; \
    rm -rf web/modules/contrib/login_destination \
        web/modules/contrib/ckeditor_templates \
        web/modules/contrib/ckeditor_templates_ui \
        web/modules/contrib/ctools \
        web/robots.txt; \
    if [ -f web/core/install.php ]; then mv web/core/install.php web/core/install.disable; fi; \
    find web -type d -exec chmod 755 {} \;; \
    find web -type f -exec chmod 644 {} \;; \
    chmod -R 775 web/sites/default/files || true; \
    chown -R www-data:www-data /opt/drupal

LABEL org.opencontainers.image.title="Drupal 11 Addon Modules (Non-Root)" \
      org.opencontainers.image.source="https://github.com/scbd/drupal-docker-wrapper" \
      org.opencontainers.image.description="Addon layer with pinned contrib modules and Drush" \
      org.opencontainers.image.licenses="GPL-2.0-or-later"

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 CMD curl -fsS http://localhost/healthz || curl -fsS http://localhost/ || exit 1

WORKDIR /opt/drupal

# Drop privileges for runtime
USER www-data
