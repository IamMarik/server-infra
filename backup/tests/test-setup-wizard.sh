#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_TMPDIR="${TMPDIR:-/tmp}"
TEST_ROOT_CREATED="$(mktemp -d "${TEST_TMPDIR%/}/backup-setup-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT_CREATED" && pwd -P)"
CONFIG_ROOT="$TEST_ROOT/etc/server-infra"
LOCK_ROOT="$TEST_ROOT/run/server-infra"
OUTPUT_FILE="$TEST_ROOT/setup.log"
SECOND_OUTPUT_FILE="$TEST_ROOT/setup-second.log"
SETUP="$REPOSITORY_ROOT/scripts/backup-setup.sh"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail_test() {
  printf '[backup-setup-test][error] %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  grep -F -- "$2" "$1" >/dev/null || \
    fail_test "Expected '$2' in $1"
}

file_mode() {
  case "$(uname -s)" in
    Linux)
      stat -c '%a' "$1"
      ;;
    Darwin)
      stat -f '%Lp' "$1"
      ;;
    *)
      fail_test "Unsupported test platform"
      ;;
  esac
}

if [[ "$(uname -s)" == "Linux" && "$(id -u)" != "0" ]]; then
  printf '[backup-setup-test][skip] Linux ownership checks require root\n'
  exit 0
fi

mkdir -p "$CONFIG_ROOT/backup"
cp "$REPOSITORY_ROOT/server.env.example" "$CONFIG_ROOT/server.env"
cp "$REPOSITORY_ROOT/modules.env.example" "$CONFIG_ROOT/modules.env"
printf '%s\n' "/srv/custom-data" > "$CONFIG_ROOT/backup/paths"
chmod 0600 "$CONFIG_ROOT/backup/paths"

printf '%s\n' \
  "litevi-acceptance" \
  "acceptance" \
  "Asia/Ho_Chi_Minh" \
  "s3.us-west-004.backblazeb2.com" \
  "litevi-backups" \
  "litevi-acceptance" \
  "testApplicationKeyId" \
  "testApplicationSecret" \
  "test-restic-password-with-32-chars" \
  "test-restic-password-with-32-chars" \
  "https://status.example.test/api/push/backup" \
  "https://status.example.test/api/push/check" \
  "https://status.example.test/api/push/restore" \
  "y" |
  SERVER_INFRA_BACKUP_LOCK_ROOT="$LOCK_ROOT" \
    "$SETUP" --config-root "$CONFIG_ROOT" > "$OUTPUT_FILE" 2>&1

assert_contains "$CONFIG_ROOT/server.env" \
  "SERVER_INFRA_INSTANCE=litevi-acceptance"
assert_contains "$CONFIG_ROOT/server.env" \
  "SERVER_INFRA_ENVIRONMENT=acceptance"
assert_contains "$CONFIG_ROOT/modules.env" 'ENABLED_MODULES="backup"'
assert_contains "$CONFIG_ROOT/backup/runtime.env" \
  "RESTIC_REPOSITORY=s3:https://s3.us-west-004.backblazeb2.com/litevi-backups/litevi-acceptance"
assert_contains "$CONFIG_ROOT/backup/runtime.env" \
  "AWS_DEFAULT_REGION=us-west-004"
assert_contains "$CONFIG_ROOT/backup/paths" "/srv/custom-data"
[[ "$(file_mode "$CONFIG_ROOT/server.env")" == "640" ]] || \
  fail_test "server.env mode is not 0640"
[[ "$(file_mode "$CONFIG_ROOT/backup/paths")" == "640" ]] || \
  fail_test "paths mode is not 0640"
[[ "$(file_mode "$CONFIG_ROOT/backup/runtime.env")" == "600" ]] || \
  fail_test "runtime.env mode is not 0600"
[[ "$(file_mode "$CONFIG_ROOT/backup/restic-password")" == "600" ]] || \
  fail_test "restic-password mode is not 0600"

if grep -F "testApplicationSecret" "$OUTPUT_FILE" >/dev/null; then
  fail_test "Application Key was printed"
fi
if grep -F "test-restic-password-with-32-chars" "$OUTPUT_FILE" >/dev/null; then
  fail_test "Restic password was printed"
fi

SERVER_INFRA_BACKUP_LOCK_ROOT="$LOCK_ROOT" \
  "$SETUP" --config-root "$CONFIG_ROOT" > "$SECOND_OUTPUT_FILE" 2>&1
assert_contains "$SECOND_OUTPUT_FILE" "backup configuration is already complete"

printf '[backup-setup-test][ok] setup, permissions, secrecy, and rerun passed\n'
