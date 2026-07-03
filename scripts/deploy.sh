#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_NAME="${1:-}"

if [[ -z "$ENV_NAME" ]]; then
  echo "Usage: $0 <environment>"
  echo "Example: $0 prod-app"
  exit 1
fi

ENV_DIR="$ROOT_DIR/environments/$ENV_NAME"
ENV_FILE="$ENV_DIR/environment.yaml"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Environment not found: $ENV_FILE"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required"
  exit 1
fi

mapfile -t MODULES < <(python3 - "$ENV_FILE" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
in_modules = False
for line in lines:
    stripped = line.strip()
    if stripped == "enabledModules:":
        in_modules = True
        continue
    if in_modules:
        if stripped.startswith("-"):
            print(stripped[1:].strip())
        elif stripped and not line.startswith(" "):
            break
PY
)

if [[ ${#MODULES[@]} -eq 0 ]]; then
  echo "No enabled modules found in $ENV_FILE"
  exit 1
fi

ensure_network() {
  local network_name="server-public"
  if ! docker network inspect "$network_name" >/dev/null 2>&1; then
    echo "Creating Docker network: $network_name"
    docker network create "$network_name" >/dev/null
  fi
}

ensure_network

for module in "${MODULES[@]}"; do
  MODULE_DIR="$ROOT_DIR/$module"
  COMPOSE_FILE="$MODULE_DIR/docker-compose.yml"
  MODULE_ENV_FILE="$ENV_DIR/$module/config.env"

  if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "Skipping module '$module': compose file not found"
    continue
  fi

  if [[ ! -f "$MODULE_ENV_FILE" ]]; then
    EXAMPLE_FILE="$ENV_DIR/$module/config.env.example"
    if [[ -f "$EXAMPLE_FILE" ]]; then
      echo "Missing $MODULE_ENV_FILE"
      echo "Create it from $EXAMPLE_FILE"
      exit 1
    fi
    MODULE_ENV_FILE="/dev/null"
  fi

  echo "Deploying module: $module"
  (
    cd "$MODULE_DIR"
    MODULE_ENV_FILE="$MODULE_ENV_FILE" docker compose \
      --project-name "server-${module}" \
      --env-file "$MODULE_ENV_FILE" \
      -f "$COMPOSE_FILE" \
      up -d
  )
done

echo "Deployment finished: $ENV_NAME"
