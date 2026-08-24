---
status: accepted
date: 2026-06-24
deciders: [randy]
context: system-wide
code-path: Dockerfile
origin: standalone
---

# 0002. Pin contrib modules with exact versions in a dedicated build stage

The wrapper image installs every contrib module and Drush at an exact pinned version, declared
inline in a single `composer require` inside a dedicated `with-modules` build stage, and retains
`composer.lock` in the image. The stage also writes `modules-versions.txt`, a human-inspectable
manifest produced by `composer show --direct`.

We do this for reproducibility and auditability: the exact dependency surface is visible in the
`Dockerfile` without running the image, builds are deterministic across machines and time, and no
implicit upgrade can slip in between rebuilds. Keeping the installs in their own stage means a module
bump invalidates only that layer's cache, not core.

## Considered Options

- **Floating version constraints** (e.g. `^3.6`) - rejected: lets contrib drift between rebuilds,
  defeating reproducibility.
- **A separate modules manifest file required by composer** - rejected: hides the version surface
  from a reader of the `Dockerfile` and adds a file to keep in sync for no cache benefit.
- **Many separate `composer require` lines** - rejected: each line is its own layer and slows
  rebuilds; one consolidated require maximizes cache reuse.

## Consequences

- Upgrading a module is a deliberate edit to the `Dockerfile` plus a rebuild, not an automatic pull.
- The pin cannot be defeated at runtime: the deployed dmsm Swarm mount contract bind-mounts only
  `modules/custom`, never the whole `modules` directory, so `web/modules/contrib`, `web/core`, and
  `vendor` always come from the image. See [adr/0005](0005-remove-runtime-module-repair.md) for the
  runtime module-repair step this removed once the mount contract made it unnecessary.
