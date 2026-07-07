> Part of the [Bioland](#) architectural plan. The cross-project hub (System Overview,
> Actors, Workflow Statuses, End-to-End Flows, Verification, Deferred Items) is the
> [hub](#); glossary: [CONTEXT.md](CONTEXT.md) (this repo's wrapper context) and the
> system [CONTEXT-MAP.md](CONTEXT-MAP.md). This doc owns the **Drupal Docker Wrapper** (Docker /
> Bash / Composer) work. Sibling spokes: [Bioland Head](#),
> [Drupal Module Bioland](#),
> [Drupal Module SCBD Thesaurus Tags](#),
> [Drupal Module SCBD Field JS](#).
>
> This spoke's code lives in **this repo** (`scbd/drupal-docker-wrapper`), so its detail also has a
> single-context home in [architecture.md](../architecture.md), [prd.md](../prd.md), and
> [adr/](../adr/). This spoke is the cross-project slice; it links to those rather than restating them.

# Bioland: Drupal Docker Wrapper plan

This project is the **CMS runtime** of Bioland: a reusable Drupal 11 base Docker image
(`scbd/drupal-docker-wrapper`) that pins contrib at build time and re-asserts that pinning at startup.
It is the host every other Drupal-side project runs inside. The deep single-context view is this
repo's [architecture.md](../architecture.md); below is only what the rest of the system depends on.

## Owned interface (the seam)

The wrapper is a **deep module behind a runtime contract**. Almost all of its behaviour (multi-stage
build, ~40 pinned contrib modules, integrity hashing, two-phase startup, permission hardening) is
hidden; what other projects actually depend on is a small, stable surface:

- **The runtime port - a Drupal 11 site that boots itself.** The image serves Apache on `:80`
  immediately and passes its `HEALTHCHECK` independently of provisioning. The custom-module spokes
  (`bioland`, `scbd_field`) depend on getting a working, pinned Drupal core + Drush + CLI tooling to
  run inside, not on knowing how it was built.
- **The mount contract (the load-bearing seam).** Exactly five paths are safe to bind-mount from EFS:
  `modules/custom`, `sites`, `drush`, `temp`, and the PHP `custom.ini`. **Never** mount `vendor/`,
  `web/core/`, or the whole `modules/` tree - that is a *volume mask* and it shadows the image's
  pinned contrib. This is the contract the dmsm Swarm deployment must honour for the pin to hold.
- **The custom-module overlay.** `drupal-module-bioland` and `scbd_field` are NOT baked into the
  image; they are overlaid at runtime under `modules/custom`. The wrapper guarantees they land in a
  Drupal that already has its contrib dependencies (`linkit`, `fontawesome`, `jsonapi_extras`, etc.)
  pinned and present.
- **The after-start guarantees.** Once per container start per image version, the wrapper repairs
  contrib against `composer.lock`, hardens permissions (code read-only `root:www-data`; only
  `sites/*/files` writable), and rebuilds the Drupal cache. The custom modules can assume this
  baseline; they do not run it themselves.

What is intentionally *not* in the interface: the build stages, the integrity hashes (build artifacts,
not machine-verified at runtime), and the dormant startup patch mechanism. Those are implementation,
hidden behind the surface above.

## Connectors / Rules

- **Upstream / supply chain.** Builds `FROM drupal:11.x-php8.4`; pins every contrib module and Drush
  to an exact version inline in the `Dockerfile`; keeps `composer.lock`. Build-time patching via
  `cweagans/composer-patches` is live; three guzzle / psr7 advisories are temporarily suppressed for
  BL-695 (remove per Drupal #3599842).
- **Module repair adapter.** `after-start.sh` walks every contrib module, compares the installed
  version against `composer.lock`, removes stale or mis-owned directories, and runs `composer install`
  as `www-data` to restore the pins. With the recommended `modules/custom`-only mount this is a near
  no-op for contrib; with the current whole-`modules` mount it does real work each start.
- **CI / release adapter.** GitHub Actions lints (markdownlint + hadolint), builds, and smoke-tests; the
  `push-images` publish job is commented out, so releases build and test but do not push to Docker Hub.

See this repo's [adr/0002](../adr/0002-pin-contrib-modules-in-a-dedicated-build-stage.md),
[adr/0003](../adr/0003-two-phase-startup-entrypoint-and-after-start.md), and
[adr/0004](../adr/0004-gate-after-start-with-a-per-version-marker.md) for the decisions behind these.

## Workflow transitions

The wrapper owns no part of the content / comment / translation workflow. It owns one **operational**
state machine: the after-start provisioning run, gated by `/tmp/after-start-<version>.complete`.

```mermaid
stateDiagram-v2
  [*] --> Pending: container start
  Pending --> Skipped: marker for this version exists
  Pending --> Running: no marker (clear stale markers first)
  Running --> Repairing: module repair vs composer.lock
  Repairing --> Cleanup: cleanup deprecated paths
  Cleanup --> Rebuilding: drush cache:rebuild
  Rebuilding --> Complete: touch marker
  Skipped --> [*]
  Complete --> [*]
```

This machine is self-contained: it touches no content state and is invisible over JSON:API, so the
hub's Workflow Statuses do not include it. A container restart on the same image short-circuits to
`Skipped`; a new image version clears stale markers and re-runs.
