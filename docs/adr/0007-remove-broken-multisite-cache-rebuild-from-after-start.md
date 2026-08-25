---
status: accepted
date: 2026-08-24
deciders: [randy]
context: system-wide
code-path: scripts/after-start.sh
origin: standalone
---

# 0007. Remove the broken multisite cache rebuild from after-start

The `rebuild_cache` function and its call site are deleted from `after-start.sh`. No Drupal cache
rebuild remains in the container's startup path, and nothing inside the container replaces it.

`rebuild_cache` ran `drush -r <project_root>/web cache:rebuild` with no `-l` / `--uri`. On a
multisite install, drush without a site URI bootstraps only the default site, so the rebuild covered
at most one site and silently skipped the rest. It was also gated on `web/sites/default/settings.php`
existing, which a multisite with per-site directories may not have - in that case it logged "No
Drupal settings.php found, skipping cache rebuild" and did nothing. Multisite is the only way this
image is deployed, so the step was either a no-op or it rebuilt one arbitrary site.
`ensure_sites_files_permissions` in the same file already globs `sites/*/files` and handles
multisite correctly, making the single-site rebuild inconsistent with the rest of the script.

A cache rebuild after an image change is still needed: new contrib versions or a new patch carry
code Drupal's cached service container and route table do not know about. That is now the deploy
process's job, run per site through the drush aliases the stack already bind-mounts at
`/var/www/html/drush` (`@lk`, `@be`, ...; see the mount table in `README.md`) - for example
`gosu www-data vendor/bin/drush @lk cache:rebuild`. `gosu` is kept in the image for exactly that. No
script in this image runs `gosu` or `drush`.

<details>
<summary>3 rejected alternatives</summary>

- **Iterate the drush aliases or `sites.php` in `after-start.sh` and rebuild every site
  automatically** - the container would guess the site list from whatever the `drush` mount happens
  to contain, which is deploy-process knowledge. Silently rebuilding every site on every start is a
  wide blast radius, and it puts slow per-site database work back on the healthcheck's critical
  path, which the two-phase split (ADR 0003) exists to avoid.
- **Pass a single `--uri` to `drush cache:rebuild`** - fixes the silent skip for one named site and
  stays wrong for every other site: one arbitrary-site bug traded for another.
- **Add `-l`/`--uri` per site inside the loop that already globs `sites/*/files`** - same problem as
  the first: deploy-time knowledge moved into the image, with slow per-site work on every start
  instead of once per deploy.

</details>

## Consequences

- A deployment that changes module versions or applies a patch and does **not** run a per-site
  cache rebuild can serve from a stale service container or route table. Nothing in this image
  catches that; the deploy process is solely responsible.
- `after-start.sh` no longer touches Drush or the database. Its remaining work
  (`cleanup_deprecated_paths`, `harden_mounted_volumes`, `ensure_sites_files_permissions`) is
  filesystem-only, so the two-phase deferral (ADR 0003) is now justified solely by the slow
  recursive permission pass over the EFS-backed `sites/` tree.
- `gosu` stays in the image though no script invokes it, so an operator can run drush as `www-data`
  by hand for tasks like this rebuild. See the `Dockerfile`'s `gosu` comment.
- ADR 0004 and ADR 0006, which described the gated "expensive work" as including a cache rebuild,
  are corrected to describe only the `sites/` permission pass - the only thing the marker gated.
