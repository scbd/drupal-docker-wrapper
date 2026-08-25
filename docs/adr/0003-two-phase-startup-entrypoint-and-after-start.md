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

We split startup so the healthcheck never waits on that provisioning. Apache is serving as soon as
the web server answers, orchestration sees the container healthy, and the hardening happens
afterward. The handoff between phases is a readiness poll against the web server (any HTTP response
counts), not a fixed sleep, so after-start starts as soon as Apache can actually answer instead of
after a guessed delay.

> **Amended 2026-08-24.** Two of the three costs that originally justified deferring this work are
> no longer in after-start: the Drush cache rebuild, which never worked correctly on multisite
> ([adr/0007](0007-remove-broken-multisite-cache-rebuild-from-after-start.md)), and every pass that
> walked an EFS bind mount — including the recursive `chown`/`chmod` over `sites/files` that the
> paragraph above originally cited as the expensive step
> ([adr/0009](0009-confine-after-start-to-image-code.md)).
>
> What remains is a bounded pass over the image's own tree, so the *performance* argument for two
> phases is weaker than when this was written. The split still stands, for a reason worth stating
> plainly rather than leaving a stale rationale in place: hardening still runs `chown -R` and
> `chmod` across `web/core`, `vendor`, and the contrib tree, and inlining that would hold the port
> closed for its duration on a cold container, making the healthcheck a function of disk speed.
> Backgrounding it also means a hardening failure degrades permissions instead of preventing the
> site from serving — the right trade for this workload. If the remaining pass ever becomes trivial
> enough to inline, revisit this decision rather than assuming it.

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
