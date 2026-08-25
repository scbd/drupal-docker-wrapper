---
status: accepted
date: 2026-08-25
deciders: [randy]
context: system-wide
code-path: Dockerfile
origin: standalone
---

# 0010. Drop the multi-platform build claim and build amd64 only

The `TARGETARCH` scaffolding is removed: the `ARG TARGETARCH` declarations in each stage and the
per-architecture apt cache ids (`id=apt-cache-$TARGETARCH`, now a single `id=apt-cache`). The AWS
CLI archive stays pinned to `awscli-exe-linux-x86_64.zip`, and the Dockerfile now says so
deliberately rather than by omission.

## Why

The image never actually built for `arm64`. `aef57f0` added the `TARGETARCH` args and the per-arch
cache ids so that concurrent multi-platform builds would not race on the apt lock, but
`Dockerfile:26` still fetched the x86_64 AWS CLI archive unconditionally and `./aws/install` then
executed a bundled x86_64 binary. A `linux/arm64` build died with an exec-format error. So the
scaffolding advertised a capability that was never delivered.

Faced with that, there were two honest options: make the claim true, or withdraw it. Making it true
is not a one-line fix. It means parameterising the archive by `$TARGETARCH`, and — because the
current fetch is an unauthenticated `curl` piped into a root-privileged install in every image —
pinning an exact CLI version and binding a signature check to a known key fingerprint, since a bare
`gpg --verify` passes happily against a substituted key. Beyond the AWS CLI, nothing has ever
exercised an arm64 build of the GD/AVIF rebuild or the contrib set, so the real cost is unbounded.

Nothing consumes an arm64 image. No deployment target was named when the scaffolding was added, and
none exists now; the `dmsm` stack this image serves runs `linux/amd64`. Spending that effort on an
architecture nothing asks for, to fix a claim nobody relies on, is not a good trade — and a false
capability claim is worse than no claim.

## Consequences

- **The image is `linux/amd64` only, and now says so.** The AWS CLI stanza carries a comment
  stating the pin is deliberate and pointing here.
- **Blocker B3 is closed by withdrawal, not repair.** The multi-platform claim and the bug in it
  are gone together.
- **CI builds a single platform.** `docker buildx` is still used for build cache and
  reproducibility, but with an explicit amd64-only platform list rather than a matrix.
- **The apt cache is shared again** under one id. That was only ever split to keep concurrent
  per-arch builds off the same lock, which cannot happen with one platform.
- **Reinstating arm64 is a bounded change, and this record is the specification for it.** Restore
  `ARG TARGETARCH` in each stage, re-split the apt cache ids, map `$TARGETARCH` to the archive
  suffix (`amd64` to `x86_64`, `arm64` to `aarch64`), and — this part is not optional — pin the CLI
  version, fetch the matching `.sig`, import AWS's published key into a temporary keyring, assert
  its full fingerprint against a constant embedded in the Dockerfile, and verify. Then expect to
  debug the GD/AVIF rebuild, which has never been built for arm64.
