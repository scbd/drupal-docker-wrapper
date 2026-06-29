---
status: accepted
date: 2026-06-24
deciders: [randy]
context: system-wide
code-path: scripts/
origin: standalone
---

# 0003. Two-phase startup: thin entrypoint, forked after-start

Container startup runs in two phases. `entrypoint.sh` runs as root, forks the after-start script to
run ~60 seconds later, and exec-chains the upstream Drupal entrypoint so Apache starts immediately.
`after-start.sh` then does the heavy, privilege-sensitive provisioning in the background: module
repair against `composer.lock`, deprecated-path cleanup, permission hardening, and a Drush cache
rebuild.

We split startup so the healthcheck never waits on Composer or Drush. Apache is serving in seconds,
orchestration sees the container healthy, and the expensive work happens once afterward. Doing the
provisioning inline in the entrypoint would block the port and the healthcheck for as long as a
composer install takes.

## Consequences

- There is a window after Apache is up but before after-start finishes where the site runs against
  the as-mounted module tree (pre-repair). For the recommended `modules/custom` mount this is a
  non-issue; for a full `modules` mount the site briefly runs on the stale tree until repair and
  cache rebuild complete.
- Provisioning failures do not stop the container; after-start logs and continues, so a healthy
  container is not a guarantee that repair succeeded - logs must be checked for `[after-start]`
  messages.
- Privilege separation is part of the design: root is used only for permission fixes and binding
  port 80, after which composer and drush run as www-data via gosu.
