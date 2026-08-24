---
status: accepted
date: 2026-06-24
deciders: [randy]
context: system-wide
code-path: scripts/after-start.sh
origin: standalone
---

# 0004. Gate after-start work with a per-version marker file

The after-start phase guards its expensive, one-time work with a marker file named
`after-start-<version>.complete`, where the version is read from the image's bundled
`package.json`. If the marker exists, after-start skips the work it guards. On a fresh run it first
deletes any stale `after-start-*.complete` markers, does its work, then touches the current marker.

We gate on a version-stamped marker so the expensive permission work runs once per image version
rather than on every restart. A plain container restart skips the gated work when the marker is
already there; an upgrade to a new image version re-runs it, because the bundled `package.json`
version changes and the old marker no longer matches.

> **Amended 2026-08-24.** The marker's location and the scope of what it gates were revised. See
> [adr/0006](0006-move-after-start-marker-to-the-mounted-volume.md) for where the marker lives now,
> why, and why the gate covers only the `sites/` permission pass rather than all of after-start's
> work. The cache rebuild referenced below as part of the gated work was later removed entirely,
> not just re-scoped; see [adr/0007](0007-remove-broken-multisite-cache-rebuild-from-after-start.md).

## Considered Options

- **No gate, run every start** - rejected: redoes permission hardening on every restart, which is
  slow and pointless when nothing changed.
- **A version-less marker** (`/tmp/after-start.complete`) - rejected: an upgraded image would see the
  old marker and skip the work it needs to run, so the permission pass would not re-run for the new
  version.
- **A persistent on-disk marker** (in the project tree) - rejected: provisioning should re-run on a
  new container, and a persisted marker would survive into containers that need the work.

## Consequences

- ~~The marker lives in `/tmp`, so it is per-container and naturally resets when a new container
  starts - which is the intended idempotency boundary (once per container per version).~~
  **Superseded by [adr/0006](0006-move-after-start-marker-to-the-mounted-volume.md).** `/tmp` sits
  in the container's writable layer, so this was never the useful boundary it looked like: it meant
  the expensive `sites/` permission pass re-ran on every redeploy and every scaled-out replica
  against the same EFS volume. The marker now lives on the mounted `temp/` volume, falling back to
  `/tmp` only when no volume is mounted, so it is per-volume and per-version. The gate now also
  covers only the `sites/` permission pass, not all of after-start's work.
- The version comes from `package.json`, read through the shared `read_wrapper_version` helper in
  `lib/common.sh` so the entrypoint and after-start derive the gate from one implementation. That
  file must be bumped in lockstep with the image so the gate distinguishes versions correctly. The
  README's versioning section makes that a release rule.
