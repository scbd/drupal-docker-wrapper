---
status: accepted
date: 2026-08-24
deciders: [randy]
context: system-wide
code-path: scripts/after-start.sh
origin: standalone
supersedes: [0004, 0006]
---

# 0009. Confine after-start to image code, and drop the version marker with it

After-start no longer touches an EFS bind mount. Every pass that walked one is gone, and with them
the marker-and-gate mechanism that existed to make those passes affordable.

Removed from `after-start.sh`:

- `ensure_sites_files_permissions()` in full — the recursive pass over `web/sites`, the
  `settings*.php` / `services*.yml` `440` tightening, and the `sites/*/files` unlock.
- The `temp/` hardening block (`chown -R root:root`, `chmod -R 700`).
- `web/modules` as a hardened path, narrowed to `web/modules/contrib` so the bind-mounted
  `modules/custom` is skipped while contrib stays hardened.
- The version-marker machinery: `resolve_marker_dir()`, `MARKER_DIR`, `MARKER_FILE`, the
  stale-marker purge, and `skip_volume_work`.

`harden_mounted_volumes` is renamed `harden_image_code`, which is what it now does.

## Why

The deployed `dmsm` stack bind-mounts five paths per site: `php/custom.ini`, `web/modules/custom`,
`web/sites`, `drush`, `temp`. Their contents and permissions belong to the deploy that mounts them.
After-start was reaching into that storage on every start to fix permissions it does not own, over
the network, before the site was fully up.

The cost was real: a recursive `chown`/`chmod` over `web/sites` walks each site's entire EFS upload
tree, as does a `find` for `.htaccess` from the project root (ADR 0008). That is why ADR 0004
introduced a marker and ADR 0006 moved it onto the mounted volume - both mitigations for work that
should not have run in the container at all.

Deleting the work deletes the reason for the mitigation. What remains — hardening `web/core`,
`web/modules/contrib`, `web/themes`, `web/profiles`, `web/libraries`, `vendor`, and the root-level
web files — walks only paths that ship in the image: local disk, identical on every container from
a given image, cheap to repeat unconditionally. A marker guarding it would add a second source of
truth about whether the image's own code is hardened, and could only be wrong in the unsafe
direction.

## Consequences

- **`web/sites` permissions are entirely the deploy's responsibility now.** Nothing in the
  container tightens `settings*.php` or `services*.yml`. That hardening must happen where the mount
  is defined, or in the external per-site script that already owns `.htaccess` under `sites/*/files`
  (ADR 0008). Sharpest edge of this decision: a mount shipping `settings.php` world-readable stays
  world-readable.
- **Container start no longer does recursive I/O over network storage.** The remaining pass is
  bounded by the image's own tree.
- **There is no completion marker to inspect, stale-purge, or reason about**, and no
  `temp/` volume dependency for one. ADRs 0004 and 0006 are superseded.
- Hardening failures are counted and named rather than swallowed (`|| true`), so "code is still
  `www-data`-writable" no longer looks identical to a clean run.
- **The reversal condition is a mount-contract change.** If a future `dmsm` template bind-mounts
  the whole `web/modules` tree, or otherwise puts image code behind a mount, this decision and
  ADR 0005 both need reopening — the pins and the hardening would be silently defeated and there
  is no code left here to notice.
