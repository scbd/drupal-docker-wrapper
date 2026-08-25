---
status: accepted
date: 2026-06-24
deciders: [randy]
context: system-wide
code-path: scripts/
origin: standalone
---

# 0003. Two-phase startup: thin entrypoint, forked after-start

Startup runs in two phases. `entrypoint.sh` runs as root, forks a job that polls the web server
until it answers then runs after-start, and exec-chains the upstream Drupal entrypoint so Apache
starts immediately. `after-start.sh` does the privilege-sensitive provisioning in the background:
deprecated-path cleanup and permission hardening.

Why: the healthcheck never waits on provisioning. The handoff is a readiness poll against the web
server (any HTTP response counts), not a fixed sleep, so after-start begins as soon as Apache can
answer rather than after a guessed delay.

> **Amended 2026-08-24.** Two of the three costs that justified deferring this work are gone from
> after-start: the Drush cache rebuild, broken on multisite
> ([adr/0007](0007-remove-broken-multisite-cache-rebuild-from-after-start.md)), and every EFS
> bind-mount walk, including the recursive `chown`/`chmod` over `sites/files` originally cited as
> the expensive step ([adr/0009](0009-confine-after-start-to-image-code.md)).
>
> What remains is a bounded pass over the image's own tree, so the *performance* argument is weaker
> than when this was written. The split still stands: hardening still runs `chown -R` and `chmod`
> across `web/core`, `vendor`, and contrib, and inlining it would hold the port closed for its
> duration on a cold container, making the healthcheck a function of disk speed. Backgrounding also
> means a hardening failure degrades permissions instead of preventing the site from serving. If the
> remaining pass ever becomes trivial enough to inline, revisit this rather than assuming it.

## Consequences

- There is a window after Apache is up but before after-start finishes where permissions are not
  yet hardened. That is expected: the split lets Apache serve immediately, not guarantee the work
  is already done when the healthcheck passes.
- Provisioning failures do not stop the container; after-start logs and continues, so a healthy
  container is no guarantee after-start succeeded - check the `[after-start]` log lines.
- Privilege separation is part of the design: root is used only for permission fixes and binding
  port 80. No script runs drush; `gosu` is kept in the image so an operator can run drush as
  www-data by hand.
