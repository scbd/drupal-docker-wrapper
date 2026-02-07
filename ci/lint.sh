#!/usr/bin/env bash
set -euo pipefail
echo "[lint] Unified lint start"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$PROJECT_ROOT"

if [ -f package.json ]; then
  echo "[lint] Installing node dev dependencies"
  if [ -f package-lock.json ]; then
    echo "[lint] Using npm ci (lockfile present)"
    npm ci --no-audit --no-fund
  else
    echo "[lint] No package-lock.json found; using npm install"
    npm install --no-audit --no-fund
  fi
fi

# hadolint function (local bin or docker fallback)
if command -v hadolint >/dev/null 2>&1; then
  run_hadolint() { hadolint "$@"; }
else
  # Prefer downloading binary if Docker socket unavailable (common in restricted CI lint containers)
  if [ ! -S /var/run/docker.sock ]; then
    echo "[lint] hadolint not found and docker socket missing; downloading binary"
    HD_VERSION="2.12.0"
    case "$(uname -s)-$(uname -m)" in
      Darwin-arm64) HD_PLATFORM="Darwin-x86_64" ;;  # Rosetta-compatible
      Darwin-*)     HD_PLATFORM="Darwin-x86_64" ;;
      Linux-aarch64) HD_PLATFORM="Linux-arm64" ;;
      *)            HD_PLATFORM="Linux-x86_64" ;;
    esac
    curl -sSL -o /tmp/hadolint "https://github.com/hadolint/hadolint/releases/download/v${HD_VERSION}/hadolint-${HD_PLATFORM}" && \
      chmod +x /tmp/hadolint || { echo "[lint] Failed to download hadolint" >&2; exit 1; }
    run_hadolint() { /tmp/hadolint "$@"; }
  else
    echo "[lint] hadolint not found locally; using docker image"
    docker pull hadolint/hadolint:latest >/dev/null || { echo "[lint] Failed to pull hadolint image" >&2; exit 1; }
    run_hadolint() { docker run --rm -v "$PWD":/workspace -w /workspace hadolint/hadolint hadolint "$@"; }
  fi
fi

MD_FAIL=0
HD_FAIL=0

echo "[lint] Markdown lint"
npm run --silent lint:md || MD_FAIL=1

echo "[lint] Dockerfile lint"

# Run hadolint on Drupal 11 Dockerfile; capture failure without aborting entire script prematurely
if [ -f Dockerfile ]; then
  if ! run_hadolint Dockerfile; then
    echo "[lint] hadolint failed for Dockerfile" >&2
    HD_FAIL=1
  fi
fi

if [ $MD_FAIL -ne 0 ] || [ $HD_FAIL -ne 0 ]; then
  echo "[lint] Failures (markdown=$MD_FAIL docker=$HD_FAIL)" >&2
  exit 2
fi
echo "[lint] All lint checks passed"
