---
status: superseded
superseded-by: 0009
date: 2026-08-24
deciders: [randy]
context: system-wide
code-path: scripts/after-start.sh
origin: standalone
---

# 0006. Move the after-start marker onto the mounted volume, and narrow the gate

> **Superseded 2026-08-24 by [adr/0009](0009-confine-after-start-to-image-code.md).** This ADR moved a
> marker that no longer exists onto a volume after-start no longer touches. `resolve_marker_dir()`,
> `MARKER_DIR`, `MARKER_FILE`, the stale-marker purge and `skip_volume_work` are all deleted.

The after-start completion marker moves off `/tmp` and onto the bind-mounted `temp/` directory. A
new `resolve_marker_dir()` helper in `after-start.sh` picks `${project_root}/temp` when that
directory exists, and falls back to `/tmp` otherwise. The image never creates `temp/`, so its
presence is a reliable signal that a volume is actually mounted there. The marker file itself is
unchanged in shape: `<marker-dir>/after-start-<version>.complete`, with the version read through
`read_wrapper_version()` in `lib/common.sh`.

`/tmp` sits in the container's writable layer. Every redeploy and every scale-out event starts a
fresh container with a fresh, empty `/tmp`, so the marker written by ADR 0004 never survived past
the container that wrote it. That defeated the point of the gate: the expensive recursive
permission pass over the EFS-backed `sites/` tree (`ensure_sites_files_permissions`) re-ran on
every redeploy and every scaled-out replica of the same wrapper version, against the same EFS
volume, doing the same work over and over. `temp/` is one of the five paths the deployed `dmsm`
Swarm stack bind-mounts from EFS per site (see adr/0005), so a marker written there survives every
container that mounts that volume. The gate becomes what it was always meant to be: once per
wrapper version, per volume, not once per container.

This decision also narrows the gate itself, and that narrowing is the more important half of it.
Only `ensure_sites_files_permissions` is gated by the marker. `harden_mounted_volumes` and
`cleanup_deprecated_paths` still run on every container start, unconditionally.
`harden_mounted_volumes` fixes ownership on `web/core`, `web/themes`, `web/profiles`,
`web/libraries`, `web/modules`, and `vendor` - paths that live in the image, not on a mounted
volume. The `Dockerfile` ends with `chown -R www-data:www-data /opt/drupal`, so a fresh container
starts with its own code owned by, and writable by, the web server. Gating that hardening pass
behind a persisted marker would leave every container after the first one on a given volume
un-hardened: the marker would say "done" for a volume, while a brand-new container's own image
layer had never been touched. That is a security regression, not an optimization, so
`harden_mounted_volumes` stays ungated. `cleanup_deprecated_paths` acts on the image's own web root
for the same reason. A third step, `rebuild_cache`, also ran ungated at the time of this decision.
It has since been removed from `after-start.sh` entirely, because it never rebuilt more than one
site on the multisite installs this image actually runs as. See
[adr/0007](0007-remove-broken-multisite-cache-rebuild-from-after-start.md).

The marker is now written from inside the background subshell, after
`ensure_sites_files_permissions` returns, not from the foreground. Writing it earlier recorded the
volume-backed work as finished while the recursive walk was still running; a container killed in
that window left a marker for work that never completed. A failed `touch` logs a warning and the
work re-runs on the next start. Stale-marker cleanup now sweeps both the resolved marker directory
and, when that directory is not `/tmp`, the legacy `/tmp` location too, so a volume carrying a
marker from a pre-move wrapper version has it purged and the work re-runs once on upgrade.

## Considered Options

- **Gate everything (cleanup, image hardening, and the cache rebuild) behind the persisted marker,
  not just the `sites/` pass** - rejected: `harden_mounted_volumes` fixes ownership on code that
  lives in the image, not on the volume. A fresh container's image layer is un-hardened regardless
  of what any volume's marker says, so gating it behind that marker would leave every container
  after the first on a volume writable by `www-data`.
- **Create `temp/` in the image so the `/tmp` fallback never triggers** - rejected: the fallback
  exists precisely because the image does not create `temp/`, which is what makes its presence a
  reliable signal that a volume is mounted there. Creating it in the image would remove that signal
  and would persist a marker inside the container's writable layer for no benefit, since that
  marker would vanish with the container regardless.
- **Keep the marker in `/tmp`** - rejected: that is the status quo this decision fixes. It made the
  gate per-container instead of per-volume, so the expensive `sites/` pass re-ran on every redeploy
  and every scaled-out replica against the same EFS volume.

## Consequences

- The marker now means "the volume-backed `sites/` permission work for this wrapper version has
  finished on this volume", not "after-start has finished on this container". It is written only
  after `ensure_sites_files_permissions` returns.
- Two containers on the same volume and the same wrapper version, started at the same time, can
  both find no marker and both run the `sites/` permission pass. The pass is idempotent, so this is
  safe. It is wasted work, not a correctness problem.
- ~~`harden_mounted_volumes` still runs a `find` for every `.htaccess` file across the whole project
  root on every start, which walks the EFS-backed `sites/` tree regardless of the marker. Some
  per-start EFS cost remains after this decision; it is not addressed here.~~
  **Resolved by [adr/0008](0008-remove-htaccess-hardening-from-after-start.md).** That pass was
  removed. It was also measured to have no durable effect, because
  `ensure_sites_files_permissions` overwrote the only path it uniquely covered straight afterward.
- This reverses part of the consequence recorded in
  [adr/0004](0004-gate-after-start-with-a-per-version-marker.md): the marker is no longer
  per-container, and the gate no longer covers permission hardening as a whole, only the `sites/`
  pass. See that ADR's amended text.
