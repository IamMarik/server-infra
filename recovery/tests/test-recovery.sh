#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_TMPDIR="${TMPDIR:-/tmp}"
TEST_ROOT_CREATED="$(mktemp -d "${TEST_TMPDIR%/}/recovery-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT_CREATED" && pwd -P)"
STATE_ROOT="$TEST_ROOT/state/recovery"
ABSENT_STATE_ROOT="$TEST_ROOT/absent/recovery"
WRONG_STATE_ROOT="$TEST_ROOT/wrong/state"
UNSAFE_STATE_ROOT="$TEST_ROOT/unsafe/state"
BREAK_GLASS_FILE="$TEST_ROOT/server-infra-break-glass.txt"
WRONG_BREAK_GLASS_FILE="$TEST_ROOT/wrong-break-glass.txt"
UNSAFE_BREAK_GLASS_FILE="$TEST_ROOT/unsafe-break-glass.txt"
SYMLINK_BREAK_GLASS_FILE="$TEST_ROOT/symlink-break-glass.txt"
TEST_BIN="$TEST_ROOT/bin"
COMMAND_OUTPUT="$TEST_ROOT/command.log"
PLAN_OUTPUT="$TEST_ROOT/plan.log"
STATUS_OUTPUT="$TEST_ROOT/status.log"
RECOVERY="$REPOSITORY_ROOT/recovery/bin/server-infra-recovery"
TEST_REPOSITORY_URL="git@github.com:example/server-infra.git"
TEST_REPOSITORY_REF="0123456789abcdef0123456789abcdef01234567"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail_test() {
  printf '[recovery-test][error] %s\n' "$*" >&2
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

write_break_glass() {
  local output_file="$1"
  local repository_url="$2"
  local repository_ref="$3"

  printf '%s\n' \
    "SERVER INFRA BREAK-GLASS RECORD" \
    "" \
    "Sensitive: yes" \
    "" \
    "BREAK_GLASS_VERSION: 1" \
    "GENERATED_AT: 2026-07-24T00:00:00Z" \
    "SERVER_INFRA_INSTANCE: acceptance" \
    "SERVER_INFRA_REPOSITORY_URL: $repository_url" \
    "SERVER_INFRA_REPOSITORY_REF: $repository_ref" \
    "" \
    "RESTIC_REPOSITORY: s3:https://s3.example.test/test-bucket/acceptance" \
    "RESTIC_PASSWORD: test-restic-password" \
    "AWS_ACCESS_KEY_ID: test-access-key" \
    "AWS_SECRET_ACCESS_KEY: test-secret-key" \
    "AWS_DEFAULT_REGION: us-west-004" \
    > "$output_file"
  chmod 0600 "$output_file"
}

mkdir -p "$TEST_BIN"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'case "$*" in' \
  '  *"rev-parse --is-inside-work-tree")' \
  '    printf "%s\n" "true"' \
  '    ;;' \
  '  *"remote get-url origin")' \
  '    printf "%s\n" "git@github.com:example/server-infra.git"' \
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

write_break_glass \
  "$BREAK_GLASS_FILE" \
  "$TEST_REPOSITORY_URL" \
  "$TEST_REPOSITORY_REF"

if PATH="$TEST_BIN:$PATH" "$RECOVERY" \
  --state-root "$ABSENT_STATE_ROOT" plan >/dev/null 2>&1; then
  fail_test "Plan accepted a missing recovery session"
fi
[[ ! -e "$ABSENT_STATE_ROOT" ]] || \
  fail_test "Plan changed host state for a missing session"

PATH="$TEST_BIN:$PATH" "$RECOVERY" \
  --state-root "$STATE_ROOT" \
  init --break-glass "$BREAK_GLASS_FILE" > "$COMMAND_OUTPUT" 2>&1

STATE_FILE="$STATE_ROOT/session.env"
[[ -f "$STATE_FILE" ]] || fail_test "Recovery state was not created"
[[ "$(file_mode "$STATE_ROOT")" == "700" ]] || \
  fail_test "Recovery state root mode is not 0700"
[[ "$(file_mode "$STATE_FILE")" == "600" ]] || \
  fail_test "Recovery state file mode is not 0600"
assert_contains "$STATE_FILE" "RECOVERY_INSTANCE=acceptance"
assert_contains "$STATE_FILE" "RECOVERY_PHASE_REPOSITORY=complete"
assert_contains "$STATE_FILE" "RECOVERY_PHASE_CONFIG=pending"
assert_contains "$STATE_FILE" \
  "RECOVERY_INFRA_REPOSITORY_REF=$TEST_REPOSITORY_REF"

for secret_value in \
  "test-restic-password" \
  "test-access-key" \
  "test-secret-key"; do
  if grep -F "$secret_value" "$STATE_FILE" "$COMMAND_OUTPUT" >/dev/null; then
    fail_test "Secret value escaped into state or command output"
  fi
done

BEFORE_CHECKSUM="$(cksum "$STATE_FILE")"
PATH="$TEST_BIN:$PATH" "$RECOVERY" \
  --state-root "$STATE_ROOT" \
  init --break-glass "$BREAK_GLASS_FILE" >> "$COMMAND_OUTPUT" 2>&1
AFTER_CHECKSUM="$(cksum "$STATE_FILE")"
[[ "$BEFORE_CHECKSUM" == "$AFTER_CHECKSUM" ]] || \
  fail_test "Repeated init changed existing recovery state"

PATH="$TEST_BIN:$PATH" "$RECOVERY" \
  --state-root "$STATE_ROOT" plan > "$PLAN_OUTPUT"
PATH="$TEST_BIN:$PATH" "$RECOVERY" \
  --state-root "$STATE_ROOT" status > "$STATUS_OUTPUT"
assert_contains "$PLAN_OUTPUT" \
  "1. [complete] Verify server-infra repository and exact commit"
assert_contains "$PLAN_OUTPUT" \
  "2. [pending] Restore and validate /etc/server-infra"
assert_contains "$PLAN_OUTPUT" \
  "Next: restore host configuration using backup/RECOVERY.md."
assert_contains "$STATUS_OUTPUT" "Instance: acceptance"
assert_contains "$STATUS_OUTPUT" "Configuration snapshot: not-selected"
assert_contains "$STATUS_OUTPUT" "Data snapshot: not-selected"

write_break_glass \
  "$WRONG_BREAK_GLASS_FILE" \
  "$TEST_REPOSITORY_URL" \
  "abcdef0123456789abcdef0123456789abcdef01"
if PATH="$TEST_BIN:$PATH" "$RECOVERY" \
  --state-root "$WRONG_STATE_ROOT" \
  init --break-glass "$WRONG_BREAK_GLASS_FILE" >/dev/null 2>&1; then
  fail_test "Recovery accepted a mismatched infrastructure commit"
fi
[[ ! -e "$WRONG_STATE_ROOT" ]] || \
  fail_test "Failed initialization created recovery state"

write_break_glass \
  "$UNSAFE_BREAK_GLASS_FILE" \
  "https://token@github.com/example/server-infra.git" \
  "$TEST_REPOSITORY_REF"
if PATH="$TEST_BIN:$PATH" "$RECOVERY" \
  --state-root "$UNSAFE_STATE_ROOT" \
  init --break-glass "$UNSAFE_BREAK_GLASS_FILE" >/dev/null 2>&1; then
  fail_test "Recovery accepted a Git URL containing credentials"
fi
[[ ! -e "$UNSAFE_STATE_ROOT" ]] || \
  fail_test "Unsafe initialization created recovery state"

ln -s "$BREAK_GLASS_FILE" "$SYMLINK_BREAK_GLASS_FILE"
if PATH="$TEST_BIN:$PATH" "$RECOVERY" \
  --state-root "$TEST_ROOT/symlink/state" \
  init --break-glass "$SYMLINK_BREAK_GLASS_FILE" >/dev/null 2>&1; then
  fail_test "Recovery accepted a symlinked break-glass record"
fi

printf '[recovery-test][ok] secure initialization, plan, status, and rerun passed\n'
