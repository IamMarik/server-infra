#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_TMPDIR="${TMPDIR:-/tmp}"
TEST_ROOT_CREATED="$(mktemp -d "${TEST_TMPDIR%/}/backup-project-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT_CREATED" && pwd -P)"
PROJECT_ROOT="$TEST_ROOT/my-app"
MANIFEST_DIR="$PROJECT_ROOT/.server-infra/backup"
STAGING_ROOT="$TEST_ROOT/state/staging"
LOCK_ROOT="$TEST_ROOT/run/server-infra"
BIN_ROOT="$TEST_ROOT/bin"
DOCKER_LOG="$TEST_ROOT/docker.log"
RESTIC_LOG="$TEST_ROOT/restic.log"
CURL_LOG="$TEST_ROOT/curl.log"
CONFIG_ROOT="$TEST_ROOT/etc/server-infra"
FILES_PROJECT_ROOT="$TEST_ROOT/files-app"
FILES_MANIFEST_DIR="$FILES_PROJECT_ROOT/.server-infra/backup"
FILES_RESTORE_ROOT="$TEST_ROOT/files-restore"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail_test() {
  printf '[backup-project-test][error] %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file_path="$1"
  local expected="$2"

  grep -F -- "$expected" "$file_path" >/dev/null || \
    fail_test "Expected '$expected' in $file_path"
}

mkdir -p \
  "$PROJECT_ROOT/uploads" \
  "$PROJECT_ROOT/config" \
  "$LOCK_ROOT" \
  "$BIN_ROOT"
: > "$PROJECT_ROOT/docker-compose.yml"
: > "$PROJECT_ROOT/runtime.env"

cat > "$BIN_ROOT/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

printf '%s ' "$@" >> "$FAKE_DOCKER_LOG"
printf '\n' >> "$FAKE_DOCKER_LOG"

for argument in "$@"; do
  if [[ "$argument" == "pg_restore" ]]; then
    cat >/dev/null
    [[ "${FAKE_DOCKER_FAIL_RESTORE:-0}" != "1" ]] || exit 44
    exit 0
  fi
done

printf 'fake-postgresql-custom-archive\n'
EOF

cat > "$BIN_ROOT/restic" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s ' "$@" >> "$FAKE_RESTIC_LOG"
printf '\n' >> "$FAKE_RESTIC_LOG"
EOF

cat > "$BIN_ROOT/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s ' "$@" >> "$FAKE_CURL_LOG"
printf '\n' >> "$FAKE_CURL_LOG"
EOF
chmod 0755 "$BIN_ROOT/docker" "$BIN_ROOT/restic" "$BIN_ROOT/curl"

export PATH="$BIN_ROOT:$PATH"
export FAKE_DOCKER_LOG="$DOCKER_LOG"
export FAKE_RESTIC_LOG="$RESTIC_LOG"
export FAKE_CURL_LOG="$CURL_LOG"
export SERVER_INFRA_BACKUP_LOCK_ROOT="$LOCK_ROOT"

CLI="$REPOSITORY_ROOT/backup/bin/server-infra-backup"
INTERNAL_HELPER="$REPOSITORY_ROOT/backup/bin/server-infra-backup-project"
COMPATIBILITY_WRAPPER="$REPOSITORY_ROOT/scripts/backup-project.sh"

mkdir -p \
  "$FILES_PROJECT_ROOT/config" \
  "$FILES_PROJECT_ROOT/uploads"
"$COMPATIBILITY_WRAPPER" init \
  --files-only \
  --non-interactive \
  --project-root "$FILES_PROJECT_ROOT" \
  --name files-app \
  --include "$FILES_PROJECT_ROOT/config" \
  --include "$FILES_PROJECT_ROOT/uploads"

(
  cd "$FILES_PROJECT_ROOT"
  "$CLI" project validate
  env PATH="/usr/bin:/bin" \
    "$CLI" project install \
      --config-root "$CONFIG_ROOT" \
      --check
)
assert_contains "$FILES_MANIFEST_DIR/source.conf" "SOURCE_TYPE=files-only"
if grep -F "COMPOSE_FILE=" "$FILES_MANIFEST_DIR/source.conf" >/dev/null; then
  fail_test "files-only manifest unexpectedly contains Compose configuration"
fi
[[ -x "$FILES_MANIFEST_DIR/restore-check.sh" ]] || \
  fail_test "files-only restore-check.sh is not executable"
[[ -f "$FILES_MANIFEST_DIR/README.md" ]] || \
  fail_test "files-only README.md was not created"

mkdir -p \
  "$FILES_RESTORE_ROOT$FILES_PROJECT_ROOT/config" \
  "$FILES_RESTORE_ROOT$FILES_PROJECT_ROOT/uploads"
"$FILES_MANIFEST_DIR/restore-check.sh" "$FILES_RESTORE_ROOT"

"$CLI" project init \
  --non-interactive \
  --project-root "$PROJECT_ROOT" \
  --name my-app \
  --include "$PROJECT_ROOT/config" \
  --include "$PROJECT_ROOT/uploads" \
  --compose-file "$PROJECT_ROOT/docker-compose.yml" \
  --compose-service postgres \
  --compose-env-file "$PROJECT_ROOT/runtime.env" \
  --dump-time 02:45 \
  --max-age-seconds 14400 \
  --staging-root "$STAGING_ROOT"

(
  cd "$PROJECT_ROOT"
  "$CLI" project validate
)
rm -f -- \
  "$MANIFEST_DIR/restore-check.sh" \
  "$MANIFEST_DIR/README.md"
"$CLI" project init \
  --non-interactive \
  --project-root "$PROJECT_ROOT" \
  --name my-app \
  --manifest "$MANIFEST_DIR"
[[ -x "$MANIFEST_DIR/restore-check.sh" ]] || \
  fail_test "Existing manifest did not receive restore-check.sh"
[[ -f "$MANIFEST_DIR/README.md" ]] || \
  fail_test "Existing manifest did not receive README.md"
(
  cd "$PROJECT_ROOT"
  "$CLI" project install \
    --config-root "$CONFIG_ROOT" \
    --check
)

INTERACTIVE_ROOT="$TEST_ROOT/interactive-app"
INTERACTIVE_MANIFEST="$INTERACTIVE_ROOT/.server-infra/backup"
mkdir -p "$INTERACTIVE_ROOT/uploads"
: > "$INTERACTIVE_ROOT/docker-compose.yml"
printf 'interactive-app\n%s\n\n\n\n\n\n' "$INTERACTIVE_ROOT/uploads" | \
  "$CLI" project init \
    --project-root "$INTERACTIVE_ROOT" \
    --staging-root "$STAGING_ROOT"
assert_contains \
  "$INTERACTIVE_MANIFEST/source.conf" \
  "SOURCE_NAME=interactive-app"

assert_contains "$MANIFEST_DIR/source.conf" "SOURCE_TYPE=postgres-compose"
assert_contains \
  "$MANIFEST_DIR/restore-check.sh" \
  'PROJECT_DUMP_PATH="${source_line#STAGING_DIR=}/postgres.dump"'
assert_contains "$MANIFEST_DIR/paths" "$PROJECT_ROOT/runtime.env"
assert_contains "$MANIFEST_DIR/paths" "$PROJECT_ROOT/uploads"
assert_contains "$MANIFEST_DIR/paths" "$STAGING_ROOT/my-app"
assert_contains \
  "$MANIFEST_DIR/freshness" \
  "14400 $STAGING_ROOT/my-app/postgres.complete"

"$INTERNAL_HELPER" dump --source-config "$MANIFEST_DIR/source.conf"
[[ -s "$STAGING_ROOT/my-app/postgres.dump" ]] || \
  fail_test "PostgreSQL dump was not published"
[[ -s "$STAGING_ROOT/my-app/postgres.complete" ]] || \
  fail_test "Freshness marker was not published"
assert_contains "$DOCKER_LOG" "--env-file $PROJECT_ROOT/runtime.env"
assert_contains "$DOCKER_LOG" "exec -T postgres"
assert_contains "$DOCKER_LOG" "pg_restore --list"

POSTGRES_RESTORE_ROOT="$TEST_ROOT/postgres-restore"
mkdir -p \
  "$POSTGRES_RESTORE_ROOT$PROJECT_ROOT/config" \
  "$POSTGRES_RESTORE_ROOT$PROJECT_ROOT/uploads" \
  "$POSTGRES_RESTORE_ROOT$STAGING_ROOT/my-app"
cp \
  "$STAGING_ROOT/my-app/postgres.dump" \
  "$POSTGRES_RESTORE_ROOT$STAGING_ROOT/my-app/postgres.dump"
cp \
  "$PROJECT_ROOT/runtime.env" \
  "$POSTGRES_RESTORE_ROOT$PROJECT_ROOT/runtime.env"
"$MANIFEST_DIR/restore-check.sh" "$POSTGRES_RESTORE_ROOT"

if FAKE_DOCKER_FAIL_RESTORE=1 \
  "$INTERNAL_HELPER" dump --source-config "$MANIFEST_DIR/source.conf"; then
  fail_test "Invalid PostgreSQL archive unexpectedly passed validation"
fi
[[ ! -e "$STAGING_ROOT/my-app/postgres.complete" ]] || \
  fail_test "Failed dump left a fresh marker"
if find "$STAGING_ROOT/my-app" -name '*.partial.*' -print -quit | grep -q .; then
  fail_test "Failed dump left temporary files"
fi

"$INTERNAL_HELPER" dump --source-config "$MANIFEST_DIR/source.conf"

mkdir -p \
  "$CONFIG_ROOT/backup/sources.d/files-app" \
  "$CONFIG_ROOT/backup/sources.d/my-app" \
  "$TEST_ROOT/base-data"
cat > "$CONFIG_ROOT/server.env" <<'EOF'
SERVER_INFRA_CONFIG_VERSION=1
SERVER_INFRA_INSTANCE=test-server
SERVER_INFRA_ENVIRONMENT=test
SERVER_INFRA_TIMEZONE=Etc/UTC
EOF
cat > "$CONFIG_ROOT/modules.env" <<'EOF'
ENABLED_MODULES=backup
EOF
cat > "$CONFIG_ROOT/backup/runtime.env" <<EOF
RESTIC_REPOSITORY=s3:https://s3.example.test/test-bucket
RESTIC_PASSWORD_FILE=$CONFIG_ROOT/backup/restic-password
AWS_ACCESS_KEY_ID=test-key
AWS_SECRET_ACCESS_KEY=test-secret
AWS_DEFAULT_REGION=test-region
UPTIME_KUMA_BACKUP_PUSH_URL=https://status.example.test/api/push/backup-monitor
UPTIME_KUMA_CHECK_PUSH_URL=https://status.example.test/api/push/check-monitor
UPTIME_KUMA_RESTORE_TEST_PUSH_URL=https://status.example.test/api/push/restore-monitor
BACKUP_KEEP_DAILY=14
BACKUP_KEEP_WEEKLY=8
BACKUP_KEEP_MONTHLY=12
BACKUP_RETENTION_ENABLED=false
BACKUP_PRUNE_ENABLED=false
EOF
printf '%s\n' "$TEST_ROOT/base-data" > "$CONFIG_ROOT/backup/paths"
: > "$CONFIG_ROOT/backup/excludes"
: > "$CONFIG_ROOT/backup/freshness"
printf 'test-password\n' > "$CONFIG_ROOT/backup/restic-password"
cp "$MANIFEST_DIR/source.conf" "$CONFIG_ROOT/backup/sources.d/my-app/source.conf"
cp "$MANIFEST_DIR/paths" "$CONFIG_ROOT/backup/sources.d/my-app/paths"
cp "$MANIFEST_DIR/excludes" "$CONFIG_ROOT/backup/sources.d/my-app/excludes"
cp "$MANIFEST_DIR/freshness" "$CONFIG_ROOT/backup/sources.d/my-app/freshness"
cp "$FILES_MANIFEST_DIR/source.conf" \
  "$CONFIG_ROOT/backup/sources.d/files-app/source.conf"
cp "$FILES_MANIFEST_DIR/paths" \
  "$CONFIG_ROOT/backup/sources.d/files-app/paths"
cp "$FILES_MANIFEST_DIR/excludes" \
  "$CONFIG_ROOT/backup/sources.d/files-app/excludes"
cp "$FILES_MANIFEST_DIR/freshness" \
  "$CONFIG_ROOT/backup/sources.d/files-app/freshness"

chmod 0750 \
  "$CONFIG_ROOT" \
  "$CONFIG_ROOT/backup" \
  "$CONFIG_ROOT/backup/sources.d" \
  "$CONFIG_ROOT/backup/sources.d/files-app" \
  "$CONFIG_ROOT/backup/sources.d/my-app"
chmod 0640 \
  "$CONFIG_ROOT/server.env" \
  "$CONFIG_ROOT/modules.env" \
  "$CONFIG_ROOT/backup/paths" \
  "$CONFIG_ROOT/backup/excludes" \
  "$CONFIG_ROOT/backup/freshness" \
  "$CONFIG_ROOT/backup/sources.d/files-app/source.conf" \
  "$CONFIG_ROOT/backup/sources.d/files-app/paths" \
  "$CONFIG_ROOT/backup/sources.d/files-app/excludes" \
  "$CONFIG_ROOT/backup/sources.d/files-app/freshness" \
  "$CONFIG_ROOT/backup/sources.d/my-app/source.conf" \
  "$CONFIG_ROOT/backup/sources.d/my-app/paths" \
  "$CONFIG_ROOT/backup/sources.d/my-app/excludes" \
  "$CONFIG_ROOT/backup/sources.d/my-app/freshness"
chmod 0600 \
  "$CONFIG_ROOT/backup/runtime.env" \
  "$CONFIG_ROOT/backup/restic-password"

LIST_OUTPUT="$TEST_ROOT/project-list.log"
REMOVE_OUTPUT="$TEST_ROOT/project-remove.log"
"$CLI" project list --config-root "$CONFIG_ROOT" > "$LIST_OUTPUT"
"$CLI" project remove \
  --name my-app \
  --config-root "$CONFIG_ROOT" \
  --check > "$REMOVE_OUTPUT"
assert_contains "$LIST_OUTPUT" $'my-app\tpostgres-compose\t02:45'
assert_contains "$LIST_OUTPUT" $'files-app\tfiles-only\t-'
assert_contains "$REMOVE_OUTPUT" "Staging data will be kept"
[[ -d "$CONFIG_ROOT/backup/sources.d/my-app" ]] || \
  fail_test "Removal check changed the active source"

if [[ "$(uname -s)" == "Linux" && "$(id -u)" != "0" ]]; then
  printf '[backup-project-test][skip] runner ownership check requires root\n'
  printf '[backup-project-test][ok] wizard and PostgreSQL dump checks passed\n'
  exit 0
fi

export SERVER_INFRA_BACKUP_CACHE_DIR="$TEST_ROOT/cache/restic"
export SERVER_INFRA_BACKUP_RESTORE_TEST_ROOT="$TEST_ROOT/cache/restore-tests"

"$REPOSITORY_ROOT/scripts/deploy.sh" --config-root "$CONFIG_ROOT" --check
"$CLI" --config-root "$CONFIG_ROOT" validate
"$CLI" --config-root "$CONFIG_ROOT" run

assert_contains "$RESTIC_LOG" "$TEST_ROOT/base-data"
assert_contains "$RESTIC_LOG" "$FILES_PROJECT_ROOT/config"
assert_contains "$RESTIC_LOG" "$FILES_PROJECT_ROOT/uploads"
assert_contains "$RESTIC_LOG" "$PROJECT_ROOT/config"
assert_contains "$RESTIC_LOG" "$PROJECT_ROOT/uploads"
assert_contains "$RESTIC_LOG" "$STAGING_ROOT/my-app"
assert_contains \
  "$RESTIC_LOG" \
  "--exclude-file $CONFIG_ROOT/backup/sources.d/my-app/excludes"

printf '[backup-project-test][ok] wizard, dump, and source aggregation passed\n'
