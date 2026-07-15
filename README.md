# drupal-docker-wrapper

[![CI](https://github.com/scbd/drupal-docker-wrapper/actions/workflows/ci.yml/badge.svg)](
    https://github.com/scbd/drupal-docker-wrapper/actions/workflows/ci.yml
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

1. **Applies patches** from `/opt/drupal/patches/` via `apply_patches_if_present`. Each `*.patch` (excluding
   `patches/old/`) is applied to the base directory it targets — the Drupal root for core/docroot-relative patches, or
   the matching module/theme under `web/modules/{contrib,custom}` / `web/themes/{contrib,custom}` for module-relative
   (composer-patches-style) patches. This runs synchronously before Apache starts so a volume-mounted contrib tree —
   which shadows the image's build-time composer-patches — is still patched. Idempotent: patches already present are
   detected via a reverse dry-run and skipped (marker: `.<patch-name>.applied` in the patched dir).
2. Forks the after-start script to run in 60 seconds.
3. Starts Apache immediately (healthcheck unaffected), chaining to the upstream Drupal entrypoint.

### Phase 2: After-Start (60 seconds later)

The `after-start.sh` script runs in the background ~60s after Apache starts. It is **gated by a per-version marker**
(`/tmp/after-start-<version>.complete`, version read from `package.json`) so its one-time work runs once per container
start per image version:

1. **Repairs composer-managed modules** — walks every module under `web/modules/contrib`, compares each installed
   version against `composer.lock`, removes any stale or mis-owned module, and runs `composer install` (as www-data) to
   restore the pinned versions. Skipped by `DRUPAL_SKIP_MODULE_REPAIR=1`; forced for all modules by
   `DRUPAL_AFTER_START_FORCE_MODULE_REPAIR=1`.
2. **Cleans up deprecated paths** (e.g. scaffolded `web/robots.txt`).
3. **Hardens permissions** (in the background): code dirs `root:www-data` 755/644, `temp/` `root:root` 700, all
   `.htaccess` 644, and only `sites/*/files` left writable (`www-data:www-data` 775).
4. **Rebuilds Drupal cache** via `drush cache:rebuild` (as www-data via gosu).

> The module-repair step exists to re-sync a volume-mounted `web/modules` against the image's `composer.lock` at
> runtime. Adopting the [`modules/custom`-only mount](#volume-mounts-current-state--recommendation) makes contrib come
> straight from the image, so this step becomes a fast no-op for contrib.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DRUPAL_SKIP_MODULE_REPAIR` | `0` | Set to `1` to skip module repair in after-start script. |
| `DRUPAL_AFTER_START_FORCE_MODULE_REPAIR` | `0` | Set to `1` to force module repair even if versions match. |

> **Note:** The after-start script **is active** — it is forked by `entrypoint.sh` and these variables take effect.
> Module repair runs once per container start per image version (marker-gated). The entrypoint *patch-application* step
> (Phase 1) is also active and runs on every start (idempotent).

Example usage:

```sh
# Skip module repair for faster startup
docker run -d --name drupal -p 8080:80 \
  -e DRUPAL_SKIP_MODULE_REPAIR=1 \
  -v drupal-sites:/opt/drupal/web/sites \
  scbd/drupal-docker-wrapper:VERSION_TAG
```

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

1. **base-core**: Drupal core (11.x.x/PHP 8.4) + minimal system packages + composer configuration (no contrib modules).
2. **with-modules**: Installs `cweagans/composer-patches` first, then all modules in a single consolidated
   `composer require` for cache efficiency; writes `modules-versions.txt`.
3. **final**: Adds labels, healthcheck, entrypoint wrapper, Apache docroot symlink, and permissions.

This preserves module version visibility in the Dockerfile while producing a reproducible, immutable image.

### Build context exclusions

A `.dockerignore` file excludes sensitive and unnecessary files from the build context:

- Environment files (`.env`, `.env*`)
- Archived patches (`patches/old/`)
- Git, CI/CD, documentation, and IDE files

## Volume mounts (current state & recommendation)

> **Path note:** the `final` stage of the `Dockerfile` symlinks `/var/www/html` → `/opt/drupal/web` (the real docroot).
> So `/var/www/html/modules` *is* `/opt/drupal/web/modules`, `/var/www/html/sites` *is* `/opt/drupal/web/sites`, and so
> on. Mounts written against either path hit the same files.

### Current state (dmsm Swarm multi-site stacks)

The deployed `drupal` service (defined by the `dmsm` Swarm stack templates) bind-mounts five host/EFS paths per site:

```yaml
volumes:
  - '…/{env}/{multiSiteCode}/php/custom.ini:/usr/local/etc/php/conf.d/custom.ini'
  - '…/{env}/{multiSiteCode}/modules:/var/www/html/modules'
  - '…/{env}/{multiSiteCode}/sites:/var/www/html/sites'
  - '…/{env}/{multiSiteCode}/drush:/var/www/html/drush'
  - '…/{env}/{multiSiteCode}/temp:/opt/drupal/temp'
```

| Host path (per `{env}/{multiSiteCode}`) | Container path | Purpose | Verdict |
|---|---|---|---|
| `…/php/custom.ini` | `/usr/local/etc/php/conf.d/custom.ini` | PHP runtime overrides | ✅ config file — doesn't mask code |
| `…/modules` | `/var/www/html/modules` | **all** modules (contrib + custom) | ⚠️ **masks image-built code** |
| `…/sites` | `/var/www/html/sites` | multisite config + uploaded files | ✅ mutable per-site data |
| `…/drush` | `/var/www/html/drush` | drush site aliases (`@lk`, `@be`, …) | ✅ config |
| `…/temp` | `/opt/drupal/temp` | script checkpoints, backups, error logs | ✅ mutable working data |

### The problem with mounting `…/modules`

Mounting the **whole** `…/modules` directory over `/opt/drupal/web/modules` hides everything the image built there:

- the ~40 pinned contrib modules installed in the `with-modules` stage of the `Dockerfile`, and
- the `.<module>.hash` integrity files the build generates under `modules/contrib`.

This defeats the entire pinned-version strategy: rolling out a new image with upgraded contrib versions changes nothing
at runtime, because the stale EFS copy shadows it. It is also why the `copy-modules-env-to-env` script exists — the
contrib tree has to be hand-seeded onto EFS and copied between environments precisely *because* the image's own copy is
never seen.

Only the **custom** modules genuinely need to come from the host — e.g. `bioland` (enabled via `drush en bioland`) and
the `scbd_*` modules, which live in their own repos and are not part of the image. Contrib should come from the image.

### Recommendation (TODO)

Mount **only `modules/custom`** so contrib + integrity hashes come from the image and just the custom modules are
overlaid from EFS:

```diff
-  - '…/{env}/{multiSiteCode}/modules:/var/www/html/modules'
+  - '…/{env}/{multiSiteCode}/modules/custom:/var/www/html/modules/custom'
```

Migration steps:

1. On EFS, create `…/modules/custom/` containing **only** the custom modules (`bioland`, `scbd_field`, …); discard the
   seeded contrib copies under `…/modules/contrib`.
2. Update the `dmsm` Swarm stack templates (the `drupal-stack.yml` template and each per-env multi-site stack) to the
   `modules/custom` mount above. Docker creates the bind-mount target, so `/opt/drupal/web/modules/contrib` keeps the
   image's copy while `modules/custom` is overlaid.
3. Narrow `copy-modules-env-to-env` to sync `modules/custom` only (contrib now ships with the image).
4. Redeploy and verify: `docker exec <c> ls /opt/drupal/web/modules/contrib` should match `modules-versions.txt`, and
   `drush pml --type=module --status=enabled` should still list the custom modules.

The other four mounts (`custom.ini`, `sites`, `drush`, `temp`) are fine to keep — they carry config or mutable data, not
image-built code. Never mount `vendor/`, `web/core/`, or `modules/contrib/` over the image.

## Versioning

The image version (in `package.json` and the release git tag) tracks the **Drupal core version** it ships:

- A core bump is released as the **bare core version** — e.g. `11.x.x` — *even when contrib modules are updated
  alongside it*, since those module updates ship as part of that core release.
- A `-vN` suffix is appended **only** for a *subsequent* wrapper iteration on the **same** Drupal core version: a
  contrib module bump, a script change, or a `package.json` / dependency update made **without** moving core. Increment
  `N` for each such iteration.

| Tag | Meaning |
|-----|---------|
| `11.x.x` | Drupal core 11.x.x (initial wrapper build for this core; module updates included) |
| `11.x.x-v1` | First wrapper change on top of 11.x.x (module/script/package update, core unchanged) |
| `11.x.x-v2` | Second such change, still on core 11.x.x |

Keep `package.json` and `package-lock.json` in sync with this version. The GitHub Actions release job
derives the published Docker tag from the GitHub Release tag (`github.event.release.tag_name`), so tag
releases match — e.g. publish a release with tag `11.x.x`.

## Local development on Apple Silicon (Mac, ARM64)

This image is **`linux/amd64`-only** — it does **not** build natively for `arm64`. The `Dockerfile`
installs AWS CLI v2 from the hardcoded x86_64 archive (`awscli-exe-linux-x86_64.zip`), and production
runs on amd64, so a native `arm64` build would ship a wrong-architecture `aws` binary that fails at
runtime. On an Apple Silicon Mac you build and run the amd64 image under emulation.

**One-time setup (Docker Desktop):**

1. Enable Rosetta for much faster x86_64 emulation: **Settings → General → "Use Rosetta for
   x86_64/amd64 emulation on Apple Silicon"** (requires macOS 13+ and the VirtioFS file sharing
   implementation). Without Rosetta, Docker falls back to QEMU, which builds and runs noticeably slower
   but still works.
2. (Optional) Make `linux/amd64` the default for every Docker command so you never forget the flag —
   this is also what makes `./ci/test-ci-locally.sh` (whose `docker build` omits `--platform`) build the
   correct architecture on Apple Silicon:

   ```sh
   export DOCKER_DEFAULT_PLATFORM=linux/amd64
   ```

   Add it to your `~/.zshrc` to persist it across shells.

**Then build and run as below** — every `docker build`/`docker run` for this image must target
`--platform linux/amd64` on Apple Silicon (already included in the commands that follow). You will see a
`requested image's platform (linux/amd64) does not match the detected host platform` warning at `run`
time; that is expected and harmless under emulation.

> The amd64-built image runs fine for local Drupal development (Apache, PHP, Drush, contrib modules).
> Emulation only costs build/startup speed, not correctness.

## Quick start (Drupal 11 image)

Replace `VERSION_TAG` (e.g. `11.x.x`, or `11.x.x-v1` for a wrapper iteration — see [Versioning](#versioning)).
On Apple Silicon, see [Local development on Apple Silicon](#local-development-on-apple-silicon-mac-arm64) first.

```sh
# Build
docker build --platform linux/amd64 -t scbd/drupal-docker-wrapper:VERSION_TAG .

# Run (ephemeral code, persistent files — single-container smoke test)
# In production this image runs under the dmsm Swarm multi-site stack with bind mounts;
# see "Volume mounts (current state & recommendation)" above.
# --platform is required on Apple Silicon (omit it on amd64 hosts, or set DOCKER_DEFAULT_PLATFORM).
docker run -d --platform linux/amd64 --name drupal -p 8080:80 \
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

## CI/CD (GitHub Actions)

The pipeline in [`.github/workflows/ci.yml`](.github/workflows/ci.yml) builds, lints, and smoke-tests the Drupal 11 image.

### Testing Locally

Before pushing changes, test the full CI pipeline locally:

```sh
./ci/test-ci-locally.sh
```

This simulates the GitHub Actions workflow without pushing to Docker Hub.

### Production Deployment

Configure Docker Hub credentials to enable automated pushes on tagged releases:

Repository secrets (Settings → Secrets and variables → Actions):

- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`

Uncomment the `push-images` job in [`.github/workflows/ci.yml`](.github/workflows/ci.yml) to enable
release-based publishing. It runs when a GitHub Release is published with a Drupal 11 tag (e.g. `11.x.x`).

Add an automated scheduled rebuild (weekly) to pick up upstream security patches.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| New contrib version not appearing | `…/modules` bind mount masking image | Mount `modules/custom` only — see [Volume mounts](#volume-mounts-current-state--recommendation) |
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
