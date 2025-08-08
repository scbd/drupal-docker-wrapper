
FROM drupal:10.5.1-php8.3

WORKDIR /opt/drupal

# Install system packages
RUN --mount=type=cache,target=/var/cache/apt \
    apt update -y && \
    apt install curl nano mariadb-client -y

# Install Drupal modules and Drush
RUN --mount=type=cache,target=/var/cache/apt \
    composer require 'drupal/administerusersbyrole:3.5' --with-all-dependencies && \
    composer require 'drupal/auditfiles:4.2.1' --with-all-dependencies && \
    composer require 'drush/drush:13.6.0' --with-all-dependencies && \
    composer require 'drupal/admin_toolbar:3.6.1' --with-all-dependencies && \
    composer require 'drupal/ckeditor_bs_grid:2.0.12' --with-all-dependencies && \
    composer require 'drupal/ckeditor5_template:1.0.8' --with-all-dependencies && \
    composer require 'drupal/ckeditor5_icons:^1.2' --with-all-dependencies && \
    composer require 'drupal/ckeditor5_fullscreen:1.0' --with-all-dependencies && \
    composer require 'drupal/editor_paste_plain:1.0.0-rc1' --with-all-dependencies && \
    composer require 'drupal/decoupled_router:2.0.5' --with-all-dependencies && \
    composer require 'drupal/forum:1.0.2' --with-all-dependencies && \
    composer require 'drupal/jsonapi_site:1.0.2' --with-all-dependencies && \
    composer require 'drupal/key_auth:2.2.0' --with-all-dependencies && \
    composer require 'drupal/pathauto:1.13' --with-all-dependencies && \
    composer require 'drupal/token:1.15' --with-all-dependencies && \
    composer require 'drupal/externalauth:2.0.8' --with-all-dependencies && \
    composer require 'drupal/redirect:1.11' --with-all-dependencies && \
    composer require 'drupal/samlauth:3.11' --with-all-dependencies && \
    composer require 'drupal/mailsystem:4.5' --with-all-dependencies && \
    composer require 'drupal/robotstxt:1.6' --with-all-dependencies && \
    composer require 'drupal/symfony_mailer:1.6.2' --with-all-dependencies && \
    composer require 'drupal/remove_entity_untranslatable_field_validation:1.3' --with-all-dependencies && \
    composer require 'drupal/jsonapi_include:1.8' --with-all-dependencies && \
    composer require 'drupal/menu_admin_per_menu:1.7' --with-all-dependencies && \
    composer require 'drupal/menu_link_attributes:1.5' --with-all-dependencies && \
    composer require 'drupal/quick_node_clone:1.22' --with-all-dependencies && \
    composer require 'drupal/jsonapi_extras:3.26' --with-all-dependencies && \
    composer require 'drupal/fpa:4.0.1' --with-all-dependencies && \
    composer require 'drupal/search_api:1.38' --with-all-dependencies && \
    composer require 'drupal/facets:3.0' --with-all-dependencies && \
    composer require 'drupal/jsonapi_resources:1.3' --with-all-dependencies && \
    composer require 'drupal/jsonapi_search_api:1.0-rc5' --with-all-dependencies && \
    composer require 'drupal/auto_node_translate:3.0.2' --with-all-dependencies && \
    composer require 'drupal/auto_node_translate_amazon:1.0.0-rc1' --with-all-dependencies && \
    composer require 'drupal/ant_bulk:2.0.0-rc4' --with-all-dependencies && \
    composer require 'drupal/devel:5.4.0' --with-all-dependencies
# Drupal 10 note
# drupal/drush_language critical
# RUN --mount=type=cache,target=/var/cache/apt \
#     composer require 'drupal/drush_language:1.0-rc5' --with-all-dependencies

# Clean up unwanted modules and files
RUN rm -rf /opt/drupal/web/modules/contrib/login_destination && \
    rm -rf /opt/drupal/web/modules/contrib/ckeditor_templates && \
    rm -rf /opt/drupal/web/modules/contrib/ckeditor_templates_ui && \
    rm -rf /opt/drupal/web/modules/contrib/ctools && \
    rm -rf /opt/drupal/web/robots.txt && \
    mv /opt/drupal/web/core/install.php /opt/drupal/web/core/install.disable

WORKDIR /opt/drupal

