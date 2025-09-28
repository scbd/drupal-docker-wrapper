# drupal-docker-wrapper

[![CircleCI](https://dl.circleci.com/status-badge/img/gh/scbd/drupal-docker-wrapper/tree/master.svg?style=shield)](
    https://dl.circleci.com/status-badge/redirect/gh/scbd/drupal-docker-wrapper/tree/master
)

Dockerized Drupal base images (Drupal 11 and 10 variants) with common tools and
modules preinstalled to speed up local development and CI/CD.

![Architecture overview](docs/images/overview.svg)

## What this image provides

- Drupal 11 image (root `Dockerfile`) and Drupal 10 image (`d10/Dockerfile`).
- Pinned contrib modules & Drush installed in a dedicated build stage (auditable versions).
- Generated `modules-versions.txt` manifest (direct dependencies) for quick inspection.
- Composer patching enabled (see `Dockerfile` for applied patches) – deterministic (lockfile retained).
- Preinstalled CLI tools: curl, nano, mariadb-client.
- Healthcheck stub (override as needed).

## Layered build strategy (base + modules)

The root `Dockerfile` now has three stages:

1. base-core: Drupal core + system packages + composer configuration (no contrib modules).
2. with-modules: Adds explicit `composer require` lines so versions remain visible in Docker history; writes
   `modules-versions.txt`.
3. final: Carries labels, healthcheck, permissions tightening.

This preserves your desire to SEE module versions in the Dockerfile while still producing a reproducible, immutable
image.

## Why avoid mounting code over the image

Mounting an EFS volume over `/opt/drupal` (or its subpaths containing code) masks the freshly-built image layers and
leaves stale module code in place. Instead only persist truly mutable data (file uploads, private files). Pinned module
upgrades then ship automatically when a new image is rolled out—no manual container exec, no in-place composer runs
required.

Recommended persistent mounts:

```sh
-v drupal-public:/opt/drupal/web/sites/default/files \
-v drupal-private:/opt/drupal/private
```

Avoid mounting `vendor/`, `web/modules/contrib/`, or the project root unless you are in an iterative local dev workflow
(in which case, rebuild frequently or run composer locally instead of inside production containers).

## Quick start (Drupal 11 image)

Replace `VERSION_TAG` (e.g. `11.2.3-v1`).

```sh
# Build
docker build --platform linux/amd64 -t scbd/drupal-docker-wrapper:VERSION_TAG .

# Run (ephemeral code, persistent files)
docker run -d --name drupal -p 8080:80 \
  -v drupal-public:/opt/drupal/web/sites/default/files \
  -v drupal-private:/opt/drupal/private \
  scbd/drupal-docker-wrapper:VERSION_TAG

# Inspect installed (direct) dependency versions
docker exec drupal head -50 /opt/drupal/modules-versions.txt
```

### Drupal 10 variant

```sh
docker build --platform linux/amd64  -f d10/Dockerfile -t scbd/drupal-docker-wrapper:10-VERSION_TAG .
```

### Drush site install example

```sh
docker exec -it drupal bash -lc "vendor/bin/drush si -y standard \
  --db-url='mysql://DB_USER:DB_PASS@DB_HOST:3306/DB_NAME' \
  --site-name='My Site' \
  --account-name=admin \
  --account-pass=admin"
```

## Upgrading a module version

1. Edit the version in the `composer require` line inside the `with-modules` stage of the `Dockerfile`.
2. Rebuild & tag the image.
3. Deploy the new image (ensure code is not volume-mounted).
4. (Optional) Clear Drupal caches / run database updates:

```sh
docker exec drupal vendor/bin/drush updb -y && \
  docker exec drupal vendor/bin/drush cr
```

## Security & hardening notes

- Base image vulnerabilities: track `drupal:11.x-php8.3` upstream updates; rebuild regularly.
- Permissions: directories 755, files 644, writable `sites/default/files` set to 775 (adjust for runtime user if you
  drop root).
- Healthcheck: simple HTTP probe; customize to a lightweight status endpoint for production.
- Lockfile: we retain `composer.lock` (do NOT delete) ensuring deterministic dependency resolution.
- Patch provenance: All applied patches are declared inline in `Dockerfile`; consider mirroring patches internally and
  pinning SHA256 hashes for integrity.
- Supply chain: explicit versions prevent implicit upgrades; periodically review `composer outdated --direct` in a CI
  job for update visibility.

## Optional: local development workflow

If you prefer live-editing code & modules locally:

```sh
docker run -d --name drupal-dev -p 8080:80 \
  -v "$(pwd)/web:/opt/drupal/web" \
  -v drupal-public:/opt/drupal/web/sites/default/files \
  scbd/drupal-docker-wrapper:VERSION_TAG
```

In that case, run `composer install` locally (not inside production container) so production builds remain clean.

## CI/CD (CircleCI)

The provided pipeline can build, lint & smoke-test images; configure Docker Hub credentials to push:

Env vars:

- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`

Add an automated scheduled rebuild (weekly) to pick up upstream security patches.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| New module version not appearing | Code volume mount masking image | Remove code mount; only mount files dirs |
| Composer patch not applied | Patch URL changed or network issue | Mirror patch; verify URL; rebuild |
| High CVE count in scan | Outdated base image packages | Rebuild with newer base tag; maybe dist-upgrade |
| Drush missing | Stage caching issue | Clear build cache (`--no-cache`) and rebuild |
| Composer cannot create `/var/www/.composer/...` | Composer cache not writable | Set writable composer home. |

Note: If you override the container USER or execute composer in a derived image, make sure to:

```sh
mkdir -p /var/www/.composer/cache
chown -R www-data:www-data /var/www/.composer
```

## Directory variants (split build)

If you prefer physical separation instead of a multi-stage single Dockerfile you can use:

- `base/Dockerfile`: core + system tools + composer config.
- `addon/Dockerfile`: starts FROM the published base image (or a locally built tag) and adds pinned modules.

### Build base then addon locally

```sh
# Build base
cd base
docker build -t drupal-base:11.2.3 .
cd ..

# Build addon (uses the locally tagged base)
sed -i '' "s|scbd/drupal-docker-wrapper-base:latest|drupal-base:11.2.3|" addon/Dockerfile
cd addon
docker build -t drupal-addon:11.2.3-mods .
```

Push your base image (e.g. `scbd/drupal-docker-wrapper-base:11.2.3`) first, then the addon image that depends on it.

### Build and push in one step (local)

docker build --platform linux/amd64 -t scbd/drupal-docker-wrapper:latest -t scbd/drupal-docker-wrapper:11.2.4 . --push

## License

This project: MIT (container build scripts). Drupal & contributed modules: GPL-2.0-or-later.

---

Refer to the `Dockerfile` for authoritative module version declarations.
