---
type: project
references: [docs/CONTEXT.md, docs/architecture.md, docs/adr/]
date: 2026-06-24
---

# Drupal Docker Wrapper - Product Requirements

## Problem Statement

Teams across bioland need a Drupal 11 environment that is identical on a laptop, in CI, and under
the production Swarm stacks: same core, same contrib versions, same CLI tooling. Building that from
`drupal:11.x-php8.4` by hand is slow and drifts - each person resolves contrib differently, and
advisories and patches land inconsistently. Nobody wants to wait on a long composer install before
the container is usable, or the web server able to overwrite its own code.

## Solution

A reusable Drupal 11 base image (`scbd/drupal-docker-wrapper`) that pins every contrib module and
Drush to an exact version at build time and ships a `modules-versions.txt` manifest. The deployed
Swarm stack bind-mounts only five paths per site - `custom.ini`, `modules/custom`, `sites`, `drush`,
`temp` - so core, contrib, and `vendor` always come from the image and cannot drift at runtime. The
image starts in two phases: Apache comes up immediately while a background after-start script cleans
deprecated paths and hardens the image's own code permissions on every start. Other bioland repos
build their sites on top of this image; the custom modules and the bioland-head Nuxt frontend layer
onto it without being part of it.

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
    while everything else stays read-only - delivered by the deploy that defines the `sites` mount,
    not by the container, which sets no permission under `web/sites` at all. See
    [adr/0009](adr/0009-confine-after-start-to-image-code.md).
11. As a platform engineer, I want an operator-invoked way to run composer and drush as www-data
    rather than root, so that manual provisioning follows least privilege - `gosu` is retained in
    the image for exactly that, and no script in the image runs either command itself.
12. As a platform engineer deploying under Swarm, I want the bind-mount contract documented exactly
    (only `custom.ini`, `modules/custom`, `sites`, `drush`, and `temp` are mounted per site), so
    that a stack definition never widens the mount to the whole `modules` tree and puts the mount
    in competition with the image's own pinned `web/core`, `web/modules/contrib`, and `vendor`.
13. As a platform engineer, I want after-start to touch no bind mount at all, so that container
    start does no recursive I/O over EFS - accepting that `web/sites` permissions become the
    responsibility of the deploy that defines the mount. See
    [adr/0009](adr/0009-confine-after-start-to-image-code.md).
14. As a CI maintainer, I want the image built and smoke-tested on every change, so that a broken
    build or a missing key module is caught before release.
15. As a CI maintainer, I want markdown and Dockerfile linting in the pipeline, so that the docs and
    the build file stay clean.
16. As a release manager, I want the published Docker tag derived from the git tag, so that the
    image version always matches the release.
17. As a release manager, I want a versioning scheme that ties the image to the Drupal core it
    ships, with a `-vN` suffix for wrapper-only iterations, so that consumers can tell a core bump
    from a module or script change.
18. As a security reviewer, I want `.env*` and archived patches excluded from the build context, so
    that secrets and dead patches never enter the image.
19. As a security reviewer, I want a healthcheck that reports container health independently of
    provisioning, so that orchestration sees the container as up as soon as Apache serves.
20. As a maintainer, I want a way to apply Drupal patches, so that I can carry fixes that are not yet
    in a contrib release: composer patching at build time for contrib, and an optional startup patch
    step for the bind-mounted `modules/custom` tree that never blocks Apache if it fails.
21. As a maintainer, I want to suppress specific security advisories temporarily with an explicit,
    documented reason, so that a Critical core fix can build before downstream packages ship their
    own patched releases.
22. As an operator, I want troubleshooting guidance for common failure modes (the readiness probe
    timing out before Apache answers, missing drush, after-start not running), so that I can
    diagnose without reading the scripts.
23. As a consumer building a derived image, I want documented composer cache ownership steps, so
    that composer works when I change the USER or run composer in my own layer.

## Implementation Decisions

- **Multi-stage build, module installs isolated.** `base-core` (core, system packages,
  GD-with-AVIF, composer config), `with-modules` (composer-patches plugin, then one consolidated
  `composer require` of all pinned modules plus Drush, then `modules-versions.txt` via
  `composer show --direct`), `final` (production php.ini, labels, docroot symlink, scripts,
  healthcheck). Isolating module installs keeps a module bump from invalidating the core layer's
  cache. See `docs/adr/0002-...`.
- **Exact pins inline in the Dockerfile.** Every contrib module and Drush carry an exact version in
  the single `composer require`. `composer.lock` is retained as the record of the build-time
  resolved graph; nothing reads it at runtime.
- **The composer-patches plugin is required before patched packages**, so patches can apply during
  the module install.
- **Two-phase startup, gated on readiness not a fixed delay.** `entrypoint.sh` runs as root, forks a
  job polling `http://127.0.0.1/` until the web server answers - any HTTP status counts, including
  301/403/500 - then runs `after-start.sh`, and exec-chains the upstream Drupal entrypoint so Apache
  starts immediately. Timeout, interval, and probe URL are overridable via
  `DRUPAL_AFTER_START_READY_TIMEOUT` (default 120s), `DRUPAL_AFTER_START_READY_INTERVAL` (default
  2s), and `DRUPAL_AFTER_START_READY_URL`, each validated with a logged fallback. See
  `docs/adr/0003-...`.
- **No gating, because nothing expensive is left.** After-start touches no bind mount:
  deprecated-path cleanup and `harden_image_code` act only on image-resident local-disk paths, so
  they are cheap to repeat and run unconditionally. No completion marker, marker directory, or
  stale-marker purge. See `docs/adr/0009-...`.
- **No cache rebuild in the container.** The old `drush cache:rebuild` ran with no site URI (so it
  bootstrapped only the default site) and was gated on `web/sites/default/settings.php`, which a
  multisite install may not have. Under multisite it was a no-op or rebuilt one arbitrary site, so
  it was removed. A per-site rebuild is still required after a module or patch change; it is now a
  deploy responsibility, run through the mounted drush aliases (`@lk`, `@be`, ...). See
  `docs/adr/0007-...`.
- **No runtime composer invocation.** The module-repair step comparing installed contrib against
  `composer.lock` was removed, with its `DRUPAL_SKIP_MODULE_REPAIR` and
  `DRUPAL_AFTER_START_FORCE_MODULE_REPAIR` variables. Only `modules/custom` is bind-mounted, so
  `web/modules/contrib`, `web/core`, and `vendor` cannot drift underneath it.
- **Permission hardening confined to image code.** `web/core`, `web/modules/contrib`, `web/themes`,
  `web/profiles`, `web/libraries`, `vendor`, and the root-level `web/*` files become `root:www-data`
  read-only (dirs 755, files 644, covering the `.htaccess` files inside them and `web/.htaccess`),
  with the execute bit restored on `vendor/bin` entries and their targets. Nothing under the five
  bind mounts is touched. In particular **nothing in the container tightens `settings*.php` or
  `services*.yml` any more** - a mount shipping `settings.php` world-readable stays world-readable,
  and that hardening must happen where the mount is defined, or in the external per-site script that
  already owns `.htaccess` under `sites/*/files`. `gosu` is preserved so an operator can run drush as
  www-data by hand (e.g. `gosu www-data vendor/bin/drush @lk cache:rebuild`); no script invokes it.
  The previous `ensure_runtime_ownership` (which made code www-data-writable) was removed for
  security, and the blanket `.htaccess` pass across the project root is gone - it walked the
  EFS-backed `sites/*/files` trees every start and changed no durable permission. See
  `docs/adr/0008-...` and `docs/adr/0009-...`.
- **Startup patch application is active, and optional.** `lib/patches.sh` (`git apply -p1` only, no
  marker files - an already-applied patch is detected with a `git apply --reverse --check` dry run;
  ignores `patches/old/`) ships in the image and runs from `entrypoint.sh` before Apache starts. It
  degrades safely both ways: a missing `lib/patches.sh` is logged and skipped rather than killing
  PID 1, and a failing patch step does not stop Apache serving. Build-time composer patching (via
  `cweagans/composer-patches`) stays the path for patches published against a contrib release; this
  one exists for patches applying against the bind-mounted `modules/custom` tree.
- **Healthcheck independent of provisioning.** An HTTP probe on `/` with a 40s start period, so the
  container reports healthy as soon as Apache serves, regardless of after-start progress.
- **CI on GitHub Actions.** `lint` (markdownlint + hadolint) gates `build-test` (docker build +
  smoke-test). `push-images` derives the tag from `github.event.release.tag_name` and is currently
  commented out. Build context exclusions live in `.dockerignore`.
- **Versioning tracks Drupal core.** The image version (in `package.json` and the git tag) is the
  core version, with a `-vN` suffix only for a later wrapper iteration on the same core.
- **Temporary advisory ignores (BL-695).** Three guzzle/psr7 advisories are suppressed in
  `base-core` so the Critical Drupal 11.3.12 core fix can build before patched releases land in
  core's ranges; documented inline to be removed (Drupal #3599842).

## Testing Decisions

- **Test the built image's external behaviour, not script internals.** `ci/smoke-test.sh` runs the
  real image and asserts observable facts: PHP runs, Drush reports a version, and key contrib
  directories (`jsonapi_extras`, `search_api`) exist. That is the artifact a consumer pulls.
- **Lint the build and docs.** `ci/lint.sh` runs markdownlint and hadolint, with a hadolint fallback
  (local binary or docker image) so it works in restricted CI containers.
- **Local pipeline parity.** `ci/test-ci-locally.sh` runs the same lint -> build -> smoke-test
  sequence locally.
- **Prior art.** Copy the smoke test for any new image-level assertion: start a container, exec a
  check, assert on its output or filesystem. Keep checks observable and version agnostic.

## Success Metrics

- Apache passes its healthcheck within the 40s start period on a cold `docker run` (baseline: a
  blocking install could take minutes).
- A fresh `docker run` of a published tag yields an installed contrib tree whose versions match
  `modules-versions.txt` and the inline `Dockerfile` pins (0 drift).
- After-start performs 0 filesystem operations under any of the five bind mounts
  (`php/custom.ini`, `web/modules/custom`, `web/sites`, `drush`, `temp`), so container start does no
  recursive I/O over EFS. Image-resident code hardening runs on every container start.
- CI fails the build when a key module directory is missing or PHP/Drush are broken.
- 0 occurrences of the web user being able to write to `web/core`, `web/modules/contrib`, `vendor`,
  or the `.htaccess` files inside them, after hardening completes. `web/modules/custom` is
  deliberately excluded - it is a bind mount, so it is deploy-owned. Keeping `sites/*/files`
  writable for uploads is likewise the deploy's guarantee, not the image's.
- Build context contains no `.env*` or archived patch files (verified by `.dockerignore`).

## Out of Scope

- The custom modules themselves (`bioland`, `scbd_*`) - own repos, overlaid at runtime.
- The bioland-head Nuxt frontend - consumes the Drupal JSON:API, separate product.
- The dmsm Swarm stack definitions and EFS provisioning - the deployment substrate lives outside
  this repo; this repo only documents the mount contract it expects.
- Site installation and content - the image provides Drush and an example; installing and seeding a
  site is the consumer's job.
- The MySQL database - external, provided by the runtime.
- Automated weekly base-image rebuilds and re-enabling the publish job - desired (noted in the
  README) but not yet implemented.

## Further Notes

The central design choice is reproducibility under a runtime that bind-mounts part of the site. The
build pins core, contrib, and Drush; the mount contract enforces that pin by only ever bind-mounting
`custom.ini`, `modules/custom`, `sites`, `drush`, and `temp` - never the whole `modules` directory.
That is a structural guarantee, not a convention teams must follow: `web/modules/contrib`,
`web/core`, and `vendor` are never a bind-mount target, so they cannot drift no matter what sits on
the EFS share behind `modules/custom`. This is why after-start no longer does any module
reconciliation - there is nothing to reconcile.
