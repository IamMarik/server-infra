#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_TMPDIR="${TMPDIR:-/tmp}"
TEST_ROOT_CREATED="$(mktemp -d "${TEST_TMPDIR%/}/break-glass-export-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT_CREATED" && pwd -P)"
CONFIG_ROOT="$TEST_ROOT/config/server-infra"
OUTPUT_DIR="$TEST_ROOT/secure-media"
OUTPUT_FILE="$OUTPUT_DIR/server-infra-break-glass.txt"
CREDENTIAL_OUTPUT_DIR="$TEST_ROOT/credential-test"
CREDENTIAL_OUTPUT_FILE="$CREDENTIAL_OUTPUT_DIR/server-infra-break-glass.txt"
COMMAND_OUTPUT="$TEST_ROOT/command.log"
EXPORTER="$REPOSITORY_ROOT/scripts/export-break-glass.sh"
TEST_BIN="$TEST_ROOT/bin"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail_test() {
  printf '[break-glass-export-test][error] %s\n' "$*" >&2
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
  printf '[break-glass-export-test][skip] Linux ownership validation requires root\n'
  exit 0
fi

mkdir -p \
  "$CONFIG_ROOT/backup" \
  "$OUTPUT_DIR" \
  "$CREDENTIAL_OUTPUT_DIR" \
  "$TEST_BIN"
chmod 0750 "$CONFIG_ROOT" "$CONFIG_ROOT/backup"

printf '%s\n' \
  "SERVER_INFRA_CONFIG_VERSION=1" \
  "SERVER_INFRA_INSTANCE=acceptance" \
  "SERVER_INFRA_ENVIRONMENT=acceptance" \
  "SERVER_INFRA_TIMEZONE=Etc/UTC" \
  > "$CONFIG_ROOT/server.env"
printf '%s\n' \
  "RESTIC_REPOSITORY=s3:https://s3.example.test/test-bucket/acceptance" \
  "RESTIC_PASSWORD_FILE=$CONFIG_ROOT/backup/restic-password" \
  "AWS_ACCESS_KEY_ID=test-key-id" \
  "AWS_SECRET_ACCESS_KEY=test-secret-key" \
  "AWS_DEFAULT_REGION=us-west-004" \
  "UPTIME_KUMA_BACKUP_PUSH_URL=" \
  "UPTIME_KUMA_CHECK_PUSH_URL=" \
  "UPTIME_KUMA_RESTORE_TEST_PUSH_URL=" \
  "BACKUP_KEEP_DAILY=14" \
  "BACKUP_KEEP_WEEKLY=8" \
  "BACKUP_KEEP_MONTHLY=12" \
  "BACKUP_RETENTION_ENABLED=false" \
  "BACKUP_PRUNE_ENABLED=false" \
  > "$CONFIG_ROOT/backup/runtime.env"
printf '%s\n' "/srv/test-data" > "$CONFIG_ROOT/backup/paths"
: > "$CONFIG_ROOT/backup/excludes"
: > "$CONFIG_ROOT/backup/freshness"
printf '%s\n' "test-restic-password" > "$CONFIG_ROOT/backup/restic-password"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'case "$*" in' \
  '  *"remote get-url origin")' \
  '    printf "%s\n" "${TEST_GIT_ORIGIN:-git@github.com:example/server-infra.git}"' \
  '    ;;' \
  '  *"rev-parse HEAD")' \
  '    printf "%s\n" "0123456789abcdef0123456789abcdef01234567"' \
  '    ;;' \
  '  *"status --porcelain --untracked-files=no")' \
  '    ;;' \
  '  *)' \
  '    exit 1' \
  '    ;;' \
  'esac' \
  > "$TEST_BIN/git"
chmod 0755 "$TEST_BIN/git"
chmod 0640 \
  "$CONFIG_ROOT/server.env" \
  "$CONFIG_ROOT/backup/paths" \
  "$CONFIG_ROOT/backup/excludes" \
  "$CONFIG_ROOT/backup/freshness"
chmod 0600 \
  "$CONFIG_ROOT/backup/runtime.env" \
  "$CONFIG_ROOT/backup/restic-password"

PATH="$TEST_BIN:$PATH" "$EXPORTER" \
  --config-root "$CONFIG_ROOT" \
  --output "$OUTPUT_FILE" > "$COMMAND_OUTPUT" 2>&1

[[ -f "$OUTPUT_FILE" ]] || fail_test "Exporter did not create the record"
[[ "$(file_mode "$OUTPUT_FILE")" == "600" ]] || \
  fail_test "Break-glass record mode is not 0600"
assert_contains "$OUTPUT_FILE" "SERVER_INFRA_INSTANCE: acceptance"
assert_contains "$OUTPUT_FILE" \
  "RESTIC_REPOSITORY: s3:https://s3.example.test/test-bucket/acceptance"
assert_contains "$OUTPUT_FILE" "RESTIC_PASSWORD: test-restic-password"
assert_contains "$OUTPUT_FILE" "AWS_ACCESS_KEY_ID: test-key-id"
assert_contains "$OUTPUT_FILE" "AWS_SECRET_ACCESS_KEY: test-secret-key"
assert_contains "$OUTPUT_FILE" \
  "SERVER_INFRA_REPOSITORY_URL: git@github.com:example/server-infra.git"
assert_contains "$OUTPUT_FILE" "SERVER_INFRA_REPOSITORY_REF:"
assert_contains "$OUTPUT_FILE" "Date: not-recorded"

if grep -F "test-secret-key" "$COMMAND_OUTPUT" >/dev/null; then
  fail_test "AWS secret was printed"
fi
if grep -F "test-restic-password" "$COMMAND_OUTPUT" >/dev/null; then
  fail_test "Restic password was printed"
fi

if PATH="$TEST_BIN:$PATH" "$EXPORTER" \
  --config-root "$CONFIG_ROOT" \
  --output "$OUTPUT_FILE" >/dev/null 2>&1; then
  fail_test "Exporter overwrote an existing record"
fi

if TEST_GIT_ORIGIN="https://token@github.com/example/server-infra.git" \
  PATH="$TEST_BIN:$PATH" "$EXPORTER" \
  --config-root "$CONFIG_ROOT" \
  --output "$CREDENTIAL_OUTPUT_FILE" >/dev/null 2>&1; then
  fail_test "Exporter accepted a Git URL containing credentials"
fi
[[ ! -e "$CREDENTIAL_OUTPUT_FILE" ]] || \
  fail_test "Exporter created a record for an unsafe Git URL"

printf '[break-glass-export-test][ok] secure export and no-overwrite guard passed\n'
