#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_TMPDIR="${TMPDIR:-/tmp}"
TEST_ROOT_CREATED="$(mktemp -d "${TEST_TMPDIR%/}/server-infra-backup-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT_CREATED" && pwd -P)"
CONFIG_ROOT="$TEST_ROOT/etc/server-infra"
BIN_ROOT="$TEST_ROOT/bin"
LOCK_ROOT="$TEST_ROOT/run/server-infra"
CACHE_ROOT="$TEST_ROOT/cache/restic"
RESTORE_TEST_ROOT="$TEST_ROOT/cache/restore-tests"
RESTIC_LOG="$TEST_ROOT/restic.log"
CURL_LOG="$TEST_ROOT/curl.log"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail_test() {
  printf '[backup-test][error] %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file_path="$1"
  local expected="$2"

  grep -F -- "$expected" "$file_path" >/dev/null || \
    fail_test "Expected '$expected' in $file_path"
}

write_runtime() {
  local backup_push_url="$1"
  local check_push_url="$2"
  local restore_push_url="$3"

  cat > "$CONFIG_ROOT/backup/runtime.env" <<EOF
RESTIC_REPOSITORY=s3:https://s3.example.test/test-bucket
RESTIC_PASSWORD_FILE=$CONFIG_ROOT/backup/restic-password
AWS_ACCESS_KEY_ID=test-key
AWS_SECRET_ACCESS_KEY=test-secret
AWS_DEFAULT_REGION=test-region
UPTIME_KUMA_BACKUP_PUSH_URL=$backup_push_url
UPTIME_KUMA_CHECK_PUSH_URL=$check_push_url
UPTIME_KUMA_RESTORE_TEST_PUSH_URL=$restore_push_url
BACKUP_KEEP_DAILY=14
BACKUP_KEEP_WEEKLY=8
BACKUP_KEEP_MONTHLY=12
BACKUP_RETENTION_ENABLED=false
BACKUP_PRUNE_ENABLED=false
EOF
  chmod 0600 "$CONFIG_ROOT/backup/runtime.env"
}

if [[ "$(uname -s)" == "Linux" && "$(id -u)" != "0" ]]; then
  printf '[backup-test][skip] Linux permission checks require root\n'
  exit 0
fi

mkdir -p "$CONFIG_ROOT/backup" "$BIN_ROOT" "$LOCK_ROOT" "$TEST_ROOT/data"

cat > "$CONFIG_ROOT/server.env" <<'EOF'
SERVER_INFRA_CONFIG_VERSION=1
SERVER_INFRA_INSTANCE=test-server
SERVER_INFRA_ENVIRONMENT=test
SERVER_INFRA_TIMEZONE=Etc/UTC
EOF
cat > "$CONFIG_ROOT/modules.env" <<'EOF'
ENABLED_MODULES=backup
EOF
write_runtime "" "" ""
cat > "$CONFIG_ROOT/backup/paths" <<EOF
$TEST_ROOT/data
EOF
: > "$CONFIG_ROOT/backup/excludes"
: > "$CONFIG_ROOT/backup/freshness"
printf 'test-password\n' > "$CONFIG_ROOT/backup/restic-password"

chmod 0750 "$CONFIG_ROOT" "$CONFIG_ROOT/backup"
chmod 0640 \
  "$CONFIG_ROOT/server.env" \
  "$CONFIG_ROOT/modules.env" \
  "$CONFIG_ROOT/backup/paths" \
  "$CONFIG_ROOT/backup/excludes" \
  "$CONFIG_ROOT/backup/freshness"
chmod 0600 \
  "$CONFIG_ROOT/backup/runtime.env" \
  "$CONFIG_ROOT/backup/restic-password"

cat > "$BIN_ROOT/restic" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

printf '%s ' "$@" >> "$FAKE_RESTIC_LOG"
printf '\n' >> "$FAKE_RESTIC_LOG"

if [[ "${1:-}" == "check" && "${FAKE_RESTIC_FAIL_CHECK:-0}" == "1" ]]; then
  exit 42
fi

if [[ "${1:-}" == "restore" ]]; then
  target=""
  while (($# > 0)); do
    if [[ "$1" == "--target" ]]; then
      target="$2"
      break
    fi
    shift
  done
  [[ -n "$target" ]]
  restored_root="$target$FAKE_CONFIG_ROOT"
  mkdir -p "$restored_root/backup"
  printf 'SERVER_INFRA_INSTANCE=test-server\n' > "$restored_root/server.env"
  printf 'ENABLED_MODULES=backup\n' > "$restored_root/modules.env"
  printf 'RESTIC_REPOSITORY=test\n' > "$restored_root/backup/runtime.env"
  if [[ "${FAKE_RESTORE_INVALID:-0}" != "1" ]]; then
    printf 'test-password\n' > "$restored_root/backup/restic-password"
  fi
  printf '/test/data\n' > "$restored_root/backup/paths"
  : > "$restored_root/backup/excludes"
  : > "$restored_root/backup/freshness"
  chmod 0750 "$restored_root" "$restored_root/backup"
  chmod 0640 \
    "$restored_root/server.env" \
    "$restored_root/modules.env" \
    "$restored_root/backup/paths" \
    "$restored_root/backup/excludes" \
    "$restored_root/backup/freshness"
  chmod 0600 "$restored_root/backup/runtime.env"
  if [[ -f "$restored_root/backup/restic-password" ]]; then
    chmod 0600 "$restored_root/backup/restic-password"
  fi
fi
EOF

cat > "$BIN_ROOT/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s ' "$@" >> "$FAKE_CURL_LOG"
printf '\n' >> "$FAKE_CURL_LOG"
EOF
chmod 0755 "$BIN_ROOT/restic" "$BIN_ROOT/curl"

export PATH="$BIN_ROOT:$PATH"
export FAKE_CONFIG_ROOT="$CONFIG_ROOT"
export FAKE_RESTIC_LOG="$RESTIC_LOG"
export FAKE_CURL_LOG="$CURL_LOG"
export SERVER_INFRA_BACKUP_CACHE_DIR="$CACHE_ROOT"
export SERVER_INFRA_BACKUP_LOCK_ROOT="$LOCK_ROOT"
export SERVER_INFRA_BACKUP_RESTORE_TEST_ROOT="$RESTORE_TEST_ROOT"

RUNNER="$REPOSITORY_ROOT/backup/bin/server-infra-backup"

"$REPOSITORY_ROOT/scripts/validate-config.sh" --config-root "$CONFIG_ROOT"
"$REPOSITORY_ROOT/scripts/deploy.sh" --config-root "$CONFIG_ROOT" --check
"$RUNNER" --config-root "$CONFIG_ROOT" validate
: > "$CURL_LOG"
"$RUNNER" --config-root "$CONFIG_ROOT" status
assert_contains \
  "$RESTIC_LOG" \
  "snapshots --host test-server --tag server-infra-config --latest 1"
assert_contains \
  "$RESTIC_LOG" \
  "snapshots --host test-server --tag server-infra-data --latest 1"
"$RUNNER" --config-root "$CONFIG_ROOT" check
assert_contains "$RESTIC_LOG" "check "
if [[ -s "$CURL_LOG" ]]; then
  fail_test "Disabled monitoring unexpectedly invoked curl"
fi

write_runtime "https://status.example.test/api/push/backup-monitor" "" ""
if "$RUNNER" --config-root "$CONFIG_ROOT" validate; then
  fail_test "Runner unexpectedly accepted partially configured monitoring"
fi

write_runtime \
  "https://status.example.test/api/push/backup-monitor" \
  "https://status.example.test/api/push/check-monitor" \
  "https://status.example.test/api/push/restore-monitor"
"$RUNNER" --config-root "$CONFIG_ROOT" validate
"$RUNNER" --config-root "$CONFIG_ROOT" check
assert_contains "$CURL_LOG" "https://status.example.test/api/push/check-monitor"
assert_contains "$CURL_LOG" "status=up"

MANUAL_TARGET="$TEST_ROOT/manual-restore"
"$REPOSITORY_ROOT/scripts/restore.sh" \
  --config-root "$CONFIG_ROOT" \
  --kind config \
  --target "$MANUAL_TARGET"
[[ -d "$MANUAL_TARGET$CONFIG_ROOT/backup" ]] || \
  fail_test "Manual restore did not create the expected configuration tree"
assert_contains \
  "$RESTIC_LOG" \
  "restore latest --host test-server --tag server-infra-config --target $MANUAL_TARGET"

FILTERED_TARGET="$TEST_ROOT/filtered-restore"
"$RUNNER" \
  --config-root "$CONFIG_ROOT" \
  restore \
  --kind data \
  --snapshot abcdef12 \
  --include "$TEST_ROOT/data/postgres.dump" \
  --target "$FILTERED_TARGET"
assert_contains \
  "$RESTIC_LOG" \
  "restore abcdef12 --host test-server --tag server-infra-data --target $FILTERED_TARGET --include $TEST_ROOT/data/postgres.dump"

if "$RUNNER" \
  --config-root "$CONFIG_ROOT" \
  restore \
  --kind data \
  --include "$TEST_ROOT/outside/postgres.dump" \
  --target "$TEST_ROOT/outside-restore"; then
  fail_test "Restore unexpectedly accepted an include outside configured data"
fi

NONEMPTY_TARGET="$TEST_ROOT/nonempty"
mkdir "$NONEMPTY_TARGET"
: > "$NONEMPTY_TARGET/existing"
if "$RUNNER" \
  --config-root "$CONFIG_ROOT" \
  restore \
  --kind config \
  --target "$NONEMPTY_TARGET"; then
  fail_test "Restore unexpectedly accepted a non-empty destination"
fi

if "$RUNNER" \
  --config-root "$CONFIG_ROOT" \
  restore \
  --kind data \
  --target "$TEST_ROOT/data"; then
  fail_test "Restore unexpectedly accepted a configured data path"
fi

mkdir "$TEST_ROOT/real-parent"
ln -s "$TEST_ROOT/real-parent" "$TEST_ROOT/symlink-parent"
if "$RUNNER" \
  --config-root "$CONFIG_ROOT" \
  restore \
  --kind config \
  --target "$TEST_ROOT/symlink-parent/restore"; then
  fail_test "Restore unexpectedly accepted a symlinked path component"
fi

"$RUNNER" --config-root "$CONFIG_ROOT" restore-test
assert_contains "$CURL_LOG" "https://status.example.test/api/push/restore-monitor"
if find "$RESTORE_TEST_ROOT" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  fail_test "Restore test left temporary data behind"
fi

if FAKE_RESTORE_INVALID=1 \
  "$RUNNER" --config-root "$CONFIG_ROOT" restore-test; then
  fail_test "Restore test unexpectedly accepted an incomplete restore"
fi
if find "$RESTORE_TEST_ROOT" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  fail_test "Failed restore test left temporary data behind"
fi
assert_contains "$CURL_LOG" "Restore test failed on test-server"

if FAKE_RESTIC_FAIL_CHECK=1 \
  "$RUNNER" --config-root "$CONFIG_ROOT" check; then
  fail_test "Repository check unexpectedly succeeded"
fi
assert_contains "$CURL_LOG" "status=down"
assert_contains "$CURL_LOG" "Repository check failed on test-server"

printf '[backup-test][ok] optional monitoring, safety, and lifecycle checks passed\n'
