---
status: accepted
date: 2026-08-24
deciders: [randy]
context: system-wide
code-path: scripts/after-start.sh
origin: standalone
---

# 0007. Remove the broken multisite cache rebuild from after-start

The `rebuild_cache` function and its call site are deleted from `after-start.sh`. There is no
longer any Drupal cache rebuild in the container's startup path. Nothing inside the container
replaces it.

`rebuild_cache` ran `drush -r <project_root>/web cache:rebuild` with no `-l` / `--uri` argument. On
a multisite install, drush with no site URI bootstraps only the default site, so the rebuild
covered at most one site and silently skipped every other one. The step was also gated on
`web/sites/default/settings.php` existing. A multisite whose sites live in per-site directories may
have no `default/settings.php` at all, in which case the function logged "No Drupal settings.php
found, skipping cache rebuild" and did nothing. Multisite is the only way this image is actually
deployed, so in practice the step was either a no-op or it rebuilt one arbitrary site, never every
site. `ensure_sites_files_permissions` in the same file already handles multisite correctly, by
globbing `sites/*/files`, which made the single-site cache rebuild inconsistent with the rest of
the script.

The need for a cache rebuild after an image change has not gone away. A new image with different
contrib module versions or a new patch carries code that Drupal's cached service container and
route table do not know about until the cache is rebuilt. That responsibility now belongs to the
deploy process, run per site through the drush site aliases the stack already bind-mounts at
`/var/www/html/drush` (aliases such as `@lk`, `@be`; see the mount table in `README.md`). The
correct operation is a per-alias rebuild run once per site, for example
`gosu www-data vendor/bin/drush @lk cache:rebuild`. `gosu` is kept in the image for exactly this: an
operator can run drush as `www-data` by hand. No script in this image runs `gosu` or `drush`.

## Considered Options

- **Iterate the drush aliases or `sites.php` inside `after-start.sh` and rebuild every site's cache
  automatically** - rejected. The container would be guessing at the site list from whatever the
  `drush` mount happens to contain at that moment, which is deploy-process knowledge, not
  image-build knowledge. A startup script that silently rebuilds every site's cache on every
  container start is a wide blast radius for something the deploy process already has the context
  to do correctly and deliberately. It would also put slow, per-site database work back in the
  startup path, which is exactly what the two-phase split (ADR 0003) exists to keep off the
  healthcheck's critical path.
- **Pass a single `--uri` to `drush cache:rebuild`** - rejected. This fixes the silent-skip case for
  one named site but is still wrong for every other site on the same multisite install. It trades
  one arbitrary-site bug for a different arbitrary-site bug.
- **Leave `rebuild_cache` in place and just add `-l`/`--uri` per site inside the loop that already
  globs `sites/*/files`** - rejected for the same reason as the first option: it moves deploy-time
  knowledge (which sites exist, when they should be rebuilt) into the image, and does slow per-site
  work on every container start instead of once per deploy.

## Consequences

- A deployment that changes module versions or applies a new patch and does **not** run a per-site
  cache rebuild afterward can serve from a stale service container or route table. Nothing in this
  image catches that; the deploy process is now solely responsible for running
  `drush cache:rebuild` per site after any change that ships new code.
- `after-start.sh` no longer touches Drush or the database at all. Its remaining work
  (`cleanup_deprecated_paths`, `harden_mounted_volumes`, `ensure_sites_files_permissions`) is
  filesystem-only, which also means the two-phase startup deferral (ADR 0003) is now justified
  solely by the slow recursive permission pass over the EFS-backed `sites/` tree, not by a slow
  Drush cache rebuild as well.
- The `gosu` package stays in the image even though no script invokes it any more, so an operator
  can still run drush as `www-data` by hand for tasks like this rebuild. See the `Dockerfile`'s
  `gosu` comment.
- ADR 0004 and ADR 0006, which described the gated "expensive work" as including a cache rebuild,
  are corrected to describe only the `sites/` permission pass, which is the only thing the marker
  ever gated.
