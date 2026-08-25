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

The after-start completion marker moves off `/tmp` onto the bind-mounted `temp/` directory. A new
`resolve_marker_dir()` helper in `after-start.sh` picks `${project_root}/temp` when it exists and
falls back to `/tmp` otherwise. The image never creates `temp/`, so its presence reliably signals a
mounted volume. The marker's shape is unchanged:
`<marker-dir>/after-start-<version>.complete`, version read via `read_wrapper_version()` in
`lib/common.sh`.

Why: `/tmp` sits in the container's writable layer, so every redeploy and scale-out starts with an
empty `/tmp` and the ADR 0004 marker never survived the container that wrote it. The expensive
recursive permission pass over the EFS-backed `sites/` tree
(`ensure_sites_files_permissions`) therefore re-ran on every redeploy and every replica against the
same volume. `temp/` is one of the five paths the deployed `dmsm` Swarm stack bind-mounts per site
(see adr/0005), so a marker there survives every container mounting that volume - once per wrapper
version per volume, not per container.

The more important half is narrowing the gate: only `ensure_sites_files_permissions` is gated.
`harden_mounted_volumes` and `cleanup_deprecated_paths` still run unconditionally, because they act
on image-resident code (`web/core`, `web/themes`, `web/profiles`, `web/libraries`, `web/modules`,
`vendor`), not the volume. The `Dockerfile` ends with `chown -R www-data:www-data /opt/drupal`, so a
fresh container starts with its own code writable by the web server; a volume marker saying "done"
would leave every container after the first un-hardened - a security regression, not an
optimization. A third step, `rebuild_cache`, also ran ungated then, and has since been removed
entirely because it never rebuilt more than one site on multisite. See
[adr/0007](0007-remove-broken-multisite-cache-rebuild-from-after-start.md).

The marker is written from inside the background subshell after `ensure_sites_files_permissions`
returns, not from the foreground: writing it earlier recorded the work as finished mid-walk, so a
container killed in that window left a marker for work that never completed. A failed `touch` logs
a warning and the work re-runs next start. Stale-marker cleanup sweeps the resolved marker directory
and, when that is not `/tmp`, the legacy `/tmp` location too, so a pre-move marker is purged and the
work re-runs once on upgrade.

<details>
<summary>3 rejected alternatives</summary>

- **Gate everything behind the persisted marker, not just the `sites/` pass** -
  `harden_mounted_volumes` fixes ownership on image code, not the volume. A fresh container's image
  layer is un-hardened whatever the volume's marker says, so gating it would leave every container
  after the first writable by `www-data`.
- **Create `temp/` in the image so the `/tmp` fallback never triggers** - the fallback works
  precisely because the image does not create `temp/`; creating it removes that signal and persists
  a marker in the writable layer that vanishes with the container anyway.
- **Keep the marker in `/tmp`** - the status quo this decision fixes: a per-container gate, so the
  expensive `sites/` pass re-ran on every redeploy and replica against the same EFS volume.

</details>

## Consequences

- The marker now means "the volume-backed `sites/` permission work for this wrapper version has
  finished on this volume", not "after-start has finished on this container". It is written only
  after `ensure_sites_files_permissions` returns.
- Two containers on the same volume and wrapper version, started together, can both find no marker
  and both run the `sites/` pass. The pass is idempotent: wasted work, not a correctness problem.
- ~~`harden_mounted_volumes` still runs a `find` for every `.htaccess` file across the whole project
  root on every start, which walks the EFS-backed `sites/` tree regardless of the marker. Some
  per-start EFS cost remains after this decision; it is not addressed here.~~
  **Resolved by [adr/0008](0008-remove-htaccess-hardening-from-after-start.md).** That pass was
  removed. It was also measured to have no durable effect, because
  `ensure_sites_files_permissions` overwrote the only path it uniquely covered straight afterward.
- This reverses part of [adr/0004](0004-gate-after-start-with-a-per-version-marker.md): the marker
  is no longer per-container, and the gate covers only the `sites/` pass, not permission hardening
  as a whole. See that ADR's amended text.
