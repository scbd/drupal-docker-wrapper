---
status: accepted
date: 2026-06-24
deciders: [randy]
context: system-wide
code-path: scripts/after-start.sh
origin: standalone
---

# 0004. Gate after-start work with a per-version marker file

The after-start phase guards its one-time work with a marker file
`/tmp/after-start-<version>.complete`, where the version is read from the image's bundled
`package.json`. If the marker exists, after-start exits early. On a fresh run it first deletes any
stale `after-start-*.complete` markers, does its work, then touches the current marker.

We gate on a version-stamped marker so the expensive work (module repair, cache rebuild) runs once
per container per image version. A plain container restart on the same image skips the work; an
upgrade to a new image version re-runs it, because the bundled `package.json` version changes and
the old marker no longer matches.

## Considered Options

- **No gate, run every start** - rejected: redoes module repair and a cache rebuild on every
  restart, which is slow and pointless when nothing changed.
- **A version-less marker** (`/tmp/after-start.complete`) - rejected: an upgraded image would see the
  old marker and skip the work it needs to run, so upgraded modules and a fresh cache would not take
  effect.
- **A persistent on-disk marker** (in the project tree) - rejected: provisioning should re-run on a
  new container, and a persisted marker would survive into containers that need the work.

## Consequences

- The marker lives in `/tmp`, so it is per-container and naturally resets when a new container
  starts - which is the intended idempotency boundary (once per container per version).
- The version comes from `package.json`; that file must be bumped in lockstep with the image so the
  gate distinguishes versions correctly. The README's versioning section makes that a release rule.
