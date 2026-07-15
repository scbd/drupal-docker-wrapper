###############################################
# Base Stage: Core + system tools + composer config
###############################################
FROM drupal:11.4.3-php8.4 AS base-core

WORKDIR /opt/drupal

# System packages (keep minimal) - cache apt metadata
# gosu is needed for dropping privileges in entrypoint
# jq is needed for parsing composer.lock in after-start.sh
# nano is a text editor for debugging inside the container
# default-mysql-client is needed for database operations and drush sql commands
# hadolint ignore=DL3008
RUN --mount=type=cache,target=/var/cache/apt \
    set -eux; \
    apt-get update -y; \
    apt-get install --no-install-recommends -y curl ca-certificates unzip gosu jq nano default-mysql-client rsync; \
    rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2
RUN set -eux; \
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"; \
    unzip awscliv2.zip; \
    ./aws/install; \
    rm -rf aws awscliv2.zip

# Rebuild GD extension with AVIF support (Drupal 11 expects it)
# hadolint ignore=DL3008
RUN --mount=type=cache,target=/var/cache/apt \
    set -eux; \
    apt-get update -y; \
    apt-get install --no-install-recommends -y \
        libavif-dev \
        libfreetype6-dev \
        libjpeg62-turbo-dev \
        libpng-dev \
        libwebp-dev; \
    docker-php-ext-configure gd \
        --with-freetype \
        --with-jpeg \
        --with-webp \
        --with-avif; \
    docker-php-ext-install -j"$(nproc)" gd; \
    rm -rf /var/lib/apt/lists/*

# Copy local patches into the image so composer-patches can use them
COPY ./patches/ /opt/drupal/patches/

# Composer configuration: prefer dist, enable patches, allow plugin, scaffold tweak
#
# TEMPORARY (BL-695): ignore three guzzle-stack security advisories (published 2026-06-18,
# no patched release yet inside Drupal core's pinned ranges) so the Critical
# SA-CORE-2026-005..009 Drupal core fix (shipped in 11.3.12) can build now:
#   - PKSA-93qv-9n9h-6k6p / GHSA-cwxw-98qj-8qjx  guzzlehttp/guzzle ~7.10  (dot-only cookie domains match all hosts)
#   - PKSA-k22t-f949-t9g6 / GHSA-wpwq-4j6v-78m3  guzzlehttp/guzzle ~7.10  (silent HTTPS-proxy downgrade to cleartext)
#   - PKSA-7qs6-zvnz-h66r                        guzzlehttp/psr7 ~2.10    (no fixed release in core's range yet)
# REMOVE once guzzle/psr7 ship patched releases in core's ranges. Tracks Drupal issue #3599842.
RUN set -eux; \
    composer config preferred-install dist; \
    composer config --json --merge extra.enable-patching true; \
    # composer config --json --merge extra.patches."drupal/jsonapi_extras" '{"Fix for issue 3452036": "patches/jsonapi_extras--2025-06-30--3452036--mr-51.patch"}'; \
    # auto_node_translate 3.0.2: fix call_user_func TypeError and restrict the Automatic Translation tab to the module's own permission (Drupal issue #3609236) \
    composer config --json --merge extra.patches."drupal/auto_node_translate" '{"Restrict Automatic Translation tab to auto translate permission; fixes call_user_func TypeError (#3609236)": "patches/auto_node_translate--2026-07-15--3609236--gate-on-permission.patch"}'; \
    composer config --no-plugins allow-plugins.cweagans/composer-patches true; \
    composer config extra.drupal-scaffold.file-mapping."[web-root]/robots.txt".mode skip; \
    composer config policy.advisories.ignore-id PKSA-93qv-9n9h-6k6p PKSA-k22t-f949-t9g6 PKSA-7qs6-zvnz-h66r

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
      'drush/drush:13.7.0' \
      'drupal/admin_toolbar:3.6.3' \
      'drupal/administerusersbyrole:3.6.0' \
      'drupal/ant_bulk:2.0.0-rc4' \
      'drupal/auditfiles:4.2.4' \
      'drupal/auto_node_translate:3.0.2' \
      'drupal/auto_node_translate_amazon:1.0.0' \
      'drupal/auto_node_translate_deepl:1.0.0' \
      'drupal/ckeditor_bs_grid:2.1.0' \
      'drupal/ckeditor5_fullscreen:1.0' \
      'drupal/ckeditor5_icons:1.3.0' \
      'drupal/ckeditor5_template:1.0.9' \
      'drupal/decoupled_router:2.0.6' \
      'drupal/devel:5.5.0' \
      'drupal/editor_paste_plain:1.0.0-rc1' \
      'drupal/externalauth:2.0.11' \
      'drupal/facets:3.0.3' \
      'drupal/fontawesome:3.0.0' \
      'drupal/fontawesome_iconpicker:3.0.0' \
      'drupal/forum:1.0.6' \
      'drupal/fpa:4.0.2' \
      'drupal/js_cookie:1.0.2' \
      'drupal/jsonapi_extras:3.x-dev@dev' \
      'drupal/jsonapi_include:2.0.0' \
      'drupal/jsonapi_resources:1.7' \
      'drupal/jsonapi_search_api:1.0-rc5' \
      'drupal/jsonapi_site:1.0.2' \
      'drupal/key_auth:2.2.0' \
      'drupal/linkit:7.0.16' \
      'drupal/mailsystem:4.5' \
      'drupal/menu_admin_per_menu:1.7' \
      'drupal/menu_link_attributes:1.7' \
      'drupal/pathauto:1.15' \
      'drupal/quick_node_clone:1.22' \
      'drupal/redirect:1.13' \
      'drupal/remove_entity_untranslatable_field_validation:1.3' \
      'drupal/robotstxt:1.6' \
      'drupal/samlauth:3.14' \
      'drupal/search_api:1.41' \
      'drupal/symfony_mailer:1.6.2' \
      'drupal/token:1.17' \
      --with-all-dependencies \
      --no-interaction \
      --no-progress \
      --optimize-autoloader; \
    composer show --no-interaction --direct > /opt/drupal/modules-versions.txt; \
    # Generate SHA256 hashes for all contrib modules (used for integrity checking at runtime)
    find /opt/drupal/web/modules/contrib -mindepth 1 -maxdepth 1 -type d -exec sh -c '\
      for dir; do \
        module=$(basename "$dir"); \
        find "$dir" -type f -name "*.php" -o -name "*.info.yml" -o -name "composer.json" 2>/dev/null | \
          sort | xargs cat 2>/dev/null | sha256sum | cut -d" " -f1 > "/opt/drupal/web/modules/contrib/.${module}.hash"; \
      done' _ {} +
#       'drupal/jsonapi_extras:3.27' \


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

# Disable assertions and suppress the assert.active deprecation warning (PHP 8.3+)
# - zend.assertions=-1 means assertion code is not generated at all (best for production)
# - error_reporting excludes E_DEPRECATED to suppress the assert.active startup warning
#   (The base PHP image has assert.active=On by default, which triggers a deprecation notice)
RUN printf 'zend.assertions=-1\nerror_reporting=E_ALL & ~E_DEPRECATED\n' > /usr/local/etc/php/conf.d/zz-production.ini

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

# Copy package.json for version tracking
COPY --chown=www-data:www-data ./package.json /opt/drupal/

# Copy entrypoint wrapper, after-start script, and lib helpers
COPY --chown=www-data:www-data ./scripts/*.sh /usr/local/bin/
COPY --chown=www-data:www-data ./scripts/lib/ /usr/local/bin/lib/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/after-start.sh

# Ensure Composer home/cache is writable for www-data
ENV COMPOSER_HOME=/var/www/.composer \
    COMPOSER_CACHE_DIR=/var/www/.composer/cache
RUN set -eux; \
    mkdir -p "$COMPOSER_CACHE_DIR"; \
    chown -R www-data:www-data /var/www/.composer

# (Optional) HEALTHCHECK - simple HTTP check on root path
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD curl -fsS http://localhost/ -o /dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["apache2-foreground"]

# Note: Entrypoint runs as root to fix permissions, then drops to www-data