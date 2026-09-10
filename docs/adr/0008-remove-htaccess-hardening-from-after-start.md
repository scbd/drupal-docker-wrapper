---
status: accepted
date: 2026-08-24
deciders: [randy]
context: system-wide
code-path: scripts/after-start.sh
origin: standalone
---

# 0008. Remove the blanket .htaccess hardening pass from after-start

> **Amended 2026-08-24.** The `ensure_sites_files_permissions` behaviour described below in the
> present tense has since been removed entirely, along with every other after-start pass over a bind
> mount. See [adr/0009](0009-confine-after-start-to-image-code.md).

`harden_mounted_volumes` no longer runs `find "${project_root}" -name ".htaccess" -exec chown
root:www-data {} +`, its matching `chmod 644` pass, or the log line above them. A comment points
here in their place.

That `find` opened every directory under `/opt/drupal` to locate files named `.htaccess`. Most of
that tree is local to the image, but `web/sites` is bind-mounted from EFS and `web/sites/*/files`
holds each site's uploads, so the walk crossed the network over the entire upload tree on every
container start to find a handful of files. It ran inside `harden_mounted_volumes`, which stays
ungated by design (see [adr/0006](0006-move-after-start-marker-to-the-mounted-volume.md)) because
that function also fixes ownership on image-resident code that resets to `www-data`-writable with
every fresh container. The per-version marker never suppressed the walk either, for the same reason.

The walk achieved nothing durable. Measured in a running container:

- The only `.htaccess` file in the image outside the code paths is `web/.htaccess`. It stays
  hardened by the existing root-level pass (`find "${project_root}/web" -maxdepth 1 -type f`),
  which already sets `644 root:www-data`. Measured after a full run:
  `644 root:www-data /opt/drupal/web/.htaccess`.
- The `.htaccess` files inside `web/core`, `web/modules`, `web/themes`, `web/profiles`,
  `web/libraries`, and `vendor` never depended on the removed pass either. The code-path loop
  already runs `find "${code_path}" -type f -exec chmod 644` over each of them, and `-type f`
  matches dotfiles.
- The one location the pass uniquely covered was `web/sites/*/files/.htaccess`, and its effect
  there was destroyed immediately. In the backgrounded subshell `harden_mounted_volumes` runs
  first, then `ensure_sites_files_permissions` does `chown -R www-data:www-data` and
  `chmod -R 775` over each `files/` directory, dotfiles included. Measured in that order: the
  removed pass set `/opt/drupal/web/sites/default/files/.htaccess` to `644 root:www-data`, then
  `ensure_sites_files_permissions` reset it to `775 www-data:www-data`. The final state is identical
  with the pass and without it.

Removing the pass changes no resulting permission anywhere. For a site that wants its `.htaccess`
files hardened, an external per-site script the operator runs replaces it - the same kind of
responsibility [adr/0007](0007-remove-broken-multisite-cache-rebuild-from-after-start.md) assigns to
the cache rebuild. That script is not part of this repo.

<details>
<summary>3 rejected alternatives</summary>

- **Scope the `find` with `-maxdepth` or prune the upload directories** - cheap, still pointless.
  `ensure_sites_files_permissions` overwrites the one target it uniquely covered right afterward.
- **Reorder so the `.htaccess` chmod runs after `ensure_sites_files_permissions`** - this would
  genuinely change permissions, making each upload directory's `.htaccess` root-owned and 644 while
  the rest stays 775 `www-data`-owned. That behaviour change belongs in the external per-site
  script, where the site list is known, not in a startup walk that runs before any site-specific
  knowledge exists.
- **Gate the pass behind the version marker instead of removing it** - it lives inside
  `harden_mounted_volumes`, which must stay ungated because it also hardens image code that resets
  to `www-data`-writable with every fresh container (see
  [adr/0006](0006-move-after-start-marker-to-the-mounted-volume.md)). Gating the whole function
  would leave every container after the first with un-hardened code.

</details>

## Consequences

- Nothing in the container resets ownership or permissions on `.htaccess` files under
  `web/sites/**` now. `ensure_sites_files_permissions` sets everything under each `files/`
  directory, `.htaccess` included, to `775 www-data:www-data`. Drupal ships that file to stop PHP
  execution in the upload directory; its content is untouched, so it still functions. What is gone
  is any in-container guarantee about its mode and owner - only the external per-site script can
  provide one.
- That guarantee was already illusory for this path: the measurement above shows the removed pass's
  effect on `sites/*/files/.htaccess` was overwritten by `ensure_sites_files_permissions` in the
  same startup run, every time.
- `after-start.sh`'s remaining permission work is bounded to the code paths under
  `harden_mounted_volumes`, the root-level `web/` files, `temp/`, and the marker-gated `sites/` pass
  in `ensure_sites_files_permissions`. None of it walks the EFS-backed upload directories for a
  filename any more.
- This resolves the leftover cost noted in
  [adr/0006](0006-move-after-start-marker-to-the-mounted-volume.md)'s consequences: "some per-start
  EFS cost remains after this decision; it is not addressed here."
