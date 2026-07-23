#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/deploy.sh <environment>
  scripts/deploy.sh --config-root <absolute-path> --check
  scripts/deploy.sh --config-root <absolute-path> --apply [--allow-new-project]

Examples:
  scripts/deploy.sh prod-app
  scripts/deploy.sh --config-root /etc/server-infra --check
  scripts/deploy.sh --config-root /etc/server-infra --apply

The positional environment form is the legacy rollback path.

The explicit config-root form requires exactly one operation:
  --check  Run all validation without changing runtime state.
  --apply  Run the same preflight, then deploy.

By default, --apply requires every expected Compose project to exist already.
Use --allow-new-project only when intentionally deploying a new module.
USAGE
}

verify_required_env() {
  local required_env="$1"
  local missing=0

  for variable_name in $required_env; do
    if [[ -z "${!variable_name:-}" ]]; then
      warn "Missing required env variable: $variable_name"
      missing=1
    fi
  done

  [[ "$missing" == "0" ]] || fail "Required environment variables are missing"
}

deploy_legacy_module() {
  local environment_name="$1"
  local environment_dir="$2"
  local module_name="$3"

  local module_dir
  local compose_file
  local module_env
  local project_name

  load_module "$module_name"

  local module_dir="$MODULE_DIR"
  local compose_file="$module_dir/docker-compose.yml"
  module_env="$(module_env_file "$environment_dir" "$module_name")"
  project_name="server_infra_${environment_name}_${module_name}"

  if [[ -n "${REQUIRED_ENV:-}" ]]; then
    [[ -f "$module_env" ]] || fail "Missing module config: $module_env"
    set -a
    # shellcheck source=/dev/null
    source "$module_env"
    set +a
    verify_required_env "$REQUIRED_ENV"
  fi

  log "Deploying module: $module_name"

  if [[ -f "$module_env" ]]; then
    MODULE_ENV_FILE="$module_env" docker compose \
      --env-file "$module_env" \
      -p "$project_name" \
      -f "$compose_file" \
      up -d
  else
    MODULE_ENV_FILE="$module_env" docker compose \
      -p "$project_name" \
      -f "$compose_file" \
      up -d
  fi
}

deploy_legacy_environment() {
  local environment_name="$1"

  load_environment "$environment_name"
  local environment_dir="$ENVIRONMENT_DIR"

  log "Deploying legacy environment: $environment_name"
  ensure_docker_network "server-infra"

  for module_name in $ENABLED_MODULES; do
    deploy_legacy_module "$environment_name" "$environment_dir" "$module_name"
  done

  log "Legacy deployment complete: $environment_name"
}

run_controlled_compose() {
  local module_env="$1"
  shift

  local controlled_env=("PATH=$PATH" "MODULE_ENV_FILE=$module_env")

  [[ -z "${HOME+x}" ]] || controlled_env+=("HOME=$HOME")
  [[ -z "${DOCKER_HOST+x}" ]] || controlled_env+=("DOCKER_HOST=$DOCKER_HOST")
  [[ -z "${DOCKER_CONTEXT+x}" ]] || controlled_env+=("DOCKER_CONTEXT=$DOCKER_CONTEXT")
  [[ -z "${DOCKER_CONFIG+x}" ]] || controlled_env+=("DOCKER_CONFIG=$DOCKER_CONFIG")
  [[ -z "${DOCKER_TLS_VERIFY+x}" ]] || \
    controlled_env+=("DOCKER_TLS_VERIFY=$DOCKER_TLS_VERIFY")
  [[ -z "${DOCKER_CERT_PATH+x}" ]] || \
    controlled_env+=("DOCKER_CERT_PATH=$DOCKER_CERT_PATH")
  [[ -z "${XDG_CONFIG_HOME+x}" ]] || \
    controlled_env+=("XDG_CONFIG_HOME=$XDG_CONFIG_HOME")
  [[ -z "${XDG_RUNTIME_DIR+x}" ]] || \
    controlled_env+=("XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR")
  [[ -z "${TMPDIR+x}" ]] || controlled_env+=("TMPDIR=$TMPDIR")

  env -i "${controlled_env[@]}" "$@"
}

external_compose() {
  local config_root="$1"
  local instance="$2"
  local module_name="$3"
  shift 3

  local module_dir="$REPO_ROOT/$module_name"
  local compose_file="$module_dir/docker-compose.yml"
  local module_env="$config_root/$module_name/runtime.env"
  local project_name="server_infra_${instance}_${module_name}"
  local compose_options=(
    --project-directory "$module_dir"
    -p "$project_name"
    -f "$compose_file"
  )

  if [[ -f "$module_env" ]]; then
    compose_options=(--env-file "$module_env" "${compose_options[@]}")
  fi

  run_controlled_compose "$module_env" \
    docker compose "${compose_options[@]}" "$@"
}

compose_project_exists() {
  local project_name="$1"
  local container_ids

  container_ids="$(run_controlled_compose "" \
    docker ps -a \
      --filter "label=com.docker.compose.project=$project_name" \
      --format '{{.ID}}')" || fail "Unable to inspect Compose project: $project_name"

  [[ -n "$container_ids" ]]
}

load_external_context() {
  local config_root="$1"
  local server_file="$config_root/server.env"
  local modules_file="$config_root/modules.env"
  local enabled_modules

  "$SCRIPT_DIR/validate-config.sh" --config-root "$config_root"

  EXTERNAL_INSTANCE="$(read_env_value "$server_file" "SERVER_INFRA_INSTANCE")"
  enabled_modules="$(read_env_value "$modules_file" "ENABLED_MODULES")"
  read -r -a EXTERNAL_MODULES <<< "$enabled_modules"
}

deploy_external_environment() {
  local config_root="$1"
  local operation="$2"
  local allow_new_project="$3"
  local module_name
  local project_name

  load_external_context "$config_root"

  log "Running Compose preflight"
  for module_name in "${EXTERNAL_MODULES[@]}"; do
    external_compose "$config_root" "$EXTERNAL_INSTANCE" "$module_name" \
      config --quiet
    project_name="server_infra_${EXTERNAL_INSTANCE}_${module_name}"
    ok "compose configuration: $module_name (project: $project_name)"

    if compose_project_exists "$project_name"; then
      ok "existing Compose project: $project_name"
    elif [[ "$operation" == "apply" && "$allow_new_project" == "0" ]]; then
      fail "Compose project does not exist: $project_name"
    else
      warn "Compose project does not exist: $project_name"
    fi
  done

  if [[ "$operation" == "check" ]]; then
    ok "deployment preflight complete; no runtime changes made"
    return
  fi

  ensure_docker_network "server-infra"

  for module_name in "${EXTERNAL_MODULES[@]}"; do
    log "Deploying module: $module_name"
    external_compose "$config_root" "$EXTERNAL_INSTANCE" "$module_name" up -d
  done

  log "External configuration deployment complete"
}

main() {
  local config_root=""
  local config_root_set=0
  local operation=""
  local allow_new_project=0
  local environment_name=""

  while (($# > 0)); do
    case "$1" in
      --config-root)
        (($# >= 2)) || fail "Missing value for --config-root"
        [[ "$config_root_set" == "0" ]] || fail "--config-root may be specified only once"
        [[ -n "$2" ]] || fail "Missing value for --config-root"
        config_root="$2"
        config_root_set=1
        shift 2
        ;;
      --config-root=*)
        [[ "$config_root_set" == "0" ]] || fail "--config-root may be specified only once"
        config_root="${1#*=}"
        [[ -n "$config_root" ]] || fail "Missing value for --config-root"
        config_root_set=1
        shift
        ;;
      --check)
        [[ -z "$operation" ]] || fail "Specify exactly one of --check or --apply"
        operation="check"
        shift
        ;;
      --apply)
        [[ -z "$operation" ]] || fail "Specify exactly one of --check or --apply"
        operation="apply"
        shift
        ;;
      --allow-new-project)
        [[ "$allow_new_project" == "0" ]] || \
          fail "--allow-new-project may be specified only once"
        allow_new_project=1
        shift
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      -*)
        fail "Unknown argument: $1"
        ;;
      *)
        [[ -z "$environment_name" ]] || fail "Only one environment may be specified"
        environment_name="$1"
        shift
        ;;
    esac
  done

  if [[ "$config_root_set" == "1" ]]; then
    [[ -z "$environment_name" ]] || \
      fail "Do not combine an environment name with --config-root"
    [[ -n "$operation" ]] || \
      fail "External configuration requires exactly one of --check or --apply"
    if [[ "$allow_new_project" == "1" && "$operation" != "apply" ]]; then
      fail "--allow-new-project requires --apply"
    fi

    require_command docker
    require_command env
    docker compose version >/dev/null || fail "Docker Compose is not available"

    deploy_external_environment "$config_root" "$operation" "$allow_new_project"
    return
  fi

  [[ -n "$environment_name" ]] || { usage; exit 1; }
  [[ -z "$operation" ]] || fail "--check and --apply require --config-root"
  [[ "$allow_new_project" == "0" ]] || \
    fail "--allow-new-project requires --config-root and --apply"

  require_command docker
  docker compose version >/dev/null || fail "Docker Compose is not available"

  deploy_legacy_environment "$environment_name"
}

main "$@"
