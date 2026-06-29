#!/usr/bin/env bash
# Local GitHub Actions workflow simulator
# Tests the build pipeline without pushing to Docker Hub

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Local GitHub Actions Pipeline Test${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo

# Simulate GITHUB_SHA
MOCK_SHA=$(git rev-parse HEAD 2>/dev/null || echo "local-build-$(date +%s)")
SHORT_SHA="${MOCK_SHA:0:12}"

echo -e "${GREEN}✓ Step 1: Lint${NC}"
echo "  Running lint script..."
cd "$PROJECT_ROOT"
chmod +x ci/lint.sh
if ./ci/lint.sh; then
  echo -e "${GREEN}  ✓ Lint passed${NC}"
else
  echo -e "${RED}  ✗ Lint failed${NC}"
  exit 1
fi
echo

echo -e "${GREEN}✓ Step 2: Build & Test Drupal 11 Image${NC}"
IMAGE_NAME="scbd/drupal-docker-wrapper"
TAG_11="11-ci-$SHORT_SHA"

echo "  Building $IMAGE_NAME:$TAG_11 ..."
if docker build -t "$IMAGE_NAME:$TAG_11" .; then
  echo -e "${GREEN}  ✓ Build succeeded${NC}"
else
  echo -e "${RED}  ✗ Build failed${NC}"
  exit 1
fi

echo "  Running smoke test..."
chmod +x ci/smoke-test.sh
if bash ci/smoke-test.sh "$IMAGE_NAME:$TAG_11"; then
  echo -e "${GREEN}  ✓ Smoke test passed${NC}"
else
  echo -e "${RED}  ✗ Smoke test failed${NC}"
  exit 1
fi
echo

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ All pipeline steps passed!${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo
echo "Built images:"
echo "  - $IMAGE_NAME:$TAG_11"
echo
echo "To clean up these test images:"
echo "  docker rmi $IMAGE_NAME:$TAG_11"
echo
