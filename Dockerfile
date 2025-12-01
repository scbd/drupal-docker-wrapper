###############################################
# Base Stage: Core + system tools + composer config
###############################################
FROM drupal:11.2.8-php8.4 AS base-core

WORKDIR /opt/drupal

# System packages (keep minimal) - cache apt metadata
# hadolint ignore=DL3008
RUN --mount=type=cache,target=/var/cache/apt \
    set -eux; \
    apt-get update -y; \
    apt-get install --no-install-recommends -y curl ca-certificates unzip; \
    rm -rf /var/lib/apt/lists/*

# Copy local patches into the image so composer-patches can use them
COPY ./patches/ /opt/drupal/patches/

# Composer configuration: prefer dist, enable patches, allow plugin, scaffold tweak
RUN set -eux; \
    composer config preferred-install dist; \
    composer config --json --merge extra.enable-patching true; \
    # composer config --json --merge extra.patches."drupal/jsonapi_extras" '{"Fix for issue 3452036": "patches/jsonapi_extras--2025-06-30--3452036--mr-51.patch"}'; \
    composer config --no-plugins allow-plugins.cweagans/composer-patches true; \
    composer config extra.drupal-scaffold.file-mapping."[web-root]/robots.txt".mode skip

###############################################
# Modules Stage: install plugin early, then modules
###############################################
FROM base-core AS with-modules
WORKDIR /opt/drupal

# Ensure tools required during composer operations are present; purge later
# hadolint ignore=DL3008
RUN --mount=type=cache,target=/var/cache/apt \
    set -eux; \
    apt-get update -y; \
    apt-get install --no-install-recommends -y git patch unzip; \
    rm -rf /var/lib/apt/lists/*

# Install the patches plugin BEFORE requiring patched packages
RUN --mount=type=cache,target=/root/.composer/cache \
    set -eux; \
    composer require cweagans/composer-patches:^1.7 --no-interaction --no-progress

# Explicit module versions in a single layer to maximize cache efficiency
RUN --mount=type=cache,target=/root/.composer/cache \
    set -eux; \
    composer require \
      'drush/drush:13.6.2' \
      'drupal/administerusersbyrole:3.6.0' \
      'drupal/auditfiles:4.2.4' \
      'drupal/admin_toolbar:3.6.2' \
      'drupal/ckeditor_bs_grid:2.0.12' \
      'drupal/ckeditor5_template:1.0.8' \
      'drupal/ckeditor5_fullscreen:1.0' \
      'drupal/editor_paste_plain:1.0.0-rc1' \
      'drupal/decoupled_router:2.0.6' \
      'drupal/forum:1.0.2' \
      'drupal/jsonapi_site:1.0.2' \
      'drupal/key_auth:2.2.0' \
      'drupal/pathauto:1.14' \
      'drupal/token:1.16' \
      'drupal/externalauth:2.0.8' \
      'drupal/redirect:1.12' \
      'drupal/samlauth:3.11' \
      'drupal/mailsystem:4.5' \
      'drupal/robotstxt:1.6' \
      'drupal/symfony_mailer:1.6' \
      'drupal/remove_entity_untranslatable_field_validation:1.3' \
      'drupal/jsonapi_include:2.0.0' \
      'drupal/js_cookie:1.0.2' \
      'drupal/menu_admin_per_menu:1.7' \
      'drupal/menu_link_attributes:1.5' \
      'drupal/quick_node_clone:1.22' \
      'drupal/jsonapi_extras:3.27' \
      'drupal/fpa:4.0.1' \
      'drupal/search_api:1.40' \
      'drupal/facets:3.0.2' \
      'drupal/jsonapi_resources:1.3' \
      'drupal/jsonapi_search_api:1.0-rc5' \
      'drupal/devel:5.4.0' \
      'drupal/ckeditor5_icons:1.2.1' \
      'drupal/auto_node_translate_deepl:1.0.0' \
      'drupal/auto_node_translate:3.0.2' \
      'drupal/auto_node_translate_amazon:1.0.0-rc1' \
      'drupal/ant_bulk:2.0.0-rc4' \
      'drupal/fontawesome:3.0.0' \
      'drupal/fontawesome_iconpicker:3.0.0' \   
      --with-all-dependencies \
      --no-interaction \
      --no-progress \
      --optimize-autoloader; \
    composer show --no-interaction --direct > /opt/drupal/modules-versions.txt

# Keep 'patch' and 'git' at runtime so entrypoint and composer operations succeed
# hadolint ignore=DL3008
RUN --mount=type=cache,target=/var/cache/apt \
    set -eux; \
    apt-get purge -y unzip || true; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*

###############################################
# Final Stage
###############################################
FROM with-modules AS final
WORKDIR /opt/drupal

# Expose manifest for quick inspection
LABEL org.opencontainers.image.title="Drupal 11 Base with Contrib Modules" \
      org.opencontainers.image.source="https://github.com/scbd/drupal-docker-wrapper" \
      org.opencontainers.image.description="Drupal 11 image with pinned contrib module versions and patching enabled" \
      org.opencontainers.image.licenses="GPL-2.0-or-later"

# Point Apache docroot at our built project and ensure permissions
RUN set -eux; \
    rm -rf /var/www/html; \
    ln -s /opt/drupal/web /var/www/html; \
    chown -R www-data:www-data /opt/drupal

# Copy entrypoint wrapper and its helper scripts
COPY --chown=www-data:www-data ./scripts/*.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

# Ensure Composer home/cache is writable for www-data
ENV COMPOSER_HOME=/var/www/.composer \
    COMPOSER_CACHE_DIR=/var/www/.composer/cache
RUN set -eux; \
    mkdir -p "$COMPOSER_CACHE_DIR"; \
    chown -R www-data:www-data /var/www/.composer

# (Optional) HEALTHCHECK - simple HTTP check (can be overridden)
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD curl -fsS http://localhost/healthz || curl -fsS http://localhost/ || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["apache2-foreground"]

USER www-data
