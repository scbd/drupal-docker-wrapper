> Part of the Bioland architectural plan. The cross-project hub (System Overview,
> Actors, Workflow Statuses, End-to-End Flows, Verification, Deferred Items) is the
> hub; glossary: [CONTEXT.md](CONTEXT.md) (this repo's wrapper context) and the
> system [CONTEXT-MAP.md](CONTEXT-MAP.md). This doc owns the **Drupal Docker Wrapper** (Docker /
> Bash / Composer) work. Sibling spokes: Bioland Head, Drupal Module Bioland,
> Drupal Module SCBD Thesaurus Tags, and Drupal Module SCBD Field JS.
>
> This spoke's code lives in **this repo** (`scbd/drupal-docker-wrapper`), so its detail also has a
> single-context home in [architecture.md](architecture.md), [prd.md](prd.md), and
> [adr/](adr/). This spoke is the cross-project slice; it links to those rather than restating them.

# Bioland: Drupal Docker Wrapper plan

This project is the **CMS runtime** of Bioland: a reusable Drupal 11 base image
(`scbd/drupal-docker-wrapper`) that pins contrib at build time and keeps that pin intact through a
mount contract that never bind-mounts contrib at runtime. Every other Drupal-side project runs
inside it. The deep view is [architecture.md](architecture.md); below is only what the rest of the
system depends on.

## Owned interface (the seam)

The wrapper is a **deep module behind a runtime contract**: the multi-stage build, ~40 pinned
contrib modules, two-phase startup, and permission hardening are all hidden. What other projects
depend on is a small, stable surface:

- **The runtime port - a Drupal 11 site that boots itself.** Apache serves on `:80` immediately and
  passes its `HEALTHCHECK` independently of provisioning. The custom-module spokes (`bioland`,
  `scbd_field`) depend on getting a working, pinned Drupal core + Drush + CLI tooling, not on how it
  was built.
- **The mount contract (the load-bearing seam).** Exactly five paths are safe to bind-mount from EFS:
  `modules/custom`, `sites`, `drush`, `temp`, and the PHP `custom.ini`. **Never** mount `vendor/`,
  `web/core/`, or the whole `modules/` tree - that is a *volume mask* and it shadows the image's
  pinned contrib. This is the contract the dmsm Swarm deployment must honour for the pin to hold.
- **The custom-module overlay.** `drupal-module-bioland` and `scbd_field` are NOT baked into the
  image; they are overlaid at runtime under `modules/custom`. The wrapper guarantees they land in a
  Drupal that already has its contrib dependencies (`linkit`, `fontawesome`, `jsonapi_extras`, etc.)
  pinned and present.
- **The after-start guarantees.** On every start the wrapper cleans deprecated paths and hardens
  image-resident code permissions (read-only `root:www-data`, `.htaccess` files inside those trees
  included). It touches none of the five bind mounts, so `web/sites` permissions - `settings*.php`
  and `services*.yml` included - are the deploy's responsibility; see
  [adr/0009](adr/0009-confine-after-start-to-image-code.md). Custom modules assume that image-code
  baseline; they do not run it themselves. No cache rebuild is in this list, see
  [adr/0007](adr/0007-remove-broken-multisite-cache-rebuild-from-after-start.md); and no `.htaccess`
  hardening under `sites/*/files`, see
  [adr/0008](adr/0008-remove-htaccess-hardening-from-after-start.md).

Intentionally *not* in the interface: the build stages and the startup patch mechanism (active, but
implementation, not seam).

## Connectors / Rules

- **Upstream / supply chain.** Builds `FROM drupal:11.x-php8.4`; pins every contrib module and Drush
  to an exact version inline in the `Dockerfile`; keeps `composer.lock`. Build-time patching via
  `cweagans/composer-patches` is live; three guzzle / psr7 advisories are temporarily suppressed for
  BL-695 (remove per Drupal #3599842).
- **CI / release adapter.** GitHub Actions lints (markdownlint + hadolint), builds, and
  smoke-tests; the `push-images` job is commented out, so releases build and test but do not push
  to Docker Hub.

See this repo's [adr/0002](adr/0002-pin-contrib-modules-in-a-dedicated-build-stage.md),
[adr/0003](adr/0003-two-phase-startup-entrypoint-and-after-start.md),
[adr/0004](adr/0004-gate-after-start-with-a-per-version-marker.md),
[adr/0005](adr/0005-remove-runtime-module-repair.md),
[adr/0006](adr/0006-move-after-start-marker-to-the-mounted-volume.md),
[adr/0007](adr/0007-remove-broken-multisite-cache-rebuild-from-after-start.md),
[adr/0008](adr/0008-remove-htaccess-hardening-from-after-start.md), and
[adr/0009](adr/0009-confine-after-start-to-image-code.md) for the decisions behind
these.

## Workflow transitions

The wrapper owns no part of the content / comment / translation workflow, only one **operational**
state machine: the after-start provisioning run. It has no branch - cleanup and image-code hardening
both run every start, ungated, because neither touches a bind mount; see
[adr/0009](adr/0009-confine-after-start-to-image-code.md). There is no cache-rebuild state; see
[adr/0007](adr/0007-remove-broken-multisite-cache-rebuild-from-after-start.md).

```mermaid
stateDiagram-v2
  [*] --> Cleanup: container start (cleanup deprecated paths, every start)
  Cleanup --> Hardening: harden image-resident code (every start)
  Hardening --> Complete: image code hardened; failures counted, non-fatal
  Complete --> [*]
```

This machine is self-contained: no content state, invisible over JSON:API, so the hub's Workflow
Statuses exclude it. Cleanup and hardening run on every container; nothing carries across containers
or volumes.
