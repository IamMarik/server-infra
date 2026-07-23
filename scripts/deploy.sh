#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

HOST_EXEC_ROOT="/usr/local/libexec/server-infra"
HOST_COMMAND_ROOT="/usr/local/bin"
SYSTEMD_UNIT_ROOT="/etc/systemd/system"
HOST_STATE_ROOT="/var/lib/server-infra"
HOST_CACHE_ROOT="/var/cache/server-infra"
EXTERNAL_HAS_COMPOSE=0
EXTERNAL_HAS_HOST=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/deploy.sh <environment>
  scripts/deploy.sh --check [--config-root <absolute-path>]
  scripts/deploy.sh --apply [--config-root <absolute-path>] \
    [--allow-new-project]

Examples:
  scripts/deploy.sh prod-app
  scripts/deploy.sh --check
  scripts/deploy.sh --apply

The positional environment form is the legacy rollback path.

The operation form uses /etc/server-infra by default:
  --check  Run all validation without changing runtime state.
  --apply  Run the same preflight, then deploy.

Use --config-root only for a non-standard configuration directory.
By default, --apply requires every expected Compose project to exist already.
Use --allow-new-project only when intentionally deploying a new Compose
module.
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

module_driver() {
  local module_name="$1"
  local manifest_file="$REPO_ROOT/$module_name/module.env"

  read_required_env_value "$manifest_file" "MODULE_DRIVER"
}

classify_external_modules() {
  local module_name
  local driver

  EXTERNAL_HAS_COMPOSE=0
  EXTERNAL_HAS_HOST=0

  for module_name in "${EXTERNAL_MODULES[@]}"; do
    driver="$(module_driver "$module_name")"
    case "$driver" in
      compose)
        EXTERNAL_HAS_COMPOSE=1
        ;;
      host)
        EXTERNAL_HAS_HOST=1
        ;;
      *)
        fail "Unsupported MODULE_DRIVER for $module_name: $driver"
        ;;
    esac
  done
}

prepare_external_tools() {
  local operation="$1"
  local module_name
  local manifest_file
  local host_required_commands
  local required_commands=()
  local command_name

  if [[ "$EXTERNAL_HAS_COMPOSE" == "1" ]]; then
    require_command docker
    require_command env
    docker compose version >/dev/null || fail "Docker Compose is not available"
  fi

  if [[ "$EXTERNAL_HAS_HOST" == "1" && "$operation" == "apply" ]]; then
    [[ "$(uname -s)" == "Linux" ]] || fail "Applying host modules requires Linux"
    [[ "$EUID" == "0" ]] || fail "Applying host modules requires root privileges"
    require_command install
    require_command mktemp
    require_command mv
    require_command rm
    require_command systemctl

    for module_name in "${EXTERNAL_MODULES[@]}"; do
      [[ "$(module_driver "$module_name")" == "host" ]] || continue
      manifest_file="$REPO_ROOT/$module_name/module.env"
      host_required_commands="$(
        read_required_env_value "$manifest_file" "HOST_REQUIRED_COMMANDS"
      )"
      [[ -n "$host_required_commands" ]] || continue

      read -r -a required_commands <<< "$host_required_commands"
      for command_name in "${required_commands[@]}"; do
        require_command "$command_name"
      done
      required_commands=()
    done
  fi
}

run_host_module_preflight() {
  local config_root="$1"
  local module_name="$2"
  local module_dir="$REPO_ROOT/$module_name"
  local manifest_file="$module_dir/module.env"
  local host_preflight_executable

  host_preflight_executable="$(
    read_required_env_value "$manifest_file" "HOST_PREFLIGHT_EXECUTABLE"
  )"

  [[ -n "$host_preflight_executable" ]] || return

  "$module_dir/$host_preflight_executable" \
    --config-root "$config_root" \
    validate
}

install_host_file_atomic() {
  local source_file="$1"
  local destination_file="$2"
  local destination_mode="$3"
  local destination_dir="${destination_file%/*}"
  local destination_name="${destination_file##*/}"
  local temporary_file

  [[ -f "$source_file" ]] || fail "Host artifact not found: $source_file"
  [[ ! -L "$source_file" ]] || fail "Host artifact must not be a symlink: $source_file"
  [[ -d "$destination_dir" ]] || \
    fail "Host artifact destination directory not found: $destination_dir"
  [[ ! -L "$destination_dir" ]] || \
    fail "Host artifact destination directory must not be a symlink: $destination_dir"

  temporary_file="$(mktemp "$destination_dir/.${destination_name}.tmp.XXXXXX")"
  if ! install \
    -o root \
    -g root \
    -m "$destination_mode" \
    "$source_file" \
    "$temporary_file"; then
    rm -f -- "$temporary_file"
    fail "Unable to prepare host artifact: $destination_file"
  fi

  if ! mv -f -- "$temporary_file" "$destination_file"; then
    rm -f -- "$temporary_file"
    fail "Unable to install host artifact: $destination_file"
  fi

  ok "installed host artifact: $destination_file"
}

install_host_module_artifacts() {
  local module_name="$1"
  local module_dir="$REPO_ROOT/$module_name"
  local manifest_file="$module_dir/module.env"
  local host_executables
  local host_public_executables
  local host_state_dirs
  local host_cache_dirs
  local systemd_units
  local executable_paths=()
  local public_executable_paths=()
  local managed_dirs=()
  local unit_paths=()
  local relative_path
  local module_exec_root="$HOST_EXEC_ROOT/$module_name"
  local managed_dir_spec
  local managed_root
  local managed_dir_list

  host_executables="$(
    read_required_env_value "$manifest_file" "HOST_EXECUTABLES"
  )"
  host_public_executables="$(
    read_required_env_value "$manifest_file" "HOST_PUBLIC_EXECUTABLES"
  )"
  host_state_dirs="$(read_required_env_value "$manifest_file" "HOST_STATE_DIRS")"
  host_cache_dirs="$(read_required_env_value "$manifest_file" "HOST_CACHE_DIRS")"
  systemd_units="$(read_required_env_value "$manifest_file" "SYSTEMD_UNITS")"

  [[ ! -L "$HOST_STATE_ROOT" ]] || \
    fail "Host state root must not be a symlink: $HOST_STATE_ROOT"
  [[ ! -L "$HOST_CACHE_ROOT" ]] || \
    fail "Host cache root must not be a symlink: $HOST_CACHE_ROOT"
  install -d -o root -g root -m 0750 "$HOST_STATE_ROOT"
  install -d -o root -g root -m 0750 "$HOST_CACHE_ROOT"

  for managed_dir_spec in \
    "$HOST_STATE_ROOT/$module_name:$host_state_dirs" \
    "$HOST_CACHE_ROOT/$module_name:$host_cache_dirs"; do
    managed_root="${managed_dir_spec%%:*}"
    managed_dir_list="${managed_dir_spec#*:}"
    [[ ! -L "$managed_root" ]] || \
      fail "Host managed directory root must not be a symlink: $managed_root"
    install -d -o root -g root -m 0750 "$managed_root"
    [[ -n "$managed_dir_list" ]] || continue

    read -r -a managed_dirs <<< "$managed_dir_list"
    for relative_path in "${managed_dirs[@]}"; do
      [[ ! -L "$managed_root/$relative_path" ]] || \
        fail "Host managed directory must not be a symlink: $managed_root/$relative_path"
      install -d -o root -g root -m 0750 "$managed_root/$relative_path"
      ok "host managed directory: $managed_root/$relative_path"
    done
    managed_dirs=()
  done

  if [[ -n "$host_executables" ]]; then
    [[ ! -L "$HOST_EXEC_ROOT" ]] || \
      fail "Host executable root must not be a symlink: $HOST_EXEC_ROOT"
    install -d -o root -g root -m 0755 "$HOST_EXEC_ROOT"
    [[ ! -L "$module_exec_root" ]] || \
      fail "Module executable root must not be a symlink: $module_exec_root"
    install -d -o root -g root -m 0755 "$module_exec_root"

    read -r -a executable_paths <<< "$host_executables"
    for relative_path in "${executable_paths[@]}"; do
      install_host_file_atomic \
        "$module_dir/$relative_path" \
        "$module_exec_root/${relative_path##*/}" \
        0755
    done
  fi

  if [[ -n "$host_public_executables" ]]; then
    [[ ! -L "$HOST_COMMAND_ROOT" ]] || \
      fail "Host command root must not be a symlink: $HOST_COMMAND_ROOT"
    install -d -o root -g root -m 0755 "$HOST_COMMAND_ROOT"
    read -r -a public_executable_paths <<< "$host_public_executables"
    for relative_path in "${public_executable_paths[@]}"; do
      install_host_file_atomic \
        "$module_dir/$relative_path" \
        "$HOST_COMMAND_ROOT/${relative_path##*/}" \
        0755
    done
  fi

  [[ -d "$SYSTEMD_UNIT_ROOT" ]] || \
    fail "Systemd unit directory not found: $SYSTEMD_UNIT_ROOT"
  [[ ! -L "$SYSTEMD_UNIT_ROOT" ]] || \
    fail "Systemd unit directory must not be a symlink: $SYSTEMD_UNIT_ROOT"

  read -r -a unit_paths <<< "$systemd_units"
  for relative_path in "${unit_paths[@]}"; do
    install_host_file_atomic \
      "$module_dir/$relative_path" \
      "$SYSTEMD_UNIT_ROOT/${relative_path##*/}" \
      0644
  done
}

enable_host_module() {
  local module_name="$1"
  local manifest_file="$REPO_ROOT/$module_name/module.env"
  local systemd_enable_units
  local enable_units=()
  local unit_name

  systemd_enable_units="$(
    read_required_env_value "$manifest_file" "SYSTEMD_ENABLE_UNITS"
  )"

  if [[ -z "$systemd_enable_units" ]]; then
    ok "host module installed without enabled units: $module_name"
    return
  fi

  read -r -a enable_units <<< "$systemd_enable_units"
  for unit_name in "${enable_units[@]}"; do
    systemctl enable --now "$unit_name"
    ok "enabled host unit: $unit_name"
  done
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
  classify_external_modules
}

deploy_external_environment() {
  local config_root="$1"
  local operation="$2"
  local allow_new_project="$3"
  local module_name
  local project_name
  local driver

  load_external_context "$config_root"
  prepare_external_tools "$operation"

  if [[ "$allow_new_project" == "1" && "$EXTERNAL_HAS_COMPOSE" == "0" ]]; then
    fail "--allow-new-project requires at least one Compose module"
  fi

  log "Running module preflight"
  for module_name in "${EXTERNAL_MODULES[@]}"; do
    driver="$(module_driver "$module_name")"
    case "$driver" in
      compose)
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
        ;;
      host)
        validate_host_module_contract "$module_name"
        run_host_module_preflight "$config_root" "$module_name"
        ok "host module contract: $module_name"
        ;;
      *)
        fail "Unsupported MODULE_DRIVER for $module_name: $driver"
        ;;
    esac
  done

  if [[ "$operation" == "check" ]]; then
    ok "deployment preflight complete; no runtime changes made"
    return
  fi

  acquire_deployment_lock "/run/server-infra"

  if [[ "$EXTERNAL_HAS_COMPOSE" == "1" ]]; then
    ensure_docker_network "server-infra"
  fi

  if [[ "$EXTERNAL_HAS_HOST" == "1" ]]; then
    for module_name in "${EXTERNAL_MODULES[@]}"; do
      [[ "$(module_driver "$module_name")" == "host" ]] || continue
      log "Installing host module artifacts: $module_name"
      install_host_module_artifacts "$module_name"
    done
    systemctl daemon-reload
    ok "systemd configuration reloaded"
  fi

  for module_name in "${EXTERNAL_MODULES[@]}"; do
    driver="$(module_driver "$module_name")"
    case "$driver" in
      compose)
        log "Deploying Compose module: $module_name"
        external_compose "$config_root" "$EXTERNAL_INSTANCE" "$module_name" up -d
        ;;
      host)
        log "Activating host module: $module_name"
        enable_host_module "$module_name"
        ;;
      *)
        fail "Unsupported MODULE_DRIVER for $module_name: $driver"
        ;;
    esac
  done

  log "External configuration deployment complete"
}

main() {
  local config_root="/etc/server-infra"
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

  if [[ -n "$operation" || "$config_root_set" == "1" || \
    "$allow_new_project" == "1" ]]; then
    [[ -z "$environment_name" ]] || \
      fail "Do not combine an environment name with external deployment options"
    [[ -n "$operation" ]] || \
      fail "External configuration requires exactly one of --check or --apply"
    if [[ "$allow_new_project" == "1" && "$operation" != "apply" ]]; then
      fail "--allow-new-project requires --apply"
    fi

    deploy_external_environment "$config_root" "$operation" "$allow_new_project"
    return
  fi

  [[ -n "$environment_name" ]] || { usage; exit 1; }

  require_command docker
  docker compose version >/dev/null || fail "Docker Compose is not available"

  deploy_legacy_environment "$environment_name"
}

main "$@"
