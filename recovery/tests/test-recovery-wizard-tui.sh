#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT_CREATED="$(
  mktemp -d "${TMPDIR:-/tmp}/recovery-wizard-tui-test.XXXXXX"
)"
TEST_ROOT="$(cd "$TEST_ROOT_CREATED" && pwd -P)"
TEST_BIN="$TEST_ROOT/bin"
FAKE_DIALOG_LOG="$TEST_ROOT/dialog.log"
TEST_STATE_ROOT="$TEST_ROOT/state"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail_test() {
  printf '[recovery-wizard-tui-test][error] %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TEST_BIN" "$TEST_STATE_ROOT"
ln -s "$REPOSITORY_ROOT/recovery/tests/fake-dialog" "$TEST_BIN/dialog"
export PATH="$TEST_BIN:$PATH"
export FAKE_DIALOG_LOG

# shellcheck source=../bin/server-infra-recovery-wizard
source "$REPOSITORY_ROOT/recovery/bin/server-infra-recovery-wizard"

ACTIVE_UI="tui"
STATE_ROOT="$TEST_STATE_ROOT"
SNAPSHOT_IDS=("abcdef12" "11111111")
SNAPSHOT_TIMES=("2026-07-24 20:00:00" "2026-07-24 19:00:00")
SNAPSHOT_PATHS=("/srv/current" "/srv/old")
FAKE_DIALOG_SNAPSHOT="abcdef12"
export FAKE_DIALOG_SNAPSHOT
choose_snapshot_tui "data"
[[ "$SELECTED_SNAPSHOT" == "abcdef12" ]] || \
  fail_test "TUI did not return the selected newest snapshot"

PROJECT_NAMES=("completed-app" "pending-app")
PROJECT_TYPES=("postgres-compose" "files-only")
PROJECT_CHECKOUT_STATES=("present" "absent")
PROJECT_FILE_STATES=("complete" "not-started")
PROJECT_DATABASE_STATES=("complete" "not-applicable")
PROJECT_SELECTED=(0 1)
PROJECT_SELECTABLE=(0 1)
FAKE_DIALOG_PROJECTS="pending-app"
export FAKE_DIALOG_PROJECTS
select_projects_tui
[[ "${PROJECT_SELECTED[0]}" == "0" ]] || \
  fail_test "TUI selected an already completed project"
[[ "${PROJECT_SELECTED[1]}" == "1" ]] || \
  fail_test "TUI did not retain the incomplete project selection"

printf '%s\n' \
  "RECOVERY_CONFIG_SNAPSHOT=config123" \
  "RECOVERY_DATA_SNAPSHOT=data123" \
  > "$STATE_ROOT/session.env"
FAKE_DIALOG_CONFIRM_EXIT=0
export FAKE_DIALOG_CONFIRM_EXIT
confirm_project_recovery_tui || \
  fail_test "TUI confirmation unexpectedly failed"

grep -F -- "--radiolist" "$FAKE_DIALOG_LOG" >/dev/null || \
  fail_test "TUI snapshot radiolist was not opened"
grep -F -- "--checklist" "$FAKE_DIALOG_LOG" >/dev/null || \
  fail_test "TUI project checklist was not opened"
grep -F -- "--yesno" "$FAKE_DIALOG_LOG" >/dev/null || \
  fail_test "TUI confirmation was not opened"

printf '[recovery-wizard-tui-test][ok] dialog selections passed\n'
