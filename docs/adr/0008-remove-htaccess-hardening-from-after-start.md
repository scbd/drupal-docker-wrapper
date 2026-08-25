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
root:www-data {} +` and its matching `chmod 644` pass, or the log line above them. A comment stands
in their place pointing here.

That `find` had to open every directory under `/opt/drupal` to locate files named `.htaccess`. Most
of that tree is local to the image, but `web/sites` is bind-mounted from EFS, and
`web/sites/*/files` holds each site's uploads. The walk therefore crossed the network over the
entire EFS-backed upload tree on every single container start, to find a handful of files. It ran
inside `harden_mounted_volumes`, which stays ungated by design (see
[adr/0006](0006-move-after-start-marker-to-the-mounted-volume.md)) because that function also fixes
ownership on image-resident code that resets to `www-data`-writable with every fresh container. The
per-version marker never suppressed this walk either, for the same reason.

The walk was also not achieving anything durable. Measured in a running container:

- The only `.htaccess` file in the image outside the code paths is `web/.htaccess`. It stays
  hardened by the existing root-level pass (`find "${project_root}/web" -maxdepth 1 -type f`),
  which already sets `644 root:www-data`. Measured after a full run:
  `644 root:www-data /opt/drupal/web/.htaccess`.
- The `.htaccess` files inside `web/core`, `web/modules`, `web/themes`, `web/profiles`,
  `web/libraries`, and `vendor` never depended on the removed pass either. The code-path loop
  already runs `find "${code_path}" -type f -exec chmod 644` over each of them, and `-type f`
  matches dotfiles.
- The one location the removed pass uniquely covered was `web/sites/*/files/.htaccess`. Its effect
  there was destroyed immediately. In the backgrounded subshell, `harden_mounted_volumes` runs
  first and `ensure_sites_files_permissions` runs second, and the latter does
  `chown -R www-data:www-data` and `chmod -R 775` over each `files/` directory, which applies to
  dotfiles too. Measured, in this exact order: the removed pass set
  `/opt/drupal/web/sites/default/files/.htaccess` to `644 root:www-data`, then
  `ensure_sites_files_permissions` reset it to `775 www-data:www-data`. The final state is
  identical with the pass and without it.

Removing the pass changes no resulting permission anywhere. What replaces it, for a site that wants
its `.htaccess` files hardened, is an external script the operator runs against that site, the same
kind of per-site responsibility
[adr/0007](0007-remove-broken-multisite-cache-rebuild-from-after-start.md) assigns to the cache
rebuild. That script is not part of this repo.

## Considered Options

- **Scope the `find` with `-maxdepth` or by pruning the upload directories** - rejected: this would
  make the walk cheap, but it would still be pointless. `ensure_sites_files_permissions` overwrites
  the one target the pass uniquely covered immediately afterward, regardless of how cheaply the walk
  found it.
- **Reorder the passes so the `.htaccess` chmod runs after `ensure_sites_files_permissions`** -
  rejected: this would genuinely change permissions, by making each upload directory's `.htaccess`
  root-owned and 644 while everything else in that directory stays 775 and `www-data`-owned. That is
  a real behaviour change, and it belongs in the external per-site script, where the site list is
  actually known, not as a side effect of a startup walk that runs before any site-specific
  knowledge exists.
- **Gate the pass behind the version marker instead of removing it** - rejected: it lives inside
  `harden_mounted_volumes`, which must stay ungated. That function also hardens image-resident code
  that resets to `www-data`-writable with every fresh container (see
  [adr/0006](0006-move-after-start-marker-to-the-mounted-volume.md)); gating the whole function
  behind a persisted marker would leave every container after the first on a volume with
  un-hardened code.

## Consequences

- Nothing in the container now resets ownership or permissions on `.htaccess` files under
  `web/sites/**`. `ensure_sites_files_permissions` actively sets everything under each `files/`
  directory, `.htaccess` included, to `775 www-data:www-data`. Drupal ships that file to stop PHP
  execution in the upload directory; its content is untouched, so it still functions. What is gone
  is any in-container guarantee about its mode and owner, and the external per-site script is now
  the only thing that can provide one.
- That guarantee was already illusory for this exact path before this change: the measurement above
  shows the removed pass's effect on `sites/*/files/.htaccess` was overwritten by
  `ensure_sites_files_permissions` in the same startup run, every time. Removing the pass changes no
  resulting permission anywhere, which is why it is safe to remove.
- `after-start.sh`'s remaining permission work is bounded to the code paths under
  `harden_mounted_volumes`, the root-level `web/` files, `temp/`, and the marker-gated `sites/` pass
  in `ensure_sites_files_permissions`. None of it walks the EFS-backed upload directories looking
  for a specific filename any more.
- This resolves the leftover cost noted in
  [adr/0006](0006-move-after-start-marker-to-the-mounted-volume.md)'s consequences: "some per-start
  EFS cost remains after this decision; it is not addressed here." That cost is what this decision
  removes.
