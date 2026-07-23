#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

CONFIG_ROOT="/etc/server-infra"
OUTPUT_PATH=""
TEMP_FILE=""

usage() {
  cat <<'USAGE'
Usage:
  scripts/export-break-glass.sh \
    --output <absolute-path>/server-infra-break-glass.txt \
    [--config-root <absolute-path>]

Creates a complete secret recovery record from the active backup
configuration and the current server-infra Git checkout.

The output file:

- is created with mode 0600;
- belongs to the invoking sudo user when one is available;
- is never printed to the terminal;
- is never overwritten;
- must be outside the repository and active configuration root.

Defaults to:
  --config-root /etc/server-infra
USAGE
}

validate_absolute_path() {
  local path_value="$1"
  local path_label="$2"

  [[ "$path_value" == /* ]] || fail "$path_label must be an absolute path"
  [[ "$path_value" != *".."* ]] || fail "$path_label must not contain .."
  [[ "$path_value" != *"//"* ]] || fail "$path_label must not contain //"
  [[ "$path_value" != *$'\n'* && "$path_value" != *$'\r'* ]] || \
    fail "$path_label contains an invalid line break"
}

validate_no_symlink_components() {
  local path_value="$1"
  local path_label="$2"
  local current_path=""
  local component
  local components=()

  IFS='/' read -r -a components <<< "${path_value#/}"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current_path="$current_path/$component"
    [[ ! -L "$current_path" ]] || \
      fail "$path_label contains a symlinked path component: $current_path"
  done
}

validate_record_value() {
  local value="$1"
  local value_label="$2"

  [[ -n "$value" ]] || fail "$value_label must not be empty"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || \
    fail "$value_label contains an invalid line break"
}

validate_repository_url() {
  local repository_url="$1"
  local authority
  local user_info

  validate_record_value "$repository_url" "Git repository URL"
  [[ "$repository_url" != *[[:space:]]* ]] || \
    fail "Git repository URL must not contain whitespace"
  [[ "$repository_url" != *"?"* && "$repository_url" != *"#"* ]] || \
    fail "Git repository URL must not contain query parameters or fragments"

  case "$repository_url" in
    https://* | ssh://* | git@*:*)
      ;;
    *)
      fail "Unsupported Git repository URL: use HTTPS or SSH"
      ;;
  esac

  if [[ "$repository_url" == https://* ]]; then
    authority="${repository_url#https://}"
    authority="${authority%%/*}"
    [[ "$authority" != *"@"* ]] || \
      fail "Git repository URL must not contain embedded credentials"
  elif [[ "$repository_url" == ssh://* ]]; then
    authority="${repository_url#ssh://}"
    authority="${authority%%/*}"
    if [[ "$authority" == *"@"* ]]; then
      user_info="${authority%@*}"
      [[ "$user_info" != *":"* ]] || \
        fail "Git repository URL must not contain embedded credentials"
    fi
  fi
}

read_restic_password() {
  local password_file="$1"
  local line_count
  local password=""

  [[ -f "$password_file" ]] || \
    fail "Restic password file not found: $password_file"
  [[ -r "$password_file" ]] || \
    fail "Restic password file is not readable: $password_file"
  [[ ! -L "$password_file" ]] || \
    fail "Restic password file must not be a symlink: $password_file"

  line_count="$(awk 'END { print NR }' "$password_file")"
  [[ "$line_count" == "1" ]] || \
    fail "Restic password file must contain exactly one line"

  IFS= read -r password < "$password_file" || [[ -n "$password" ]] || \
    fail "Restic password file is empty"
  validate_record_value "$password" "Restic password"
  printf '%s' "$password"
}

parse_arguments() {
  local config_root_set=0
  local output_set=0

  while (($# > 0)); do
    case "$1" in
      --config-root)
        (($# >= 2)) || fail "Missing value for --config-root"
        [[ "$config_root_set" == "0" ]] || \
          fail "--config-root may be specified only once"
        CONFIG_ROOT="$2"
        config_root_set=1
        shift 2
        ;;
      --config-root=*)
        [[ "$config_root_set" == "0" ]] || \
          fail "--config-root may be specified only once"
        CONFIG_ROOT="${1#*=}"
        [[ -n "$CONFIG_ROOT" ]] || fail "Missing value for --config-root"
        config_root_set=1
        shift
        ;;
      --output)
        (($# >= 2)) || fail "Missing value for --output"
        [[ "$output_set" == "0" ]] || fail "--output may be specified only once"
        OUTPUT_PATH="$2"
        output_set=1
        shift 2
        ;;
      --output=*)
        [[ "$output_set" == "0" ]] || fail "--output may be specified only once"
        OUTPUT_PATH="${1#*=}"
        [[ -n "$OUTPUT_PATH" ]] || fail "Missing value for --output"
        output_set=1
        shift
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$OUTPUT_PATH" ]] || fail "--output is required"
}

validate_output() {
  local output_dir="${OUTPUT_PATH%/*}"
  local physical_output_dir
  local physical_repo_root
  local physical_config_root

  [[ -n "$output_dir" ]] || output_dir="/"
  validate_absolute_path "$OUTPUT_PATH" "Output path"
  [[ "${OUTPUT_PATH##*/}" == "server-infra-break-glass.txt" ]] || \
    fail "Output filename must be server-infra-break-glass.txt"
  [[ -d "$output_dir" ]] || fail "Output directory not found: $output_dir"
  validate_no_symlink_components "$output_dir" "Output directory"
  [[ ! -e "$OUTPUT_PATH" && ! -L "$OUTPUT_PATH" ]] || \
    fail "Refusing to overwrite existing output: $OUTPUT_PATH"

  physical_output_dir="$(cd "$output_dir" && pwd -P)"
  physical_repo_root="$(cd "$REPO_ROOT" && pwd -P)"
  physical_config_root="$(cd "$CONFIG_ROOT" && pwd -P)"

  case "$physical_output_dir/" in
    "$physical_repo_root/"*)
      fail "Output must be outside the server-infra repository"
      ;;
    "$physical_config_root/"*)
      fail "Output must be outside the active configuration root"
      ;;
  esac
}

cleanup() {
  if [[ -n "$TEMP_FILE" && -f "$TEMP_FILE" ]]; then
    rm -f -- "$TEMP_FILE"
  fi
}

main() {
  local server_file
  local runtime_file
  local restic_password_file
  local server_instance
  local restic_repository
  local restic_password
  local aws_access_key_id
  local aws_secret_access_key
  local aws_default_region
  local repository_url
  local repository_ref
  local generated_at
  local output_dir

  parse_arguments "$@"
  validate_config_root_path "$CONFIG_ROOT"
  validate_absolute_path "$CONFIG_ROOT" "Configuration root"
  [[ -d "$CONFIG_ROOT" && ! -L "$CONFIG_ROOT" ]] || \
    fail "Configuration root is not a regular directory: $CONFIG_ROOT"

  if [[ "$(uname -s)" == "Linux" && \
    "${CONFIG_ROOT%/}" == "/etc/server-infra" && "$(id -u)" != "0" ]]; then
    fail "Default host configuration export must run as root"
  fi

  validate_output
  require_command awk
  require_command date
  require_command git
  require_command ln
  require_command mktemp
  if [[ -n "${SUDO_UID:-}" || -n "${SUDO_GID:-}" ]]; then
    require_command chown
  fi

  "$REPO_ROOT/backup/bin/server-infra-backup" \
    --config-root "$CONFIG_ROOT" validate >/dev/null

  server_file="$CONFIG_ROOT/server.env"
  runtime_file="$CONFIG_ROOT/backup/runtime.env"
  server_instance="$(read_required_env_value "$server_file" "SERVER_INFRA_INSTANCE")"
  restic_repository="$(read_required_env_value "$runtime_file" "RESTIC_REPOSITORY")"
  restic_password_file="$(
    read_required_env_value "$runtime_file" "RESTIC_PASSWORD_FILE"
  )"
  aws_access_key_id="$(read_required_env_value "$runtime_file" "AWS_ACCESS_KEY_ID")"
  aws_secret_access_key="$(
    read_required_env_value "$runtime_file" "AWS_SECRET_ACCESS_KEY"
  )"
  aws_default_region="$(
    read_required_env_value "$runtime_file" "AWS_DEFAULT_REGION"
  )"
  restic_password="$(read_restic_password "$restic_password_file")"

  repository_url="$(git -C "$REPO_ROOT" remote get-url origin)" || \
    fail "Unable to read the server-infra origin URL"
  repository_ref="$(git -C "$REPO_ROOT" rev-parse HEAD)" || \
    fail "Unable to read the server-infra Git commit"
  [[ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]] || \
    fail "Tracked server-infra files are modified; commit or restore them before export"

  validate_repository_url "$repository_url"
  [[ "$repository_ref" =~ ^[0-9a-f]{40}$ || \
    "$repository_ref" =~ ^[0-9a-f]{64}$ ]] || \
    fail "Invalid server-infra Git commit"

  validate_record_value "$server_instance" "Server instance"
  validate_record_value "$restic_repository" "Restic repository"
  validate_record_value "$aws_access_key_id" "AWS access key ID"
  validate_record_value "$aws_secret_access_key" "AWS secret access key"
  validate_record_value "$aws_default_region" "AWS region"

  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  output_dir="${OUTPUT_PATH%/*}"
  [[ -n "$output_dir" ]] || output_dir="/"
  umask 077
  TEMP_FILE="$(mktemp "$output_dir/.server-infra-break-glass.XXXXXX")"
  trap cleanup EXIT

  {
    printf '%s\n\n' "SERVER INFRA BREAK-GLASS RECORD"
    printf '%s\n' "Sensitive: yes"
    printf '%s\n' \
      "Storage: password manager secure document and, optionally, encrypted offline media"
    printf '%s\n\n' \
      "Server copy: do not keep a permanent copy on the backed-up server"
    printf '%s\n' "BREAK_GLASS_VERSION: 1"
    printf '%s\n' "GENERATED_AT: $generated_at"
    printf '%s\n' "SERVER_INFRA_INSTANCE: $server_instance"
    printf '%s\n' "SERVER_INFRA_REPOSITORY_URL: $repository_url"
    printf '%s\n\n' "SERVER_INFRA_REPOSITORY_REF: $repository_ref"
    printf '%s\n' "RESTIC_REPOSITORY: $restic_repository"
    printf '%s\n' "RESTIC_PASSWORD: $restic_password"
    printf '%s\n' "AWS_ACCESS_KEY_ID: $aws_access_key_id"
    printf '%s\n' "AWS_SECRET_ACCESS_KEY: $aws_secret_access_key"
    printf '%s\n\n' "AWS_DEFAULT_REGION: $aws_default_region"
    printf '%s\n\n' "GIT ACCESS"
    printf '%s\n' \
      "Git credentials and SSH private keys do not belong in this record."
    printf '%s\n\n' \
      "Recovery uses a newly authorized SSH key or the operator's Git provider account."
    printf '%s\n\n' "LAST VERIFIED"
    printf '%s\n' "Date: not-recorded"
    printf '%s\n' "Operator: not-recorded"
    printf '%s\n' "Config restore snapshot: not-recorded"
    printf '%s\n' "Data restore snapshot: not-recorded"
    printf '%s\n' \
      "Notes: Update these fields in the secure record after a successful restore test."
  } > "$TEMP_FILE"

  chmod 0600 "$TEMP_FILE"
  if [[ -n "${SUDO_UID:-}" || -n "${SUDO_GID:-}" ]]; then
    [[ "${SUDO_UID:-}" =~ ^[0-9]+$ && "${SUDO_GID:-}" =~ ^[0-9]+$ ]] || \
      fail "Invalid sudo user ownership metadata"
    chown "$SUDO_UID:$SUDO_GID" "$TEMP_FILE"
  fi
  if ! ln "$TEMP_FILE" "$OUTPUT_PATH"; then
    fail "Unable to create output without overwriting an existing file"
  fi
  rm -f -- "$TEMP_FILE"
  TEMP_FILE=""

  ok "break-glass record created with mode 0600: $OUTPUT_PATH"
  warn "Import it into the password manager, update LAST VERIFIED, then remove the plaintext file"
}

main "$@"
