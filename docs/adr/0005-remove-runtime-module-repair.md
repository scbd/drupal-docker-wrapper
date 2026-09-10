---
status: accepted
date: 2026-08-24
deciders: [randy]
context: system-wide
code-path: scripts/after-start.sh
origin: standalone
---

# 0005. Remove runtime module repair and the integrity hashes it depended on

> **Amended 2026-08-24.** The "Drush cache rebuild" named below as remaining work no longer exists;
> it was removed as broken on multisite. See
> [adr/0007](0007-remove-broken-multisite-cache-rebuild-from-after-start.md).

`after-start.sh` no longer repairs contrib modules against `composer.lock`. The deployed dmsm Swarm
stack bind-mounts exactly five paths per site:

```text
/home/ubuntu/dmsm/{env}/{env}/{multiSiteCode}/php/custom.ini -> /usr/local/etc/php/conf.d/custom.ini
/home/ubuntu/dmsm/{env}/{env}/{multiSiteCode}/modules/custom -> /var/www/html/modules/custom
/home/ubuntu/dmsm/{env}/{env}/{multiSiteCode}/sites          -> /var/www/html/sites
/home/ubuntu/dmsm/{env}/{env}/{multiSiteCode}/drush          -> /var/www/html/drush
/home/ubuntu/dmsm/{env}/{env}/{multiSiteCode}/temp           -> /opt/drupal/temp
```

Only `modules/custom` is mounted, never the whole `modules` tree, so `web/modules/contrib`,
`web/core`, and `vendor` always come from the image and cannot drift from `composer.lock`. Repair
existed to re-sync a volume-masked module tree; no deployed stack has one, so it had nothing to
repair.

Removing it deleted the only runtime `composer install` and an `rm -rf` over contrib directories - a
data-destruction path that ran automatically on every ordinary restart. The per-module
`.<module>.hash` files it read are gone too: nothing ever read them, and the `find` expression
generating them was mis-parenthesised, so they were unreliable even while they existed.

<details>
<summary>3 rejected alternatives</summary>

- **Keep repair as a defensive no-op** - it is not a no-op. It still runs `composer install` and
  deletes directories on every restart past the per-version marker. Keeping code with that blast
  radius around a threat that structurally cannot occur is a live footgun, not defence.
- **Gate repair behind an opt-in flag** - `DRUPAL_SKIP_MODULE_REPAIR` and
  `DRUPAL_AFTER_START_FORCE_MODULE_REPAIR` already existed and made it optional to disable, not
  safer. A flag you must remember on every deployment does not fix a step that should not exist.
- **Fix the `.hash` generation instead of deleting it** - nothing read the hash files, so a correct
  `find` would still produce files with no consumer.

</details>

## Consequences

- Contrib can never drift at runtime under the current mount contract, and there is no runtime
  `composer install` or destructive `rm -rf` left in the image at all.
- `after-start.sh` is shorter and its remaining work - deprecated-path cleanup, permission
  hardening, and a Drush cache rebuild - touches no module code.
- This reverses a consequence in
  [adr/0002](0002-pin-contrib-modules-in-a-dedicated-build-stage.md): the pin is reinforced only by
  the mount contract now, not by a runtime repair step. If a future deployment reintroduces a
  whole-`modules` mount, the pin is silently defeated with nothing left to correct it. The mount
  contract is load-bearing on its own and must be enforced at the stack template level.
- `modules-versions.txt` (from `composer show --direct` at build time) remains the human-inspectable
  manifest of what is pinned. Repair never verified against it; `composer.lock` was.
