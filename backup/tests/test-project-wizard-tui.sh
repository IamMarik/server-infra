#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT_CREATED="$(
  mktemp -d "${TMPDIR:-/tmp}/backup-project-tui-test.XXXXXX"
)"
TEST_ROOT="$(cd "$TEST_ROOT_CREATED" && pwd -P)"
TEST_BIN="$TEST_ROOT/bin"
TEST_PROJECT_ROOT="$TEST_ROOT/project"
FAKE_PROJECT_DIALOG_LOG="$TEST_ROOT/dialog.log"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail_test() {
  printf '[backup-project-tui-test][error] %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TEST_BIN" "$TEST_PROJECT_ROOT/uploads"
ln -s \
  "$REPOSITORY_ROOT/backup/tests/fake-project-dialog" \
  "$TEST_BIN/dialog"
printf 'APP_ENV=local\n' > "$TEST_PROJECT_ROOT/.env"
printf 'APP_ENV=production\n' > "$TEST_PROJECT_ROOT/production.env"

export PATH="$TEST_BIN:$PATH"
export FAKE_PROJECT_DIALOG_LOG

# shellcheck source=../bin/server-infra-backup-project
source "$REPOSITORY_ROOT/backup/bin/server-infra-backup-project"

ACTIVE_UI="tui"
PROJECT_ROOT="$TEST_PROJECT_ROOT"
FAKE_PROJECT_DIALOG_COMPONENTS=$'files\npostgres'
export FAKE_PROJECT_DIALOG_COMPONENTS
select_backup_components_tui
[[ "$FILES_COMPONENT_SELECTED" == "1" ]] || \
  fail_test "TUI did not select project files"
[[ "$POSTGRES_COMPONENT_SELECTED" == "1" ]] || \
  fail_test "TUI did not select PostgreSQL"

detect_project_file_candidates
INCLUDE_PATHS=()
FAKE_PROJECT_DIALOG_PATHS="$TEST_PROJECT_ROOT/.env"$'\n'"$TEST_PROJECT_ROOT/production.env"$'\n'"$TEST_PROJECT_ROOT/uploads"
FAKE_PROJECT_DIALOG_INPUT=""
export FAKE_PROJECT_DIALOG_PATHS FAKE_PROJECT_DIALOG_INPUT
collect_project_files_tui
[[ " ${INCLUDE_PATHS[*]} " == *" $TEST_PROJECT_ROOT/.env "* ]] || \
  fail_test "TUI did not retain .env"
[[ " ${INCLUDE_PATHS[*]} " == *" $TEST_PROJECT_ROOT/production.env "* ]] || \
  fail_test "TUI did not retain production.env"
[[ " ${INCLUDE_PATHS[*]} " == *" $TEST_PROJECT_ROOT/uploads "* ]] || \
  fail_test "TUI did not retain uploads"

COMPOSE_ENV_FILE=""
detect_compose_env_candidates
FAKE_PROJECT_DIALOG_ENV_SELECTION="env-2"
export FAKE_PROJECT_DIALOG_ENV_SELECTION
select_compose_env_file_tui
[[ "$COMPOSE_ENV_FILE" == "$TEST_PROJECT_ROOT/production.env" ]] || \
  fail_test "TUI did not select production.env as the Compose env file"

grep -F -- "--checklist" "$FAKE_PROJECT_DIALOG_LOG" >/dev/null || \
  fail_test "TUI checklist was not opened"
grep -F -- "--radiolist" "$FAKE_PROJECT_DIALOG_LOG" >/dev/null || \
  fail_test "TUI env-file radiolist was not opened"

printf '[backup-project-tui-test][ok] component and env selection passed\n'
