---
status: accepted
date: 2026-06-24
deciders: [randy]
context: system-wide
code-path: Dockerfile
origin: standalone
---

# 0002. Pin contrib modules with exact versions in a dedicated build stage

The wrapper installs every contrib module and Drush at an exact pinned version, declared inline in
one `composer require` inside a dedicated `with-modules` stage, and retains `composer.lock`. The
stage also writes `modules-versions.txt` via `composer show --direct`.

Why: the exact dependency surface is readable in the `Dockerfile` without running the image, builds
are deterministic, and no implicit upgrade slips in between rebuilds. Isolating the installs means a
module bump invalidates only that layer's cache, not core.

<details>
<summary>3 rejected alternatives</summary>

- **Floating constraints** (e.g. `^3.6`) - lets contrib drift between rebuilds.
- **A separate composer-required manifest file** - hides the version surface from a `Dockerfile`
  reader and adds a file to keep in sync, for no cache benefit.
- **Many separate `composer require` lines** - each is its own layer and slows rebuilds; one
  consolidated require maximizes cache reuse.

</details>

## Consequences

- Upgrading a module is a deliberate edit to the `Dockerfile` plus a rebuild, not an automatic pull.
- The pin cannot be defeated at runtime: the deployed dmsm Swarm mount contract bind-mounts only
  `modules/custom`, never the whole `modules` directory, so `web/modules/contrib`, `web/core`, and
  `vendor` always come from the image. See [adr/0005](0005-remove-runtime-module-repair.md) for the
  runtime module-repair step this removed once the mount contract made it unnecessary.
