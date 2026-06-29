---
type: project
references: [docs/CONTEXT.md, docs/architecture.md, docs/adr/]
date: 2026-06-24
---

# Drupal Docker Wrapper - Product Requirements

## Problem Statement

Teams across bioland need a Drupal 11 environment that is identical everywhere: the same core, the
same contrib modules at the same versions, the same CLI tooling, whether a developer is running it
on a laptop, CI is smoke-testing it, or it is deployed under the production Swarm stacks. Building
that from the upstream `drupal:11.x-php8.4` image by hand is slow and drifts: each person resolves
contrib versions differently, security advisories and patches are applied inconsistently, and a
Drupal site that bind-mounts its module directory from shared storage quietly diverges from whatever
the team thinks it is running. Nobody wants to wait on a long composer install before the container
is usable, and nobody wants the web server able to overwrite its own code.

## Solution

A reusable Drupal 11 base Docker image (`scbd/drupal-docker-wrapper`) that pins every contrib module
and Drush to an exact version at build time, ships a manifest and per-module integrity hashes for
auditability, and starts in two phases: Apache comes up immediately while a background after-start
script does the heavy, privilege-sensitive provisioning (re-syncing modules against the lockfile,
cleaning deprecated paths, hardening permissions, rebuilding caches) once per container per image
version. Other bioland repos build their sites on top of this image; the custom modules and the
bioland-head Nuxt frontend layer onto it without being part of it.

## User Stories

1. As a Drupal developer, I want a base image with core and the standard contrib set already
   installed, so that I can start working without resolving dependencies myself.
2. As a developer, I want the exact module versions visible in the `Dockerfile`, so that I can see
   what I am getting without running the image.
3. As a developer, I want a `modules-versions.txt` manifest inside the image, so that I can inspect
   direct dependency versions with a single command.
4. As a developer, I want Apache to be serving within seconds of `docker run`, so that I am not
   blocked waiting on composer during startup.
5. As a developer, I want Drush and common CLI tools (curl, jq, git, patch, mysql client, aws cli)
   preinstalled, so that I can run site operations and debugging inside the container.
6. As a developer, I want a documented `drush si` example, so that I can install a site quickly for a
   smoke test.
7. As a developer running locally, I want to skip the runtime module repair, so that my container
   starts faster when I know my module tree is correct (`DRUPAL_SKIP_MODULE_REPAIR=1`).
8. As a developer debugging a drift, I want to force module repair for all modules, so that I can
   restore the pinned tree on demand (`DRUPAL_AFTER_START_FORCE_MODULE_REPAIR=1`).
9. As a platform engineer, I want contrib modules pinned to exact versions, so that builds are
   reproducible and no implicit upgrade sneaks in between rebuilds.
10. As a platform engineer, I want the lockfile retained in the image, so that runtime repair has a
    source of truth to compare installed modules against.
11. As a platform engineer, I want the web server unable to write to code directories, so that a
    compromised PHP process cannot modify modules, core, or `.htaccess` files.
12. As a platform engineer, I want only `sites/*/files` writable at runtime, so that uploads work
    while everything else stays read-only.
13. As a platform engineer, I want composer and drush to run as www-data, not root, so that
    provisioning follows least privilege.
14. As a platform engineer deploying under Swarm, I want clear guidance on which paths are safe to
    bind-mount, so that I do not mask the image's pinned contrib with a stale EFS copy.
15. As a platform engineer, I want the heavy startup work to run once per container per image
    version, so that a container restart does not redo module repair and cache rebuild needlessly.
16. As a platform engineer, I want an upgrade to a new image version to re-run the one-time work, so
    that upgraded modules and a fresh cache take effect.
17. As a CI maintainer, I want the image built and smoke-tested on every change, so that a broken
    build or a missing key module is caught before release.
18. As a CI maintainer, I want markdown and Dockerfile linting in the pipeline, so that the docs and
    the build file stay clean.
19. As a release manager, I want the published Docker tag derived from the git tag, so that the
    image version always matches the release.
20. As a release manager, I want a versioning scheme that ties the image to the Drupal core it
    ships, with a `-vN` suffix for wrapper-only iterations, so that consumers can tell a core bump
    from a module or script change.
21. As a security reviewer, I want `.env*` and archived patches excluded from the build context, so
    that secrets and dead patches never enter the image.
22. As a security reviewer, I want a healthcheck that reports container health independently of
    provisioning, so that orchestration sees the container as up as soon as Apache serves.
23. As a maintainer, I want a way to apply Drupal patches, so that I can carry fixes that are not yet
    in a contrib release (composer patching at build time; a startup patch mechanism that can be
    re-enabled if needed).
24. As a maintainer, I want to suppress specific security advisories temporarily with an explicit,
    documented reason, so that a Critical core fix can build before downstream packages ship their
    own patched releases.
25. As an operator, I want troubleshooting guidance for common failure modes (masked contrib, OOM
    during composer, missing drush, after-start not running), so that I can diagnose without reading
    the scripts.
26. As a consumer building a derived image, I want documented composer cache ownership steps, so
    that composer works when I change the USER or run composer in my own layer.

## Implementation Decisions

- **Multi-stage build with module installs isolated.** Three stages: `base-core` (core, system
  packages, GD-with-AVIF, composer config), `with-modules` (the composer-patches plugin, then one
  consolidated `composer require` of all pinned modules plus Drush, then the manifest and integrity
  hashes), and `final` (production php.ini, labels, docroot symlink, scripts, healthcheck). Isolating
  module installs keeps a module bump from invalidating the core layer's cache. See
  `docs/adr/0002-...`.
- **Exact pins inline in the Dockerfile.** Every contrib module and Drush carry an exact version
  string in the single `composer require`. The `composer.lock` is retained in the image and is the
  runtime source of truth.
- **The composer-patches plugin is required before patched packages.** Patching is wired before any
  module is pulled so patches can apply during the module install.
- **Two-phase startup.** `entrypoint.sh` runs as root, forks the after-start script (60s delay), and
  exec-chains the upstream Drupal entrypoint so Apache starts immediately. `after-start.sh` runs the
  heavy work in the background. See `docs/adr/0003-...`.
- **Per-version marker gating.** After-start work is gated on `/tmp/after-start-<version>.complete`,
  with the version read from `package.json`. Stale markers are cleared on a new run so an image
  upgrade re-runs the one-time work. See `docs/adr/0004-...`.
- **Runtime module repair against the lockfile.** After-start walks every contrib module, compares
  its installed version against `composer.lock`, removes stale or mis-owned directories, and runs
  `composer install` (as www-data) to restore the pins. Controlled by `DRUPAL_SKIP_MODULE_REPAIR`
  and `DRUPAL_AFTER_START_FORCE_MODULE_REPAIR`.
- **Privilege separation and permission hardening.** Code is `root:www-data` read-only (dirs 755,
  files 644), `temp/` is `root:root` 700, every `.htaccess` is forced to 644, and only
  `sites/*/files` is writable (`www-data:www-data` 775). Composer and drush run as www-data via
  gosu. The previous `ensure_runtime_ownership` (which made code www-data-writable) was removed for
  security.
- **Startup patch application is implemented but disabled.** `lib/patches.sh` is complete (multiple
  `patch` strategies, applied markers, ignores `patches/old/`), but its call in `entrypoint.sh` is
  commented out. Build-time composer patching remains the active path.
- **Healthcheck independent of provisioning.** A simple HTTP probe on `/`, with a 40s start period,
  so the container is reported healthy as soon as Apache serves regardless of after-start progress.
- **CI on GitHub Actions.** `lint` (markdownlint + hadolint) gates `build-test` (docker build +
  smoke-test). The `push-images` job derives the tag from the GitHub Release (`github.event.release.tag_name`)
  and is currently commented out. Build context exclusions live in `.dockerignore`.
- **Versioning tracks Drupal core.** The image version (in `package.json` and the git tag) is the
  core version, with a `-vN` suffix only for a later wrapper iteration on the same core.
- **Temporary advisory ignores (BL-695).** Three guzzle/psr7 advisories are suppressed in
  `base-core` so the Critical Drupal 11.3.12 core fix can build before patched releases land in
  core's ranges; documented inline to be removed (Drupal #3599842).

## Testing Decisions

- **Test external behaviour of the built image, not script internals.** The smoke test
  (`ci/smoke-test.sh`) runs the actual image and asserts observable facts: PHP runs, Drush reports a
  version, and key contrib module directories (`jsonapi_extras`, `search_api`) exist. This is the
  right seam because it exercises the real artifact a consumer pulls.
- **Lint the build and docs.** `ci/lint.sh` runs markdownlint and hadolint, with a hadolint
  fallback (local binary or docker image) so it works in restricted CI containers.
- **Local pipeline parity.** `ci/test-ci-locally.sh` runs the same lint -> build -> smoke-test
  sequence locally so a developer can reproduce CI before pushing.
- **Prior art.** The smoke test is the model to copy for any new image-level assertion: start a
  container, exec a check, assert on its output or filesystem. Keep checks observable and version
  agnostic where possible.

## Success Metrics

- Apache passes its healthcheck within the 40s start period on a cold `docker run` (baseline: a
  blocking install could take minutes).
- A fresh `docker run` of a published tag yields an installed contrib tree whose versions match
  `modules-versions.txt` and the inline `Dockerfile` pins (0 drift).
- After-start runs its one-time work exactly once per container per image version (the marker is
  present after the first run; a restart logs "already complete").
- CI fails the build when a key module directory is missing or PHP/Drush are broken (smoke test
  catches it before any publish).
- 0 occurrences of the web user being able to write to `web/core`, `web/modules`, `vendor`, or any
  `.htaccess` after hardening completes.
- Build context contains no `.env*` or archived patch files (verified by `.dockerignore`).

## Out of Scope

- The custom modules themselves (`bioland`, `scbd_*`) - they live in their own repos and are
  overlaid at runtime, not built into the image.
- The bioland-head Nuxt frontend - it consumes the Drupal JSON:API but is a separate product.
- The dmsm Swarm stack definitions and EFS provisioning - the deployment substrate lives outside
  this repo; this repo only documents the mount contract it expects.
- Site installation and content - the image provides Drush and an example, but installing and
  seeding a site is the consumer's job.
- The MySQL database - external, provided by the runtime.
- Automated weekly base-image rebuilds and re-enabling the publish job - desired (noted in the
  README) but not yet implemented.

## Further Notes

The central design choice is reproducibility under a runtime that bind-mounts module storage. The
build pins everything; the after-start phase exists to re-assert those pins when a mount has drifted.
Adopting the `modules/custom`-only mount (the README's recommendation) would make runtime contrib
repair a fast no-op and remove the main reason the image's pinning can be silently defeated in
production.
