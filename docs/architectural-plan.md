> **Plan vs. as-built.** This is the design-of-record for the **Drupal Docker Wrapper** project.
> [architecture.md](architecture.md) is the as-built snapshot; when they conflict, `architecture.md`
> is the truth about the code and this plan is the truth about intent. The overlap between the two is
> deliberate provenance, not duplication.
>
> Part of the Bioland architectural plan. The cross-project hub (System Overview,
> Actors, Workflow Statuses, End-to-End Flows, Verification, Deferred Items) is the
> hub, not yet linkable from this repo; glossary: [CONTEXT.md](CONTEXT.md); context map:
> [CONTEXT-MAP.md](CONTEXT-MAP.md). This doc owns the **Drupal Docker Wrapper** (Docker / Bash /
> Composer) work. Sibling spokes (separate repos, no cross-repo link yet): Bioland Head,
> Drupal Module Bioland, Drupal Module SCBD Thesaurus Tags, Drupal Module SCBD Field JS.

# Bioland: Drupal Docker Wrapper — Architectural Plan

## Context

The Drupal Docker Wrapper is the CMS runtime of the Bioland system. It is a single, reusable Docker
image (`scbd/drupal-docker-wrapper`) built on the official `drupal:11.x-php8.4` upstream image,
layering every required contrib module and Drush at pinned exact versions, along with CLI tooling
and a two-phase startup script. Every other Drupal-side Bioland project — `drupal-module-bioland`,
`scbd_field`, and the module dependencies they require — runs inside a container started from this
image.

This project is the hub repo for the Bioland architectural plan. Its design documents (this file,
[architecture.md](architecture.md), [prd.md](prd.md), [CONTEXT.md](CONTEXT.md)) are the
system-of-record for the CMS Runtime bounded context. The cross-project material lives in the
Bioland hub (a separate repo; no cross-repo link yet).

> Cross-project decisions: [docs/adr/](adr/).

---

## Owned Interface (the seam)

The wrapper is a deep module. Almost all of its implementation — the multi-stage build, the ~40
pinned contrib modules, the two-phase startup, the permission hardening — is hidden from
consumers. What other projects actually depend on is a small, stable contract:

**1. The runtime port — a Drupal 11 site that boots immediately.**
The image starts Apache on `:80` in seconds and passes its `HEALTHCHECK` before the background
provisioning finishes. The custom-module spokes (`bioland`, `scbd_field`) depend on a live,
pinned Drupal core + Drush environment to run inside, not on knowing how it was assembled.

**2. The mount contract — the load-bearing seam.**
Exactly five paths are safe to bind-mount from EFS:

| Mount path | Purpose |
| --- | --- |
| `modules/custom` | Custom module overlays (`bioland`, `scbd_*`) |
| `sites` | Multi-site config and per-site `files/` |
| `drush` | Site aliases |
| `temp` | Checkpoints, backups, scratch |
| `php/custom.ini` | PHP runtime overrides |

Mounting `vendor/`, `web/core/`, or the whole `modules/` directory is a volume mask — it hides the
image's pinned contrib tree and defeats the reproducibility guarantee. This is the contract the dmsm
Swarm deployment must honour for the pin to hold.

**3. The custom-module overlay contract.**
`drupal-module-bioland` and `scbd_field` are not baked into the image. They are overlaid under
`modules/custom` at runtime. The wrapper guarantees they land in a Drupal that already has their
contrib dependencies (`linkit`, `fontawesome`, `jsonapi_extras`, `auto_node_translate`, etc.)
pinned and present.

**4. The after-start guarantees.**
Once per container start per image version, the wrapper: (a) cleans deprecated paths, (b) hardens
permissions (code read-only `root:www-data`; only `sites/*/files` writable), and (c) rebuilds the
Drupal cache. Custom modules can assume this baseline; they do not run it themselves.

What is **not** in the interface: the build stages and the startup patch-application internals.
Those are implementation, hidden behind the surface above.

---

## Architecture Views

*Deep view: [architecture.md](architecture.md) — the as-built snapshot.
Sections are linked per-item below.*

### System Context (C4 L1)

```mermaid
flowchart TB
  subgraph actors [Actors]
    dev[Developer<br/>Builds and runs locally]
    ci[CI / Release<br/>GitHub Actions]
  end
  subgraph external [External systems]
    upstream[[drupal:11.x-php8.4<br/>upstream image]]
    packagist[[Packagist / drupal.org<br/>Composer sources]]
    registry[(Docker Hub<br/>published tags)]
    efs[(EFS runtime<br/>dmsm Swarm bind mounts)]
    custom[(bioland & scbd_ modules<br/>overlaid at runtime)]
    head[bioland-head Nuxt<br/>decoupled frontend]
  end

  wrapper([Drupal Docker Wrapper<br/>scbd/drupal-docker-wrapper])

  dev -->|builds, runs, inspects| wrapper
  ci -->|builds, lints, smoke-tests, publishes| wrapper
  wrapper -->|builds FROM| upstream
  wrapper -->|pins contrib via Composer| packagist
  wrapper -->|published to| registry
  efs -->|overlays modules/custom, sites, drush| wrapper
  custom -->|deployed onto| efs
  head -->|reads JSON:API| wrapper
```

The wrapper sits between the upstream `drupal:11.x-php8.4` image and the Packagist/drupal.org
sources it builds FROM, and the consumers that depend on it at runtime: the dmsm Swarm stacks, the
custom module overlays (from EFS), and the bioland-head Nuxt frontend that reads the Drupal
JSON:API. Developers and GitHub Actions build and test the image; Docker Hub holds published tags.

### Containers (C4 L2) — what is built in vs. overlaid at runtime

```mermaid
flowchart TB
  subgraph image [Wrapper image: scbd/drupal-docker-wrapper]
    core[Drupal 11 core + PHP 8.4<br/>from upstream]
    contrib[Pinned contrib modules<br/>web/modules/contrib]
    drush[Drush 13 + CLI tools<br/>curl, gosu, jq, patch, git, mysql client, aws cli]
    manifest[modules-versions.txt<br/>direct-dependency manifest]
    startup[Two-phase startup<br/>entrypoint.sh + after-start.sh + lib/]
    pkg[package.json<br/>wrapper version]
  end

  subgraph runtime [Overlaid at runtime via bind mounts]
    custom[(modules/custom<br/>bioland, scbd_*)]
    sites[(sites<br/>multisite config + files)]
    drushcfg[(drush<br/>site aliases)]
    temp[(temp<br/>checkpoints, backups)]
    phpini[(custom.ini<br/>PHP overrides)]
  end

  upstream[[drupal:11.x-php8.4]] --> core
  composer[[Composer / Packagist]] --> contrib
  composer --> drush
  contrib --> manifest
  custom -. overlays .-> contrib
  sites -. mounts .-> image
  drushcfg -. mounts .-> image
  temp -. mounts .-> image
  phpini -. mounts .-> image
```

The image contains four kinds of content:

| Content | Where | Notes |
| --- | --- | --- |
| Drupal 11 core + PHP 8.4 | `web/core/`, `vendor/` | From the upstream image |
| Pinned contrib modules (~40) | `web/modules/contrib/` | Built in the `with-modules` stage |
| Drush 13 + CLI tooling | system path / composer global | curl, gosu, jq, patch, git, mysql client, aws cli |
| Startup scripts + manifest | `scripts/`, `/opt/drupal/modules-versions.txt` | `entrypoint.sh`, `after-start.sh` |

Five paths are **overlaid at runtime** via bind mounts from EFS (see Owned Interface §2 above). The
hard rule: never mount over `vendor/`, `web/core/`, or `web/modules/contrib/`.

### Key Components (C4 L3)

#### Build stages

The `Dockerfile` is three named stages, each adding one concern:

| Stage | Adds | Cache strategy |
| --- | --- | --- |
| `base-core` | Upstream Drupal core, system packages (curl, gosu, jq, nano, mysql-client, unzip, AWS CLI v2, GD/AVIF rebuild), composer config | Cache invalidates only on system-package or base-image changes |
| `with-modules` | One consolidated `composer require` of all ~40 pinned modules + Drush; `modules-versions.txt` | Cache invalidates on any module version bump; isolated from core |
| `final` | Production PHP ini (`zz-production.ini`), OCI labels, docroot symlink, startup scripts, composer-home writable for www-data, `HEALTHCHECK`, `ENTRYPOINT` | Small, invalidates rarely |

```mermaid
flowchart LR
  subgraph base [base-core]
    b1[FROM drupal:11.4.5-php8.4]
    b2[System packages:<br/>curl, gosu, jq, nano,<br/>mysql client, unzip]
    b3[AWS CLI v2]
    b4[Rebuild GD with AVIF]
    b5[COPY patches/ into image]
    b6[Composer config:<br/>prefer dist, enable patching,<br/>exclude robots.txt from scaffold,<br/>ignore 3 guzzle advisories]
  end
  subgraph mods [with-modules]
    m1[Install build tools:<br/>git, patch, unzip]
    m2[Require composer-patches plugin FIRST]
    m3[Single composer require:<br/>~40 pinned modules + Drush]
    m4[Write modules-versions.txt]
    m5[Delete web/robots.txt<br/>so drupal/robotstxt owns the route]
    m6[Purge unzip]
  end
  subgraph fin [final]
    f1[zz-production.ini:<br/>disable assertions]
    f2[OCI image labels]
    f3[Symlink /var/www/html to web]
    f4[COPY package.json + scripts]
    f5[Composer home writable<br/>for www-data]
    f6[HEALTHCHECK + ENTRYPOINT]
  end
  base --> mods --> fin
```

Two deliberate ordering constraints:

- The `cweagans/composer-patches` plugin must be required **before** any patched package, so it is
  a separate `composer require` step at the top of `with-modules`.
- Three guzzle/psr7 security advisories (`PKSA-93qv-9n9h-6k6p`, `PKSA-k22t-f949-t9g6`,
  `PKSA-7qs6-zvnz-h66r`) are temporarily suppressed in `base-core` for BL-695 so the Critical
  SA-CORE-2026-005..009 Drupal core fix (shipped in 11.3.12) can build before patched guzzle/psr7
  releases land in core's dependency ranges. Remove when Drupal issue #3599842 is resolved.

#### Startup scripts

```mermaid
flowchart TB
  ep[entrypoint.sh\nroot, thin]
  asf[after-start.sh\nbackground, once the readiness poll succeeds]
  common[lib/common.sh\nlog, find_project_root, read_wrapper_version]
  patches[lib/patches.sh\napply_patches_if_present\noptional: missing file logged, skipped]

  ep -->|sources if present| patches
  ep -->|calls, best-effort| patches
  ep -->|sources| common
  ep -->|forks, polls http://127.0.0.1/| asf
  ep -->|exec| upstream[upstream docker-entrypoint → apache2-foreground]
  asf -->|sources| common
  asf --> cleanup[cleanup_deprecated_paths]
  asf --> harden[harden_mounted_volumes +\nensure_sites_files_permissions]
  asf --> cache[rebuild_cache via drush]
```

`lib/patches.sh` is fully implemented (multi-strategy `patch`, applied markers) and its entry point
`apply_patches_if_present` runs at startup, before Apache starts. It is optional and best-effort: a
missing `lib/patches.sh` is logged and skipped rather than killing the container, and a failing
patch step does not stop Apache from serving. Build-time composer patching via
`cweagans/composer-patches` runs independently at image build.

---

## Data Model

There is no application database in this repo. The "data" is the dependency manifest fixed at
build time:

```mermaid
erDiagram
  COMPOSER_LOCK ||--o{ CONTRIB_MODULE : pins
  CONTRIB_MODULE ||--o| MODULES_VERSIONS_TXT : listed_in
  PACKAGE_JSON ||--|| VERSION_MARKER : names
  COMPOSER_LOCK {
    string package "drupal/<name>"
    string version "exact pinned"
  }
  CONTRIB_MODULE {
    string name
    string installed_version
    string path "web/modules/contrib/<name>"
  }
  VERSION_MARKER {
    string file "/tmp/after-start-<version>.complete"
  }
```

`composer.lock` is the authoritative pin: every contrib module's exact version is fixed at build
time and never rewritten afterward, because `web/modules/contrib` is never bind-mounted (see the
mount contract in Owned Interface §2 above) — there is nothing at runtime that could drift it.
`modules-versions.txt` is the human-readable manifest of direct dependency versions, produced by
`composer show --direct` at build time.

---

## Key Flows

### Container startup — two-phase

```mermaid
sequenceDiagram
  participant Docker
  participant Entry as entrypoint.sh (root)
  participant Apache as Apache / upstream entrypoint
  participant After as after-start.sh (background)
  participant Drush

  Docker->>Entry: ENTRYPOINT [apache2-foreground]
  Note over Entry: apply_patches_if_present runs, best-effort (missing engine or a failed patch does not block Apache)
  Entry->>After: fork (poll http://127.0.0.1/ until ready, then run after-start) &
  Entry->>Apache: exec docker-entrypoint apache2-foreground
  Apache-->>Docker: serving on :80 — HEALTHCHECK passes

  Note over After: once the readiness poll succeeds (or times out), in background
  After->>After: marker /tmp/after-start-<version>.complete present?
  alt marker exists
    After-->>After: exit 0 (already done this version)
  else first run for this version
    After->>After: clear stale version markers
    After->>After: cleanup_deprecated_paths (robots.txt; defence-in-depth backstop)
    par background hardening
      After->>After: harden_mounted_volumes + sites/*/files perms
    end
    After->>Drush: cache:rebuild (as www-data via gosu)
    After->>After: touch marker
  end
```

The fork design means the healthcheck never waits on after-start. Apache is exec'd immediately and
serving independently of it; the forked task polls for that readiness and then runs the
privilege-sensitive work once, gated by the version marker so a container restart on the same
image skips it.

### CI build and release

```mermaid
sequenceDiagram
  actor Dev
  participant GHA as GitHub Actions
  participant Build as build-test
  participant Smoke as smoke-test.sh
  participant Hub as Docker Hub

  Dev->>GHA: push / release
  GHA->>GHA: lint (markdownlint + hadolint)
  GHA->>Build: docker build .
  Build->>Smoke: run container, check PHP, Drush, key modules
  Smoke-->>Build: pass
  Note over Hub: push-images job is commented out
  GHA-->>Dev: green (no publish until push job re-enabled)
```

---

## Deployment / Infrastructure

```mermaid
flowchart LR
  subgraph ci [CI / Release]
    cc[GitHub Actions]
    hub[(Docker Hub<br/>scbd/drupal-docker-wrapper)]
  end
  subgraph swarm [dmsm Docker Swarm]
    svc[drupal service<br/>per multi-site]
  end
  subgraph efs [EFS per env/site]
    mcustom[(modules/custom)]
    msites[(sites)]
    mdrush[(drush)]
    mtemp[(temp)]
    mphp[(php/custom.ini)]
  end
  db[(MySQL)]
  nuxt[bioland-head Nuxt]

  cc -->|tag build, push job currently off| hub
  hub --> svc
  mcustom -. bind mount .-> svc
  msites -. bind mount .-> svc
  mdrush -. bind mount .-> svc
  mtemp -. bind mount .-> svc
  mphp -. bind mount .-> svc
  svc --> db
  nuxt -->|JSON:API| svc
```

The deployed `drupal` service runs under the dmsm Swarm multi-site stacks (defined outside this
repo). It bind-mounts exactly the five paths above; `modules/custom` is the only part of
`modules/` ever mounted, so `web/modules/contrib`, `web/core`, and `vendor` always come from the
image and cannot drift.

---

## Connectors / Rules

**Upstream / supply chain.**
Builds `FROM drupal:11.x-php8.4`. Every contrib module and Drush is pinned to an exact version
declared inline in the `with-modules` `composer require`. `composer.lock` is retained in the image.
Build-time patching via `cweagans/composer-patches` is live; three guzzle/psr7 advisories are
temporarily suppressed for BL-695 (remove per Drupal #3599842).

**Permission hardening adapter.**
`after-start.sh` → `harden_mounted_volumes` + `ensure_sites_files_permissions`: makes the code
tree read-only (`root:www-data`, dirs 755 / files 644), locks `temp/` to `root:root` 700, forces
every `.htaccess` to 644, tightens `settings*.php`/`services*.yml` under `web/sites` to `440`
`root:www-data`, and leaves only `sites/*/files` writable (`www-data:www-data` 775). Root is used
only for this hardening step and for binding port 80; all Drush work runs as `www-data` via
`gosu`.

**CI / release adapter.**
GitHub Actions: `lint` (markdownlint + hadolint) gates `build-test` (docker build + smoke-test). The
`push-images` job reads the GitHub Release tag (`github.event.release.tag_name`) for the image tag and is
currently commented out — releases build and test but do not push to Docker Hub until it is re-enabled.

**Healthcheck.**
`HEALTHCHECK` makes an HTTP probe on `/` with a 40-second start period. The container reports
healthy as soon as Apache serves, independently of after-start progress. A healthy container does
not guarantee that after-start succeeded; check `[after-start]` log lines.

---

## Quality Attributes (NFRs)

| Attribute | Target | Design mechanism |
| --- | --- | --- |
| **Reproducibility** | Same digest from same source | Every contrib module and Drush pinned inline in the `Dockerfile`; `composer.lock` retained |
| **Determinism** | No implicit upgrades | Single consolidated `composer require` with exact versions; lockfile kept; `composer outdated --direct` used for visibility |
| **Startup latency** | Apache serving in seconds | Thin entrypoint forks after-start and exec-chains the upstream entrypoint immediately |
| **Idempotent provisioning** | One-time work per container per version | After-start gated by `/tmp/after-start-<version>.complete`; stale markers cleared on new version |
| **Health observability** | Container healthy independently of provisioning | HTTP `HEALTHCHECK` on `/` with 40 s start period; never blocked by after-start's cleanup, hardening, or Drush cache rebuild |
| **Security / least privilege** | Web user cannot write code | root only for permission fixes and port bind; then `www-data` via gosu; code `root:www-data` read-only; only `sites/*/files` writable |
| **Supply-chain control** | Auditable, explicit deps | Versions visible in `Dockerfile`; `modules-versions.txt` manifest; `.dockerignore` excludes `.env*` and archived patches |
| **Build efficiency** | Fast incremental rebuilds | Multi-stage build; module installs isolated; apt and Composer caches mounted; build-only tools purged |

---

## Decisions

Recorded in [docs/adr/](adr/). Rationale lives there; not restated here.

| ADR | Decision |
| --- | --- |
| [0001](adr/0001-record-architecture-decisions.md) | Adopt Architecture Decision Records |
| [0002](adr/0002-pin-contrib-modules-in-a-dedicated-build-stage.md) | Pin contrib modules at exact versions in a dedicated build stage rather than floating constraints or a separate manifest |
| [0003](adr/0003-two-phase-startup-entrypoint-and-after-start.md) | Two-phase startup: thin entrypoint chains Apache immediately; after-start does heavy provisioning in the background |
| [0004](adr/0004-gate-after-start-with-a-per-version-marker.md) | Gate after-start one-time work with a version-stamped marker in `/tmp` so restarts skip it and upgrades re-run it |
| [0005](adr/0005-remove-runtime-module-repair.md) | Remove runtime module repair and the per-module integrity hashes, since the mount contract never bind-mounts contrib and it cannot drift |

---

## Workflow Transitions

The wrapper owns no part of the content, comment, or translation workflow — those are the
`drupal-module-bioland` spoke's domain. It owns one operational state machine: the after-start
provisioning run, gated by the version marker.

```mermaid
stateDiagram-v2
  [*] --> Pending: container start
  Pending --> Skipped: marker for this version exists
  Pending --> Running: no marker (clear stale markers first)
  Running --> Cleanup: cleanup_deprecated_paths
  Cleanup --> Hardening: forked, backgrounded (no wait)
  Cleanup --> Rebuilding: drush cache:rebuild
  Rebuilding --> Complete: touch marker
  Hardening --> [*]
  Skipped --> [*]
  Complete --> [*]
```

| State | Transition trigger | Notes |
| --- | --- | --- |
| `Pending` | Container start | Always enters here |
| `Skipped` | Marker for this version already exists | Container restart on the same image; work skipped |
| `Running` | No marker found | Clears any stale `after-start-*.complete` markers first |
| `Cleanup` | Entered from `Running` | `cleanup_deprecated_paths` (e.g. `robots.txt`); defence-in-depth backstop, not the primary mechanism |
| `Hardening` | Forked at `Cleanup` exit, runs in background | Permission hardening; cache rebuild does not wait on it |
| `Rebuilding` | Forked at `Cleanup` exit, runs in foreground | `drush cache:rebuild` as `www-data` via `gosu` |
| `Complete` | Rebuild done | Marker file touched; subsequent restarts on the same version → `Skipped` |

This machine is self-contained: it touches no content state and is invisible over JSON:API. A
container restart on the same image short-circuits to `Skipped`; a new image version clears stale
markers and re-runs the full sequence.

---

## Deferred / Open Items

| Item | Owner | Notes |
| --- | --- | --- |
| **Temporary advisory ignores (BL-695)** | this repo | Three guzzle/psr7 advisories suppressed to allow the Critical Drupal 11.4.1 build. Must be removed once Drupal issue #3599842 is resolved. Left in place, they will hide real future advisories on those packages. |
| **Release publishing is off** | CI / ops | The GitHub Actions `push-images` job is commented out. Tagged releases build and test but do not push to Docker Hub. Re-enable with Docker Hub credentials when ready to publish. |
| **No scheduled weekly rebuild** | CI | README calls for a weekly rebuild to pick up upstream base-image security patches; the automation is not yet in place. |
| **No end-to-end test crossing the mount seam** | cross | No automated test verifies that the custom-module overlay + contrib pin produce a working Drupal site end-to-end. The smoke test checks PHP, Drush, and key module directories but not a live page render. |

---

## Verification Checklist

Checks scoped to this project. Items marked `[cross]` also appear in the Bioland hub's verification
checklist.

- [ ] Apache passes its `HEALTHCHECK` within the 40-second start period on a cold `docker run`.
- [ ] A fresh `docker run` of a published tag yields a contrib tree whose versions match
      `modules-versions.txt` and the inline `Dockerfile` pins — 0 drift.
- [ ] After-start runs its one-time work exactly once per container per image version: the marker is
      present after the first run; a restart logs "already complete" and exits early.
- [ ] A new image version causes after-start to re-run (old marker no longer matches).
- [ ] The web user (`www-data`) cannot write to `web/core/`, `web/modules/`, `vendor/`, or any
      `.htaccess` file after hardening completes.
- [ ] Only `sites/*/files` is writable by `www-data` after hardening.
- [ ] Build context contains no `.env*` or archived patch files (`.dockerignore` enforcement).
- [ ] CI fails the build when a key module directory (`jsonapi_extras`, `search_api`) is missing or
      PHP / Drush are broken (smoke test).
- [ ] `[cross]` The dmsm Swarm mount contract binds only `modules/custom` (never the whole
      `modules/` tree), so `web/modules/contrib` always comes from the image with no
      volume-masked drift — a standing regression check, not a one-time migration.
- [ ] `[cross]` Custom modules (`bioland`, `scbd_field`) overlaid at runtime find their contrib
      dependencies (`linkit`, `fontawesome`, `jsonapi_extras`, etc.) pinned and present.
