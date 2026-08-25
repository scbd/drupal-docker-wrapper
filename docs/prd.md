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

Each decision below is the requirement it satisfies, not the mechanism. `architecture.md` is the
as-built record; the ADRs carry the rationale.

- **Pin contrib at build time in a dedicated stage.** Reproducibility and cache isolation, over
  floating constraints. ADR 0002.
- **Two-phase startup, handed off on a readiness poll rather than a fixed delay.** Apache must serve
  before provisioning finishes. ADR 0003.
- **After-start touches no bind mount, and nothing is gated.** What remains is cheap local-disk work
  on image code, so a completion marker would only be a second source of truth. ADR 0009.
- **No cache rebuild and no composer invocation in the container.** The rebuild never covered more
  than one site on multisite; repair had nothing to repair once contrib stopped being mountable.
  A per-site rebuild after a code change is now a deploy responsibility. ADRs 0005, 0007.
- **Hardening is confined to image code.** The consequence is deliberate and sharp: **nothing in the
  container tightens `settings*.php` or `services*.yml` any more**, so a mount shipping
  `settings.php` world-readable stays world-readable. That belongs to the deploy defining the mount,
  or to the external per-site script that owns `.htaccess` under `sites/*/files`. `gosu` stays so an
  operator can run drush as `www-data` by hand; no script invokes it. ADRs 0008, 0009.
- **Startup patch application is active but never blocking.** A missing patch engine or a failing
  patch logs and continues rather than stopping Apache. Build-time composer patching remains the
  path for patches published against a contrib release.
- **Healthcheck independent of provisioning**, so orchestration sees the container up as soon as
  Apache serves.
- **CI lints before it builds, and publishing is off.** The `push-images` job is commented out;
  tagged releases build and test but do not push.
- **Versioning tracks Drupal core**, with a `-vN` suffix for a wrapper-only iteration.
- **Temporary advisory ignores (BL-695).** Three guzzle/psr7 advisories are suppressed so the
  Critical Drupal 11.3.12 core fix can build before patched releases land in core's ranges. To be
  removed per Drupal #3599842; left in, they hide real future advisories on those packages.

## Testing Decisions

- **Test the built image's external behaviour, not script internals.** `ci/smoke-test.sh` runs the
  real image and asserts observable facts - PHP runs, Drush reports a version, key contrib
  directories exist - because that is the artifact a consumer pulls.
- **Lint the build and the docs.** `ci/lint.sh`, with a hadolint fallback so it works in restricted
  CI containers.
- **Local pipeline parity**: the same lint -> build -> smoke-test sequence runs locally.
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
