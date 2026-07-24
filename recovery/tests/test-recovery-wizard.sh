#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT_CREATED="$(
  mktemp -d "${TMPDIR:-/tmp}/recovery-wizard-test.XXXXXX"
)"
TEST_ROOT="$(cd "$TEST_ROOT_CREATED" && pwd -P)"
STATE_ROOT="$TEST_ROOT/state/recovery"
CONFIG_ROOT="$TEST_ROOT/etc/server-infra"
WORK_ROOT="$TEST_ROOT/cache/recovery"
BREAK_GLASS_FILE="$TEST_ROOT/server-infra-break-glass.txt"
PROJECT_ROOT="$TEST_ROOT/projects/acceptance-app"
RECOVERY_LOG="$TEST_ROOT/recovery.log"
OUTPUT_LOG="$TEST_ROOT/output.log"
WIZARD="$REPOSITORY_ROOT/recovery/bin/server-infra-recovery-wizard"
FAKE_RECOVERY="$REPOSITORY_ROOT/recovery/tests/fake-recovery-wizard-cli"
TEST_GIT_USER="$(id -un)"

cleanup() {
  if [[ "${RECOVERY_WIZARD_TEST_KEEP:-0}" == "1" ]]; then
    printf '[recovery-wizard-test] preserved test root: %s\n' \
      "$TEST_ROOT" >&2
    return
  fi
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail_test() {
  printf '[recovery-wizard-test][error] %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  grep -F -- "$2" "$1" >/dev/null || \
    fail_test "Expected '$2' in $1"
}

mkdir -p "${PROJECT_ROOT%/*}"
printf 'test break-glass record\n' > "$BREAK_GLASS_FILE"
chmod 0600 "$BREAK_GLASS_FILE"

export SERVER_INFRA_RECOVERY_EXECUTABLE="$FAKE_RECOVERY"
export FAKE_RECOVERY_LOG="$RECOVERY_LOG"
export FAKE_RECOVERY_PROJECT_ROOT="$PROJECT_ROOT"

printf '%s\n' \
  "abcdef12" \
  "deadbeef" \
  "1" \
  "" \
  "" \
  | "$WIZARD" \
    --break-glass "$BREAK_GLASS_FILE" \
    --git-user "$TEST_GIT_USER" \
    --state-root "$STATE_ROOT" \
    --config-root "$CONFIG_ROOT" \
    --work-root "$WORK_ROOT" \
    > "$OUTPUT_LOG" 2>&1

assert_contains \
  "$OUTPUT_LOG" \
  "Infrastructure modules (deferred):"
assert_contains "$OUTPUT_LOG" "[deferred] backup"
assert_contains "$OUTPUT_LOG" "[deferred] proxy"
assert_contains "$OUTPUT_LOG" "[deferred] monitoring"
assert_contains "$OUTPUT_LOG" "Monitoring named-volume state is not protected"
assert_contains "$OUTPUT_LOG" "[ ] 1. acceptance-app"
assert_contains "$OUTPUT_LOG" "[ ] 2. static-site"
assert_contains \
  "$OUTPUT_LOG" \
  "Selected projects reached the isolated restore stage"
assert_contains \
  "$RECOVERY_LOG" \
  "restore-config --break-glass $BREAK_GLASS_FILE --snapshot abcdef12"
assert_contains \
  "$RECOVERY_LOG" \
  "select-data --break-glass $BREAK_GLASS_FILE --snapshot deadbeef"
assert_contains \
  "$RECOVERY_LOG" \
  "clone-project --break-glass $BREAK_GLASS_FILE --name acceptance-app"
assert_contains \
  "$RECOVERY_LOG" \
  "restore-project-files --break-glass $BREAK_GLASS_FILE --name acceptance-app"
assert_contains \
  "$RECOVERY_LOG" \
  "restore-project-db --break-glass $BREAK_GLASS_FILE --name acceptance-app"
assert_contains \
  "$RECOVERY_LOG" \
  "--target-db acceptance_app_recovered --jobs 4 --start-service"

if grep -F "test break-glass record" "$RECOVERY_LOG" >/dev/null; then
  fail_test "Break-glass contents leaked into the recovery command log"
fi
if grep -F -- "--name static-site" "$RECOVERY_LOG" >/dev/null; then
  fail_test "Unselected project was passed to a recovery operation"
fi

printf '[recovery-wizard-test][ok] interactive recovery flow passed\n'
