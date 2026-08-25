###############################################
# Base Stage: Core + system tools + composer config
###############################################
FROM drupal:11.4.5-php8.4 AS base-core

WORKDIR /opt/drupal

# System packages (keep minimal) - cache apt metadata
# gosu is kept so drush can be run as www-data by hand (e.g. gosu www-data vendor/bin/drush @lk cr)
# jq is needed for reading the wrapper version from package.json (after-start marker)
# nano is a text editor for debugging inside the container
# default-mysql-client is needed for database operations and drush sql commands
# hadolint ignore=DL3008
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache,sharing=locked \
    set -eux; \
    apt-get update -y; \
    apt-get install --no-install-recommends -y curl ca-certificates unzip gosu jq nano default-mysql-client; \
    rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2
#
# amd64 only, deliberately. This image is built and deployed for linux/amd64;
# nothing consumes an arm64 build, so the archive below is pinned to x86_64
# rather than parameterised. Recorded in adr/0010, which lands with the docs set.
# To reinstate arm64: re-add `ARG TARGETARCH` to each stage, split the apt cache
# ids back out per arch, map amd64->x86_64 / arm64->aarch64 onto the archive name
# below, and expect to debug the GD/AVIF rebuild, which has never been built for
# arm64.
#
# The `aws --version` check is load-bearing, not decoration. `./aws/install` exits 0
# even when the bundled x86_64 binary cannot execute - on an arm64 builder it prints
# "rosetta error: failed to open elf" and then "You can now run: aws --version", and
# `set -e` sees success. Without this assertion a `docker build` on an Apple Silicon
# machine silently produces an image whose aws is dead on first use.
ARG AWSCLI_VERSION=2.36.31
ARG AWSCLI_SHA256=96ab904b1fec2b49972685aecc1d2e8c0fd0c981d7a81f5dc5d2dd725ace05f1
RUN set -eux; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" -o awscliv2.zip; \
    echo "${AWSCLI_SHA256}  awscliv2.zip" | sha256sum -c -; \
    unzip -q awscliv2.zip; \
    ./aws/install; \
    rm -rf aws awscliv2.zip; \
    aws --version

# Rebuild GD extension with AVIF support (Drupal 11 expects it)
# hadolint ignore=DL3008
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache,sharing=locked \
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

# Copy local patches into the image so composer-patches can use them.
#
# root-owned, deliberately. The upstream image leaves /opt/drupal www-data-owned, so
# an unqualified COPY lands these www-data:www-data - and scripts/lib/patches.sh
# applies every discovered patch as root, before Apache starts. A www-data-writable
# patch directory would let a compromised PHP worker stage a file that root then
# applies to the docroot. The engine refuses non-root-owned patches for that reason,
# so without this --chown the runtime patch step silently refuses its own payload.
COPY --chown=root:root ./patches/ /opt/drupal/patches/

# Composer configuration: prefer dist, enable patches, allow plugin, scaffold tweak
#
# The BL-695 advisory suppression that used to sit at the end of this block is gone.
# It ignored three guzzle-stack advisories so the Critical SA-CORE-2026-005..009 core
# fix could build before guzzle/psr7 had patched releases in core's ranges. At 11.4.5
# that no longer applies: guzzle resolves to 7.15.5, well past the affected ~7.10, and
# `composer audit --no-dev` reports no advisories against the installed tree. Verified
# by building this stage with the suppression removed before deleting it.
RUN set -eux; \
    composer config preferred-install dist; \
    composer config --json --merge extra.enable-patching true; \
    # composer config --json --merge extra.patches."drupal/jsonapi_extras" '{"Fix for issue 3452036": "patches/jsonapi_extras--2025-06-30--3452036--mr-51.patch"}'; \
    # auto_node_translate 3.0.2: fix call_user_func TypeError and restrict the Automatic Translation tab to the module's own permission (Drupal issue #3609236) \
    composer config --json --merge extra.patches."drupal/auto_node_translate" '{"Restrict Automatic Translation tab to auto translate permission; fixes call_user_func TypeError (#3609236)": "patches/auto_node_translate--2026-07-15--3609236--gate-on-permission.patch"}'; \
    composer config --no-plugins allow-plugins.cweagans/composer-patches true; \
    # Exclude robots.txt from drupal-scaffold. This MUST go through --json --merge on
    # the file-mapping key: `composer config` only auto-nests one level below `extra.`,
    # so the older `extra.drupal-scaffold.file-mapping."[web-root]/robots.txt".mode skip`
    # form wrote a single flat key literally named
    # `file-mapping.[web-root]/robots.txt.mode` and scaffold never saw an override.
    # `false` is also the only value scaffold honours as "do not write this file";
    # `mode: skip` is not part of its schema.
    composer config --json --merge extra.drupal-scaffold.file-mapping '{"[web-root]/robots.txt": false}'

###############################################
# Modules Stage: install plugin early, then modules
###############################################
FROM base-core AS with-modules
WORKDIR /opt/drupal

# Ensure tools required during composer operations are present; purge later
# hadolint ignore=DL3008
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache,sharing=locked \
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
      'drush/drush:13.7.6' \
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
      'drupal/ckeditor5_template:1.0.10' \
      'drupal/decoupled_router:2.0.7' \
      'drupal/devel:5.5.0' \
      'drupal/editor_paste_plain:1.0.0-rc1' \
      'drupal/externalauth:2.0.13' \
      'drupal/facets:3.0.4' \
      'drupal/fontawesome:3.0.0' \
      'drupal/fontawesome_iconpicker:3.0.0' \
      'drupal/forum:1.1.3' \
      'drupal/fpa:4.0.2' \
      'drupal/js_cookie:1.0.2' \
      'drupal/jsonapi_extras:3.27' \
      'drupal/jsonapi_include:2.0.0' \
      'drupal/jsonapi_resources:1.8' \
      'drupal/jsonapi_search_api:1.0-rc5' \
      'drupal/jsonapi_site:1.0.2' \
      'drupal/key_auth:2.2.3' \
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
    # The scaffold exclusion above stops composer from WRITING robots.txt, but the
    # upstream drupal image already ships one. Delete it so the drupal/robotstxt
    # module owns the route instead of being shadowed by a static file.
    rm -f /opt/drupal/web/robots.txt

# Fail the build on a known-vulnerable dependency.
#
# This is what makes deleting the BL-695 suppression safe to keep. The direct
# requires above are exact-pinned, but --with-all-dependencies re-resolves every
# transitive against packagist on each build, so "guzzle is past the affected
# range" is a fact about one resolution, not about this Dockerfile. Without this
# line the removal would take the last build-time advisory signal with it, and a
# future rebuild could quietly pull a vulnerable transitive.
#
# If this ever fails, do not re-add an ignore-id. Find out what moved.
RUN --mount=type=cache,target=/root/.composer/cache \
    set -eux; \
    composer audit --no-dev

# Keep 'patch' and 'git' at runtime so the entrypoint's patch-application step succeeds
# hadolint ignore=DL3008
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache,sharing=locked \
    set -eux; \
    apt-get purge -y unzip || true; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*

# git is a hard runtime dependency, not a convenience: scripts/lib/patches.sh applies
# every patch with `git apply` and has no fallback. Without it the patch step degrades
# to a single log line and the container serves unpatched code. Assert it survived the
# purge above rather than trusting the comment.
RUN set -eux; \
    command -v git >/dev/null || { echo "FATAL: git is required by scripts/lib/patches.sh"; exit 1; }; \
    command -v patch >/dev/null || { echo "FATAL: patch is expected at runtime"; exit 1; }

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
#
# patches/ is re-owned to root AFTER the recursive chown, which would otherwise hand
# it back to www-data. scripts/lib/patches.sh applies these as root before Apache
# starts and refuses any patch a less-privileged account could have written, so this
# ownership is a precondition for the runtime patch step working at all - not
# cosmetic. Asserted below so a future reordering cannot silently undo it.
RUN set -eux; \
    rm -rf /var/www/html; \
    ln -s /opt/drupal/web /var/www/html; \
    chown -R www-data:www-data /opt/drupal; \
    chown -R root:root /opt/drupal/patches; \
    chmod 755 /opt/drupal/patches; \
    find /opt/drupal/patches -type f -exec chmod 644 {} +; \
    test -z "$(find /opt/drupal/patches ! -user root -print -quit)"; \
    # Root-own the project directory NODE (not -R). Directory write permission
    # governs creating and removing entries, not their ownership, so a www-data
    # /opt/drupal would let a compromised worker rename patches/ aside and put its
    # own directory there. It could not get a patch applied - the engine refuses
    # anything it does not own - but it could make the shipped patch vanish, and
    # that patch is an authorization gate. Losing it logs only "No patch files
    # found", which reads like a normal build.
    chown root:root /opt/drupal; \
    test "$(stat -c '%U' /opt/drupal)" = root

# Copy package.json for version tracking
COPY --chown=www-data:www-data ./package.json /opt/drupal/

# Copy entrypoint wrapper, after-start script, and lib helpers
#
# root-owned and not group/other-writable, without exception. entrypoint.sh runs as
# root and `source`s lib/common.sh and lib/patches.sh as root before Apache binds,
# then execs after-start.sh as root. If www-data can write any of the four, a single
# Drupal file-write primitive plus one container restart is container root - and it
# bypasses the patch engine's own provenance check entirely, because editing the
# engine is easier than getting a patch past it. Nothing at runtime needs these
# writable; entrypoint.sh only reads them.
COPY --chown=root:root ./scripts/*.sh /usr/local/bin/
COPY --chown=root:root ./scripts/lib/ /usr/local/bin/lib/
RUN set -eux; \
    chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/after-start.sh; \
    chmod 644 /usr/local/bin/lib/*.sh; \
    for f in /usr/local/bin/entrypoint.sh /usr/local/bin/after-start.sh \
             /usr/local/bin/lib/common.sh /usr/local/bin/lib/patches.sh; do \
      test "$(stat -c '%U' "$f")" = root; \
      test -z "$(find "$f" -maxdepth 0 \( -perm -g+w -o -perm -o+w \) -print)"; \
    done

# Ensure Composer home/cache is writable for www-data
ENV COMPOSER_HOME=/var/www/.composer \
    COMPOSER_CACHE_DIR=/var/www/.composer/cache
RUN set -eux; \
    mkdir -p "$COMPOSER_CACHE_DIR"; \
    chown -R www-data:www-data /var/www/.composer

# (Optional) HEALTHCHECK - simple HTTP check on root path
# 127.0.0.1, not localhost: if localhost resolves to ::1 first and Apache's Listen 80
# is v4-only, the probe fails while the container is serving normally - which on ECS
# is a task-replacement loop. Matches the entrypoint's readiness probe.
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD curl -fsS http://127.0.0.1/ -o /dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["apache2-foreground"]

# Note: Entrypoint runs as root to fix permissions, then drops to www-data