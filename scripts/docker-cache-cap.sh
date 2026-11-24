#!/usr/bin/env bash
# Cap the Docker BUILD cache at KIT_BUILD_CACHE_KEEP (default 40GB), keeping the most recently used layers.
# Call it AFTER a deploy that passed its health check, never before: a deploy that is still failing keeps the layers it needs
# to be re-run fast. Every deploy adds layers; with no cap one project's cache reached 180 GB and filled the disk.
# Usage: scripts/docker-cache-cap.sh [--dry-run]
#   --dry-run  print the command it would run and change nothing.
# A prune failure only WARNS and still exits 0: the deploy it follows has already succeeded. No docker on the host = a note, exit 0.
# Seam for tests: KIT_DOCKER_BIN (default `docker`).
keep="${KIT_BUILD_CACHE_KEEP:-40GB}"
docker_bin="${KIT_DOCKER_BIN:-docker}"
dry=0
case "${1:-}" in
  "") ;;
  --dry-run) dry=1 ;;
  *) echo "usage: scripts/docker-cache-cap.sh [--dry-run]" >&2; exit 2 ;;
esac
command -v "$docker_bin" >/dev/null 2>&1 || { echo "docker-cache-cap: $docker_bin not found; nothing to trim" >&2; exit 0; }
if [ "$dry" = 1 ]; then echo "docker-cache-cap: would run: $docker_bin builder prune --force --max-used-space $keep"; exit 0; fi
echo "docker-cache-cap: trimming the Docker build cache down to $keep..."
"$docker_bin" builder prune --force --max-used-space "$keep" >/dev/null 2>&1 \
  || echo "docker-cache-cap: WARNING: docker builder prune failed (cache not trimmed)" >&2
exit 0
