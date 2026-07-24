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
SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
JOURNALCTL_LOG="$TEST_ROOT/journalctl.log"
BACKUP_RESTORE_LOG="$TEST_ROOT/backup-restore.log"
PROJECT_RESTORE_ROOT="$TEST_ROOT/project-restores"
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
git -C "$PROJECT_ROOT" init --quiet
git -C "$PROJECT_ROOT" config user.name "Backup Test"
git -C "$PROJECT_ROOT" config user.email "backup-test@example.test"
git -C "$PROJECT_ROOT" add docker-compose.yml runtime.env
git -C "$PROJECT_ROOT" commit --quiet -m "test project"
git -C "$PROJECT_ROOT" remote add origin \
  "git@github.com:example/my-app.git"
PROJECT_DEPLOY_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"

cat > "$BIN_ROOT/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

printf '%s ' "$@" >> "$FAKE_DOCKER_LOG"
printf '\n' >> "$FAKE_DOCKER_LOG"

all_arguments="$*"
if [[ "$all_arguments" == *"SERVER_INFRA_DB_USER="* ]]; then
  printf 'SERVER_INFRA_DB_USER=test-user\n'
  printf 'SERVER_INFRA_DB_NAME=test_db\n'
  exit 0
fi
if [[ "$all_arguments" == *"SELECT 1 FROM pg_database"* ]]; then
  if [[ "${FAKE_TARGET_DB_EXISTS:-0}" == "1" ]]; then
    printf '1\n'
  fi
  exit 0
fi
if [[ "$all_arguments" == *"mktemp"* ]]; then
  printf '/tmp/server-infra-restore-my-app.A1b2C3\n'
  exit 0
fi
for argument in "$@"; do
  if [[ "$argument" == "pg_restore" ]]; then
    [[ "${FAKE_DOCKER_FAIL_RESTORE:-0}" != "1" ]] || exit 44
    if [[ "${FAKE_DOCKER_FAIL_IMPORT:-0}" == "1" && \
      "$all_arguments" == *"--dbname"* ]]; then
      exit 45
    fi
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

cat > "$BIN_ROOT/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s ' "$@" >> "$FAKE_SYSTEMCTL_LOG"
printf '\n' >> "$FAKE_SYSTEMCTL_LOG"
EOF

cat > "$BIN_ROOT/journalctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s ' "$@" >> "$FAKE_JOURNALCTL_LOG"
printf '\n' >> "$FAKE_JOURNALCTL_LOG"
EOF

cat > "$BIN_ROOT/server-infra-backup-runner" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

printf '%s ' "$@" >> "$FAKE_BACKUP_RESTORE_LOG"
printf '\n' >> "$FAKE_BACKUP_RESTORE_LOG"

target=""
while (($# > 0)); do
  if [[ "$1" == "--target" ]]; then
    target="$2"
    break
  fi
  shift
done
[[ -n "$target" ]]
mkdir -p "$target$FAKE_PROJECT_STAGING_DIR"
printf 'fake-restored-postgresql-custom-archive\n' \
  > "$target$FAKE_PROJECT_STAGING_DIR/postgres.dump"
EOF
chmod 0755 \
  "$BIN_ROOT/docker" \
  "$BIN_ROOT/restic" \
  "$BIN_ROOT/curl" \
  "$BIN_ROOT/systemctl" \
  "$BIN_ROOT/journalctl" \
  "$BIN_ROOT/server-infra-backup-runner"

export PATH="$BIN_ROOT:$PATH"
export FAKE_DOCKER_LOG="$DOCKER_LOG"
export FAKE_RESTIC_LOG="$RESTIC_LOG"
export FAKE_CURL_LOG="$CURL_LOG"
export FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG"
export FAKE_JOURNALCTL_LOG="$JOURNALCTL_LOG"
export FAKE_BACKUP_RESTORE_LOG="$BACKUP_RESTORE_LOG"
export FAKE_PROJECT_STAGING_DIR="$STAGING_ROOT/my-app"
export SERVER_INFRA_BACKUP_LOCK_ROOT="$LOCK_ROOT"
export SERVER_INFRA_BACKUP_EXECUTABLE="$BIN_ROOT/server-infra-backup-runner"
export SERVER_INFRA_BACKUP_PROJECT_RESTORE_ROOT="$PROJECT_RESTORE_ROOT"

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
if grep -F "server-infra-backup project dump" \
  "$FILES_MANIFEST_DIR/README.md" >/dev/null; then
  fail_test "files-only README unexpectedly documents a dump producer"
fi
if grep -F "server-infra-backup project restore-db" \
  "$FILES_MANIFEST_DIR/README.md" >/dev/null; then
  fail_test "files-only README unexpectedly documents database restore"
fi

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
git -C "$PROJECT_ROOT" add .server-infra/backup
git -C "$PROJECT_ROOT" commit --quiet -m "add backup manifest"
PROJECT_DEPLOY_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
(
  cd "$PROJECT_ROOT"
  "$CLI" project install \
    --config-root "$CONFIG_ROOT" \
    --check
) > "$TEST_ROOT/project-install-plan.log"
assert_contains \
  "$TEST_ROOT/project-install-plan.log" \
  "Recovery repository: git@github.com:example/my-app.git"
assert_contains \
  "$TEST_ROOT/project-install-plan.log" \
  "Recovery commit: $PROJECT_DEPLOY_COMMIT"
git -C "$PROJECT_ROOT" remote set-url origin \
  "https://embedded-token@github.com/example/my-app.git"
if (
  cd "$PROJECT_ROOT"
  "$CLI" project install \
    --config-root "$CONFIG_ROOT" \
    --check
); then
  fail_test "Project install accepted an HTTPS origin containing credentials"
fi
git -C "$PROJECT_ROOT" remote set-url origin \
  "git@github.com:example/my-app.git"
printf 'tracked change\n' > "$PROJECT_ROOT/docker-compose.yml"
if (
  cd "$PROJECT_ROOT"
  "$CLI" project install \
    --config-root "$CONFIG_ROOT" \
    --check
); then
  fail_test "Project install accepted tracked Git changes"
fi
git -C "$PROJECT_ROOT" restore docker-compose.yml

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
assert_contains \
  "$MANIFEST_DIR/README.md" \
  "sudo server-infra-backup project dump"
assert_contains \
  "$MANIFEST_DIR/README.md" \
  "sudo server-infra-backup project restore-db"

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
cat > "$CONFIG_ROOT/backup/sources.d/my-app/recovery.conf" <<EOF
RECOVERY_VERSION=1
REPOSITORY_URL=git@github.com:example/my-app.git
DEPLOY_COMMIT=$PROJECT_DEPLOY_COMMIT
EOF
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
  "$CONFIG_ROOT/backup/sources.d/my-app/freshness" \
  "$CONFIG_ROOT/backup/sources.d/my-app/recovery.conf"
chmod 0600 \
  "$CONFIG_ROOT/backup/runtime.env" \
  "$CONFIG_ROOT/backup/restic-password"

(
  cd "$PROJECT_ROOT"
  "$CLI" project dump --config-root "$CONFIG_ROOT"
  "$CLI" project status --config-root "$CONFIG_ROOT"
  "$CLI" project logs --config-root "$CONFIG_ROOT"
  "$CLI" project restore-db \
    --config-root "$CONFIG_ROOT" \
    --target-db test_restore \
    --snapshot abcdef12 \
    --jobs 3
  "$CLI" project restore-db \
    --config-root "$CONFIG_ROOT" \
    --target-db started_restore \
    --snapshot abcdef12 \
    --start-service
)
"$CLI" project status \
  --name my-app \
  --config-root "$CONFIG_ROOT"
if "$CLI" project dump \
  --name files-app \
  --config-root "$CONFIG_ROOT"; then
  fail_test "Files-only source unexpectedly accepted a dump operation"
fi
if "$CLI" project restore-db \
  --name my-app \
  --config-root "$CONFIG_ROOT" \
  --target-db test_db; then
  fail_test "Restore unexpectedly accepted the configured source database"
fi
if FAKE_TARGET_DB_EXISTS=1 \
  "$CLI" project restore-db \
    --name my-app \
    --config-root "$CONFIG_ROOT" \
    --target-db existing_restore; then
  fail_test "Restore unexpectedly accepted an existing target database"
fi
if FAKE_DOCKER_FAIL_IMPORT=1 \
  "$CLI" project restore-db \
    --name my-app \
    --config-root "$CONFIG_ROOT" \
    --target-db failed_restore; then
  fail_test "Restore unexpectedly accepted a failed pg_restore"
fi
assert_contains \
  "$SYSTEMCTL_LOG" \
  "start server-infra-backup-project-my-app.service"
assert_contains \
  "$SYSTEMCTL_LOG" \
  "status --no-pager --full server-infra-backup-project-my-app.service server-infra-backup-project-my-app.timer"
assert_contains \
  "$JOURNALCTL_LOG" \
  "--unit server-infra-backup-project-my-app.service --lines 100"
assert_contains \
  "$BACKUP_RESTORE_LOG" \
  "restore --kind data --snapshot abcdef12 --include $STAGING_ROOT/my-app/postgres.dump"
assert_contains \
  "$DOCKER_LOG" \
  "/tmp/server-infra-restore-my-app."
assert_contains \
  "$DOCKER_LOG" \
  "createdb --username test-user --maintenance-db postgres --template template0 test_restore"
assert_contains \
  "$DOCKER_LOG" \
  "up -d --no-deps postgres"
assert_contains \
  "$DOCKER_LOG" \
  "exec -T postgres pg_isready --quiet"
assert_contains \
  "$DOCKER_LOG" \
  "pg_restore --exit-on-error --no-owner --no-acl --jobs 3 --username test-user --dbname test_restore"
assert_contains \
  "$DOCKER_LOG" \
  "dropdb --username test-user --maintenance-db postgres --if-exists failed_restore"
if find "$PROJECT_RESTORE_ROOT" -mindepth 1 -print -quit | grep -q .; then
  fail_test "Database restore left temporary host data behind"
fi

LIST_OUTPUT="$TEST_ROOT/project-list.log"
RECOVERY_LIST_OUTPUT="$TEST_ROOT/project-recovery-list.log"
REMOVE_OUTPUT="$TEST_ROOT/project-remove.log"
"$CLI" project list --config-root "$CONFIG_ROOT" > "$LIST_OUTPUT"
"$CLI" project recovery-list \
  --config-root "$CONFIG_ROOT" > "$RECOVERY_LIST_OUTPUT"
"$CLI" project remove \
  --name my-app \
  --config-root "$CONFIG_ROOT" \
  --check > "$REMOVE_OUTPUT"
assert_contains "$LIST_OUTPUT" $'my-app\tpostgres-compose\t02:45'
assert_contains "$LIST_OUTPUT" $'files-app\tfiles-only\t-'
assert_contains \
  "$RECOVERY_LIST_OUTPUT" \
  $'NAME\tTYPE\tPROJECT_ROOT\tREPOSITORY_URL\tDEPLOY_COMMIT'
assert_contains \
  "$RECOVERY_LIST_OUTPUT" \
  $'files-app\tfiles-only\t'"$FILES_PROJECT_ROOT"$'\tMISSING\tMISSING'
assert_contains \
  "$RECOVERY_LIST_OUTPUT" \
  $'my-app\tpostgres-compose\t'"$PROJECT_ROOT"$'\tgit@github.com:example/my-app.git\t'"$PROJECT_DEPLOY_COMMIT"
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
