# Base Drupal 11 image (core + system tools + composer config)
FROM drupal:11.2.3-php8.3 AS base-core

WORKDIR /opt/drupal

# System packages
# hadolint ignore=DL3008
RUN --mount=type=cache,target=/var/cache/apt \
    set -eux; \
    apt-get update -y; \
    apt-get install --no-install-recommends -y curl nano mariadb-client; \
    rm -rf /var/lib/apt/lists/*

# Composer configuration (patching + scaffold)
RUN set -eux; \
    composer config --json --merge extra.enable-patching true; \
    composer config --json --merge extra.patches."drupal/jsonapi_extras" '{"Fix for issue 3452036": "https://www.drupal.org/files/issues/2025-06-30/jsonapi_extras--2025-06-30--3452036--mr-51.patch"}'; \
    composer config --no-plugins allow-plugins.cweagans/composer-patches true; \
    composer config extra.drupal-scaffold.file-mapping."[web-root]/robots.txt".mode skip

# Minimal labels
LABEL org.opencontainers.image.title="Drupal 11 Base Core" \
      org.opencontainers.image.source="https://github.com/scbd/drupal-docker-wrapper"

WORKDIR /opt/drupal
