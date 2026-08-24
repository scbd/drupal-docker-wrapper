---
status: accepted
date: 2026-06-24
deciders: [randy]
context: system-wide
code-path: scripts/
origin: standalone
---

# 0003. Two-phase startup: thin entrypoint, forked after-start

Container startup runs in two phases. `entrypoint.sh` runs as root, forks a background job that
polls the web server until it answers and then runs the after-start script, and exec-chains the
upstream Drupal entrypoint so Apache starts immediately. `after-start.sh` then does the
privilege-sensitive provisioning in the background: deprecated-path cleanup and permission
hardening.

We split startup so the healthcheck never waits on that provisioning. The recursive chown/chmod pass
over EFS-backed `sites/files` is slow; doing it inline in the entrypoint would block the port and the
healthcheck for as long as it takes. Apache is serving as soon as the web server answers,
orchestration sees the container healthy, and the expensive work happens once afterward. The handoff
between phases is a readiness poll against the web server (any HTTP response counts), not a fixed
sleep, so after-start starts as soon as Apache can actually answer instead of after a guessed delay.

> **Amended 2026-08-24.** After-start used to also run a Drush cache rebuild, which was part of the
> original rationale for deferring this work off the entrypoint. That step was removed because it
> never worked correctly on multisite; see
> [adr/0007](0007-remove-broken-multisite-cache-rebuild-from-after-start.md). The deferral rationale
> now rests solely on the recursive permission pass, which remains slow enough on its own to justify
> the split.

## Consequences

- There is a window after Apache is up but before after-start finishes where permissions have not yet
  been hardened. This is expected: the two-phase split exists to let Apache serve immediately while
  that work runs in the background, not to guarantee it has already happened by the time the
  healthcheck reports healthy.
- Provisioning failures do not stop the container; after-start logs and continues, so a healthy
  container is not a guarantee that after-start succeeded - logs must be checked for `[after-start]`
  messages.
- Privilege separation is part of the design: root is used only for permission fixes and binding
  port 80. No script runs drush; `gosu` is kept in the image so an operator can run drush as
  www-data by hand.
