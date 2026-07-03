#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${1:-}"
if [[ -z "$CONTAINER" ]]; then
  echo "Usage: $0 <container>"
  exit 1
fi

docker logs -f --tail=200 "$CONTAINER"
