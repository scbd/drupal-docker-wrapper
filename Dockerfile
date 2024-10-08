
FROM drupal:10.3.5-php8.3

WORKDIR /opt/drupal

RUN  \
    --mount=type=cache,target=/var/cache/apt \
    apt update -y && \
    apt install curl nano mariadb-client -y

#d11
RUN \
    --mount=type=cache,target=/var/cache/apt \
    composer require 'drupal/auditfiles:4.2.0' --with-all-dependencies  && \
    composer require 'drush/drush:13.0.1.0'  --with-all-dependencies  && \
    composer require 'drupal/admin_toolbar:3.5.0' --with-all-dependencies  && \
    composer require 'drupal/ckeditor_bs_grid:2.0.12' --with-all-dependencies  && \
    composer require 'drupal/ckeditor5_template:1.0.8' --with-all-dependencies  && \
    composer require 'drupal/decoupled_router:2.0.5' --with-all-dependencies  && \
    composer require 'drupal/forum:1.0.2' --with-all-dependencies  && \
    composer require 'drupal/jsonapi_site:1.0.2' --with-all-dependencies  && \
    composer require 'drupal/key_auth:2.2.0' --with-all-dependencies  && \
    composer require 'drupal/pathauto:1.13' --with-all-dependencies  && \
    composer require 'drupal/token:1.15' --with-all-dependencies  && \
    composer require 'drupal/externalauth:2.0.6' --with-all-dependencies  && \
    composer require 'drupal/redirect: 1.10' --with-all-dependencies  && \
    composer require 'drupal/samlauth:3.10' --with-all-dependencies  && \
    composer require 'drupal/mailsystem:4.5' --with-all-dependencies  && \
    composer require 'drupal/robotstxt:1.6' --with-all-dependencies  && \
    composer require 'drupal/symfony_mailer:1.5.0' --with-all-dependencies  && \
    composer require 'drupal/remove_entity_untranslatable_field_validation:1.3' --with-all-dependencies  && \
    composer require 'drupal/jsonapi_include:1.8' --with-all-dependencies  && \
    composer require 'drupal/menu_admin_per_menu:1.6' --with-all-dependencies  && \
    composer require 'drupal/ckeditor5_fullscreen:1.0.0-beta10' --with-all-dependencies  && \
    composer require 'drupal/menu_link_attributes:1.5' --with-all-dependencies

#d10
RUN \
    --mount=type=cache,target=/var/cache/apt \
    composer require 'drupal/editor_paste_plain:1.0.0-beta1' --with-all-dependencies  && \
    composer require 'drupal/fpa:4.0.0' --with-all-dependencies  && \
    composer require 'drupal/jsonapi_extras:3.25' --with-all-dependencies  && \
    composer require 'drupal/administerusersbyrole:3.4' --with-all-dependencies  && \
    composer require 'drupal/quick_node_clone:1.18'  --with-all-dependencies  && \
    composer require 'drupal/drush_language:1.0-rc5' --with-all-dependencies 

RUN rm -rf /opt/drupal/web/modules/contrib/login_destination
RUN rm -rf /opt/drupal/web/modules/contrib/ckeditor_templates
RUN rm -rf /opt/drupal/web/modules/contrib/ckeditor_templates_ui
RUN rm -rf /opt/drupal/web/modules/contrib/ctools
RUN rm -rf /opt/drupal/web/robots.txt
RUN mv /opt/drupal/web/core/install.php /opt/drupal/web/core/install.disable

WORKDIR /opt/drupal

# ENV DRUPAL_VERSION="drupal:10.3.2-php8.3" PHP_VERSION="8.3" 


