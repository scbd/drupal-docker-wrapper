# drupal-docker-wrapper

[![CircleCI](https://dl.circleci.com/status-badge/img/gh/scbd/drupal-docker-wrapper/tree/master.svg?style=shield)](
    https://dl.circleci.com/status-badge/redirect/gh/scbd/drupal-docker-wrapper/tree/master
)

Dockerized Drupal 11 base image with common tools and
modules preinstalled to speed up local development and CI/CD.

![Architecture overview](docs/images/overview.svg)

## What this image provides

- Drupal 11 image (root `Dockerfile`).
- Pinned contrib modules & Drush installed in a dedicated build stage (auditable versions).
- Generated `modules-versions.txt` manifest (direct dependencies) for quick inspection.
- Composer patching enabled (see `Dockerfile` for applied patches) – deterministic (lockfile retained).
- Preinstalled CLI tools: curl, gosu, patch, git.
- Healthcheck stub (override as needed).
- **After-start background script** for deferred heavy operations (module reinstall, cleanup, cache rebuild).

## Entrypoint & After-Start Architecture

The container uses a two-phase startup approach:

### Phase 1: Entrypoint (immediate)

The `entrypoint.sh` script runs immediately at container start:

1. Applies any patches from `/opt/drupal/patches/` (skips `patches/old/`)
2. Forks the after-start script to run in 60 seconds
3. Starts Apache immediately (healthcheck unaffected)

### Phase 2: After-Start (60 seconds later)

The `after-start.sh` script runs in the background after Apache is healthy:

1. **Reinstalls modules** with exact versions (as www-data via gosu)
2. **Cleans up deprecated paths** (old modules, robots.txt)
3. **Fixes permissions** on sites/files directories
4. **Rebuilds Drupal cache** (as www-data via gosu)

This approach ensures:

- Fast container startup (Apache available immediately)
- Heavy composer operations don't block healthchecks
- Privilege separation (composer/drush run as www-data, not root)

### Script Structure

```text
scripts/
├── entrypoint.sh      # Main entrypoint (thin - patches + fork after-start)
├── after-start.sh     # Background script (modules, cleanup, perms, cache)
└── lib/
    ├── common.sh      # Shared utilities (log, find_project_root)
    └── patches.sh     # Patch application logic
```

## Layered build strategy (base + modules)

The root `Dockerfile` has three stages:

1. **base-core**: Drupal core (11.2.9/PHP 8.4) + minimal system packages + composer configuration (no contrib modules).
2. **with-modules**: Installs `cweagans/composer-patches` first, then all modules in a single consolidated
   `composer require` for cache efficiency; writes `modules-versions.txt`.
3. **final**: Adds labels, healthcheck, entrypoint wrapper, Apache docroot symlink, and permissions.

This preserves module version visibility in the Dockerfile while producing a reproducible, immutable image.

### Build context exclusions

A `.dockerignore` file excludes sensitive and unnecessary files from the build context:

- Environment files (`.env`, `.env*`)
- Archived patches (`patches/old/`)
- Git, CI/CD, documentation, and IDE files

## Why avoid mounting code over the image

Mounting an EFS volume over `/opt/drupal` (or its subpaths containing code) masks the freshly-built image layers and
leaves stale module code in place. Instead only persist truly mutable data (file uploads, private files). Pinned module
upgrades then ship automatically when a new image is rolled out—no manual container exec, no in-place composer runs
required.

Recommended persistent mounts:

```sh
-v drupal-sites:/opt/drupal/web/sites \
```

Avoid mounting `vendor/`, `web/modules/contrib/`, or the project root unless you are in an iterative local dev workflow
(in which case, rebuild frequently or run composer locally instead of inside production containers).

## Quick start (Drupal 11 image)

Replace `VERSION_TAG` (e.g. `11.2.9-v10`).

```sh
# Build
docker build --platform linux/amd64 -t scbd/drupal-docker-wrapper:VERSION_TAG .

# Run (ephemeral code, persistent files)
docker run -d --name drupal -p 8080:80 \
  -v drupal-sites:/opt/drupal/web/sites \
  scbd/drupal-docker-wrapper:VERSION_TAG

# Inspect installed (direct) dependency versions
docker exec drupal head -50 /opt/drupal/modules-versions.txt
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
4. The after-start script will automatically rebuild caches ~60 seconds after startup.

## Security & hardening notes

- **Base image**: Track `drupal:11.x-php8.4` upstream updates; rebuild regularly.
- **Build context**: `.dockerignore` excludes `.env*`, `patches/old/`, git/CI files from the image.
- **Permissions**: Directories 755, files 644, writable `sites/default/files` set to 775.
- **Privilege separation**: After-start operations run as www-data via gosu, not root.
- **Healthcheck**: Simple HTTP probe; customize to a lightweight status endpoint for production.
- **Lockfile**: We retain `composer.lock` (do NOT delete) ensuring deterministic dependency resolution.
- **Patch provenance**: Patches declared inline in `Dockerfile`; archived in `patches/old/` when no longer needed.
- **Supply chain**: Explicit versions prevent implicit upgrades; periodically review `composer outdated --direct` in a
  CI job for update visibility.

## CI/CD (CircleCI)

The provided pipeline builds, lints, and smoke-tests the Drupal 11 image.

### Testing Locally

Before pushing changes, test the full CI pipeline locally:

```sh
./ci/test-ci-locally.sh
```

This simulates the CircleCI workflow without pushing to Docker Hub.

### Production Deployment

Configure Docker Hub credentials to enable automated pushes on tagged releases:

Env vars:

- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`

Uncomment the `push_images` job in `.circleci/config.yml` to enable tag-based releases.

Add an automated scheduled rebuild (weekly) to pick up upstream security patches.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| New module version not appearing | Code volume mount masking image | Remove code mount; only mount files dirs |
| Composer patch not applied | Patch URL changed or network issue | Mirror patch; verify URL; rebuild |
| High CVE count in scan | Outdated base image packages | Rebuild with newer base tag; maybe dist-upgrade |
| Drush missing | Stage caching issue | Clear build cache (`--no-cache`) and rebuild |
| After-start not running | Check logs for errors | `docker logs <container>` - look for `[after-start]` messages |
| Exit code 137 at startup | OOM during composer | After-start runs as www-data; check container memory limits |

Note: If you override the container USER or execute composer in a derived image, make sure to:

```sh
mkdir -p /var/www/.composer/cache
chown -R www-data:www-data /var/www/.composer
```

### Build and push in one step (local)

```sh
# for dev and stg
docker build --platform linux/amd64 -t scbd/drupal-docker-wrapper:${env}-${VERSION_TAG} . --push

#prod
docker build --platform linux/amd64 -t scbd/drupal-docker-wrapper:${VERSION_TAG} -t scbd/drupal-docker-wrapper:latest . --push
```

## License

This project: MIT (container build scripts). Drupal & contributed modules: GPL-2.0-or-later.

---

Refer to the `Dockerfile` for authoritative module version declarations.
