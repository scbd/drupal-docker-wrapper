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
contrib versions differently, and security advisories and patches are applied inconsistently. Nobody
wants to wait on a long composer install before the container is usable, and nobody wants the web
server able to overwrite its own code.

## Solution

A reusable Drupal 11 base Docker image (`scbd/drupal-docker-wrapper`) that pins every contrib module
and Drush to an exact version at build time and ships a `modules-versions.txt` manifest for
auditability. The deployed Swarm stack bind-mounts only five paths per site - `custom.ini`,
`modules/custom`, `sites`, `drush`, and `temp` - so core, contrib, and `vendor` always come from the
image and cannot drift at runtime. The image starts in two phases: Apache comes up immediately while
a background after-start script does the remaining privilege-sensitive provisioning (cleaning
deprecated paths, hardening the image's own code permissions) on every start. Other bioland repos
build their sites on top of this image; the custom
modules and the bioland-head Nuxt frontend layer onto it without being part of it.

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
7. As a platform engineer, I want contrib modules pinned to exact versions, so that builds are
   reproducible and no implicit upgrade sneaks in between rebuilds.
8. As a platform engineer, I want the `composer.lock` retained in the image, so that the exact,
   build-time-resolved dependency graph is auditable at any time, independent of what any single
   `composer require` line shows.
9. As a platform engineer, I want the web server unable to write to code directories, so that a
   compromised PHP process cannot modify modules, core, or `.htaccess` files.
10. As a platform engineer, I want only `sites/*/files` writable at runtime, so that uploads work
    while everything else stays read-only.
11. As a platform engineer, I want composer and drush to run as www-data, not root, so that
    provisioning follows least privilege.
12. As a platform engineer deploying under Swarm, I want the bind-mount contract documented exactly
    (only `custom.ini`, `modules/custom`, `sites`, `drush`, and `temp` are mounted per site), so
    that a stack definition never widens the mount to the whole `modules` tree and puts the mount
    in competition with the image's own pinned `web/core`, `web/modules/contrib`, and `vendor`.
13. As a platform engineer, I want the expensive `sites/` permission pass to run once per image
    version per mounted volume, so that an ordinary container restart or scale-out does not repeat
    the EFS-wide walk needlessly.
14. As a platform engineer, I want an image upgrade to re-run the volume-backed permission work, so
    that a volume carrying an older version's marker gets re-hardened under the new image's
    contents.
15. As a CI maintainer, I want the image built and smoke-tested on every change, so that a broken
    build or a missing key module is caught before release.
16. As a CI maintainer, I want markdown and Dockerfile linting in the pipeline, so that the docs and
    the build file stay clean.
17. As a release manager, I want the published Docker tag derived from the git tag, so that the
    image version always matches the release.
18. As a release manager, I want a versioning scheme that ties the image to the Drupal core it
    ships, with a `-vN` suffix for wrapper-only iterations, so that consumers can tell a core bump
    from a module or script change.
19. As a security reviewer, I want `.env*` and archived patches excluded from the build context, so
    that secrets and dead patches never enter the image.
20. As a security reviewer, I want a healthcheck that reports container health independently of
    provisioning, so that orchestration sees the container as up as soon as Apache serves.
21. As a maintainer, I want a way to apply Drupal patches, so that I can carry fixes that are not yet
    in a contrib release: composer patching at build time for contrib, and an optional startup patch
    step for the bind-mounted `modules/custom` tree that never blocks Apache if it fails.
22. As a maintainer, I want to suppress specific security advisories temporarily with an explicit,
    documented reason, so that a Critical core fix can build before downstream packages ship their
    own patched releases.
23. As an operator, I want troubleshooting guidance for common failure modes (the readiness probe
    timing out before Apache answers, missing drush, after-start not running), so that I can
    diagnose without reading the scripts.
24. As a consumer building a derived image, I want documented composer cache ownership steps, so
    that composer works when I change the USER or run composer in my own layer.

## Implementation Decisions

- **Multi-stage build with module installs isolated.** Three stages: `base-core` (core, system
  packages, GD-with-AVIF, composer config), `with-modules` (the composer-patches plugin, then one
  consolidated `composer require` of all pinned modules plus Drush, then the `modules-versions.txt`
  manifest via `composer show --direct`), and `final` (production php.ini, labels, docroot symlink,
  scripts, healthcheck). Isolating module installs keeps a module bump from invalidating the core
  layer's cache. See `docs/adr/0002-...`.
- **Exact pins inline in the Dockerfile.** Every contrib module and Drush carry an exact version
  string in the single `composer require`. The `composer.lock` is retained in the image as the
  record of that build-time-resolved dependency graph; nothing reads it at runtime.
- **The composer-patches plugin is required before patched packages.** Patching is wired before any
  module is pulled so patches can apply during the module install.
- **Two-phase startup, gated on readiness rather than a fixed delay.** `entrypoint.sh` runs as root,
  forks a background job that polls `http://127.0.0.1/` until the web server answers - any HTTP
  status counts as ready, including 301/403/500 - before running `after-start.sh`, and exec-chains
  the upstream Drupal entrypoint so Apache starts immediately. The poll's timeout, interval, and
  probe URL are overridable via `DRUPAL_AFTER_START_READY_TIMEOUT` (default 120s),
  `DRUPAL_AFTER_START_READY_INTERVAL` (default 2s), and `DRUPAL_AFTER_START_READY_URL`, each
  validated with a logged fallback on a bad value. See `docs/adr/0003-...`.
- **No gating, because nothing expensive is left.** After-start touches no bind mount: deprecated-path
  cleanup and image-resident code hardening (`harden_image_code`) both act only on paths that ship in
  the image, on local disk, so they are cheap to repeat and run unconditionally on every start. There
  is no completion marker, no marker directory, and no stale-marker purge to reason about. See
  `docs/adr/0009-...`.
- **No cache rebuild in the container.** `after-start.sh` used to run `drush cache:rebuild` with no
  site URI, which bootstraps only the default site, gated on `web/sites/default/settings.php`
  existing, which a multisite install may not have. On this image's only real deployment topology
  (multisite) it was a no-op or rebuilt one arbitrary site, so it was removed. A per-site cache
  rebuild is still required after a module or patch change; it is now a deploy-process
  responsibility, run per site through the mounted drush aliases (`@lk`, `@be`, ...). See
  `docs/adr/0007-...`.
- **No runtime composer invocation.** The runtime module-repair step that used to compare installed
  contrib against `composer.lock` and re-run `composer install` was removed, along with the
  `DRUPAL_SKIP_MODULE_REPAIR` and `DRUPAL_AFTER_START_FORCE_MODULE_REPAIR` variables that controlled
  it. It is unneeded: the deployed stack bind-mounts only `modules/custom`, never the whole `modules`
  directory, so `web/modules/contrib`, `web/core`, and `vendor` always come from the image and cannot
  drift underneath it.
- **Privilege separation and permission hardening, confined to image code.** The image's own code -
  `web/core`, `web/modules/contrib`, `web/themes`, `web/profiles`, `web/libraries`, `vendor`, and the
  root-level `web/*` files - is made `root:www-data` read-only (dirs 755, files 644, which covers the
  `.htaccess` files inside those trees and `web/.htaccess`), with the execute bit restored on
  `vendor/bin` entries and their targets. Nothing under the five bind mounts is touched: `web/sites`,
  `modules/custom`, `drush`, `temp`, and `custom.ini` belong to the deploy. In particular **nothing in
  the container tightens `settings*.php` or `services*.yml` any more** - a mount that ships
  `settings.php` world-readable will stay world-readable, and that hardening has to happen where the
  mount is defined or in the external per-site script that already owns `.htaccess` under
  `sites/*/files`. `gosu` is preserved in the image so an operator can run drush as www-data by hand
  (e.g. `gosu www-data vendor/bin/drush @lk cache:rebuild`); no script invokes it. The previous
  `ensure_runtime_ownership` (which made code www-data-writable) was removed for security. There is
  also no blanket `.htaccess` pass across the project root any more: it walked the EFS-backed
  `sites/*/files` upload trees on every start and changed no durable permission. See
  `docs/adr/0008-...` and `docs/adr/0009-...`.
- **Startup patch application is active, and optional.** `lib/patches.sh` (multiple `patch`
  strategies, applied markers, ignores `patches/old/`) ships in the image and is invoked from
  `entrypoint.sh` before Apache starts. It degrades safely on either failure mode: a missing
  `lib/patches.sh` is logged and skipped rather than killing PID 1, and a failing patch step is
  logged and does not stop Apache from serving. Build-time composer patching (via
  `cweagans/composer-patches`) remains the path for patches published against a contrib release;
  this mechanism exists for patches that need to apply against the bind-mounted `modules/custom`
  tree.
- **Healthcheck independent of provisioning.** A simple HTTP probe on `/`, with a 40s start period,
  so the container is reported healthy as soon as Apache serves regardless of after-start progress.
- **CI on GitHub Actions.** `lint` (markdownlint + hadolint) gates `build-test` (docker build +
  smoke-test). The `push-images` job derives the tag from the GitHub Release (`github.event.release.tag_name`)
  and is currently commented out. Build context exclusions live in `.dockerignore`.
- **Versioning tracks Drupal core.** The image version (in `package.json` and the git tag) is the
  core version, with a `-vN` suffix only for a later wrapper iteration on the same core.
- **Temporary advisory ignores (BL-695).** Three guzzle/psr7 advisories are suppressed in
  `base-core` so the Critical Drupal 11.4.1 core fix can build before patched releases land in
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
- The `sites/` permission pass runs exactly once per image version per mounted volume (the marker
  is present on the volume after the first run; a later container on the same volume logs "already
  done on this volume" and skips it). Image-resident code hardening still runs on every container
  start.
- CI fails the build when a key module directory is missing or PHP/Drush are broken (smoke test
  catches it before any publish).
- 0 occurrences of the web user being able to write to `web/core`, `web/modules`, `vendor`, or the
  `.htaccess` files inside them, after hardening completes. (`sites/*/files` stays writable by the
  web user by design, for uploads; that includes its `.htaccess`.)
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

The central design choice is reproducibility under a runtime that bind-mounts part of the site. The
build pins core, contrib, and Drush; the deployed Swarm stack's mount contract enforces that pin by
only ever bind-mounting `custom.ini`, `modules/custom`, `sites`, `drush`, and `temp` for a site -
never the whole `modules` directory. That is a structural guarantee, not a convention teams have to
follow: `web/modules/contrib`, `web/core`, and `vendor` are never a bind-mount target, so they cannot
drift no matter what is on the EFS share behind `modules/custom`. This is why the after-start phase
no longer does any module reconciliation - there is nothing for it to reconcile.
