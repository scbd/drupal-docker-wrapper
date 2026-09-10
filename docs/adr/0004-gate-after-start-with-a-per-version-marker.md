---
status: superseded
superseded-by: 0009
date: 2026-06-24
deciders: [randy]
context: system-wide
code-path: scripts/after-start.sh
origin: standalone
---

# 0004. Gate after-start work with a per-version marker file

> **Superseded 2026-08-24 by [adr/0009](0009-confine-after-start-to-image-code.md).** The marker no
> longer exists. It gated the recursive `sites/` permission pass and the other EFS-walking work;
> that work left after-start entirely and the gate went with it. What remains walks only the image's
> own tree and is cheap to repeat unconditionally.

After-start guards its expensive, one-time work with a marker file `after-start-<version>.complete`,
the version read from the image's bundled `package.json`. If the marker exists, after-start skips
the guarded work. On a fresh run it deletes stale `after-start-*.complete` markers, does the work,
then touches the current marker.

Why version-stamped: the expensive permission work runs once per image version rather than every
restart. A plain restart skips it; an upgrade re-runs it, because the bundled `package.json` version
changes and the old marker no longer matches.

> **Amended 2026-08-24.** The marker's location and gate scope were revised - see
> [adr/0006](0006-move-after-start-marker-to-the-mounted-volume.md). The cache rebuild referenced
> below as gated work was later removed entirely, not re-scoped; see
> [adr/0007](0007-remove-broken-multisite-cache-rebuild-from-after-start.md).

<details>
<summary>3 rejected alternatives</summary>

- **No gate, run every start** - redoes permission hardening on every restart, slow and pointless
  when nothing changed.
- **A version-less marker** (`/tmp/after-start.complete`) - an upgraded image would see the old
  marker and skip work it needs, so the permission pass would not re-run for the new version.
- **A persistent on-disk marker** (in the project tree) - would survive into new containers that
  need the work.

</details>

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
