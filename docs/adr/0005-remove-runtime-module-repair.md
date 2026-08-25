---
status: accepted
date: 2026-08-24
deciders: [randy]
context: system-wide
code-path: scripts/after-start.sh
origin: standalone
---

# 0005. Remove runtime module repair and the integrity hashes it depended on

`after-start.sh` no longer repairs contrib modules against `composer.lock`. The deployed dmsm Swarm
stack bind-mounts exactly five paths per site:

```text
/home/ubuntu/dmsm/{env}/{env}/{multiSiteCode}/php/custom.ini -> /usr/local/etc/php/conf.d/custom.ini
/home/ubuntu/dmsm/{env}/{env}/{multiSiteCode}/modules/custom -> /var/www/html/modules/custom
/home/ubuntu/dmsm/{env}/{env}/{multiSiteCode}/sites          -> /var/www/html/sites
/home/ubuntu/dmsm/{env}/{env}/{multiSiteCode}/drush          -> /var/www/html/drush
/home/ubuntu/dmsm/{env}/{env}/{multiSiteCode}/temp           -> /opt/drupal/temp
```

Only `modules/custom` is mounted, never the whole `modules` tree. `web/modules/contrib`, `web/core`,
and `vendor` always come from the image and cannot drift from `composer.lock`. The runtime repair
step existed to re-sync a volume-masked module tree; that tree no longer exists in any deployed
stack, so the step had nothing left to repair.

Removing it also deleted the only runtime `composer install` and an `rm -rf` over contrib
directories - a data-destruction path that ran on every ordinary container restart, triggered
automatically rather than by a deliberate action. The per-module `.<module>.hash` files it read to
decide what to repair are deleted too: nothing ever read them, and the `find` expression that
generated them was mis-parenthesised, so they were unreliable even while they existed.

## Considered Options

- **Keep repair as a defensive no-op** - rejected: it is not a no-op. It still runs `composer
  install` and deletes directories on every restart past the per-version marker; keeping code with a
  real blast radius around a threat (a volume mask) that structurally cannot occur is not
  "defensive", it is a live footgun with no upside.
- **Keep repair but gate it behind an opt-in flag** - rejected: `DRUPAL_SKIP_MODULE_REPAIR` and
  `DRUPAL_AFTER_START_FORCE_MODULE_REPAIR` already existed and did not make the step safer, only
  optional to disable. A flag that must be remembered on every deployment is not a fix for a step
  that should not exist.
- **Fix the `.hash` file generation instead of deleting it** - rejected: nothing in the codebase
  ever read the hash files, so a correctly-parenthesised `find` would still produce files with no
  consumer. Fixing dead code is not a reason to keep it.

## Consequences

- Contrib can never drift at runtime under the current mount contract, and there is no runtime
  `composer install` or destructive `rm -rf` left in the image at all.
- `after-start.sh` is shorter and its remaining work - deprecated-path cleanup, permission
  hardening, and a Drush cache rebuild - touches no module code.
- This reverses the consequence recorded in
  [adr/0002](0002-pin-contrib-modules-in-a-dedicated-build-stage.md): the pin is no longer
  reinforced by a runtime repair step, only by the mount contract. If a future deployment ever
  reintroduces a whole-`modules` mount, the pin would be silently defeated with nothing left to
  correct it. The mount contract is now load-bearing on its own and must be enforced at the stack
  template level, not assumed.
- `modules-versions.txt`, produced by `composer show --direct` at build time, remains as the
  human-inspectable manifest of what is pinned. It was never the thing repair verified against;
  `composer.lock` was.
