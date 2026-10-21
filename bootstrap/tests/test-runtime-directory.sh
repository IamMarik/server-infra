#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT_CREATED="$(mktemp -d "${TMPDIR:-/tmp}/runtime-directory-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT_CREATED" && pwd -P)"
LOCK_ROOT="$TEST_ROOT/run/server-infra"
TMPFILES_ROOT="$TEST_ROOT/etc/tmpfiles.d"
TMPFILES_CONFIG="$TMPFILES_ROOT/server-infra.conf"
CALL_LOG="$TEST_ROOT/calls.log"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail_test() {
  printf '[runtime-directory-test][error] %s\n' "$*" >&2
  exit 1
}

# shellcheck source=../../scripts/common.sh
source "$REPOSITORY_ROOT/scripts/common.sh"

# All privileged operations are doubles and reject paths outside this fixture.
install() {
  [[ "$*" == "-d -o root -g root -m 0755 $TMPFILES_ROOT" ]] || \
    fail_test "Unexpected install: $*"
  mkdir -p "$TMPFILES_ROOT"
}

chown() {
  [[ "$1" == "root:root" && "$2" == "$TMPFILES_ROOT/".server-infra.conf.* ]] || \
    fail_test "Unexpected chown: $*"
  printf 'chown %s\n' "$*" >> "$CALL_LOG"
}

systemd-tmpfiles() {
  [[ "$#" == "2" && "$1" == "--create" && "$2" == "$TMPFILES_CONFIG" ]] || \
    fail_test "Unexpected tmpfiles invocation: $*"
  printf 'tmpfiles\n' >> "$CALL_LOG"
  [[ "${FAIL_TMPFILES:-0}" == "0" ]] || return 42
  [[ "$(cat "$2")" == "d $LOCK_ROOT 0750 root root -" ]] || \
    fail_test "Wrong runtime path, mode, owner, or cleanup policy"
  mkdir -p "$LOCK_ROOT"
  chmod 0750 "$LOCK_ROOT"
}

assert_no_temporary_files() {
  local files=("$TMPFILES_ROOT/".server-infra.conf.*)
  [[ ! -e "${files[0]}" ]] || fail_test "Temporary configuration leaked"
}

configure_runtime_directory_persistence "$LOCK_ROOT" "$TMPFILES_ROOT"
[[ -d "$LOCK_ROOT" ]] || fail_test "Missing runtime root was not created"
[[ "$(cat "$TMPFILES_CONFIG")" == "d $LOCK_ROOT 0750 root root -" ]] || \
  fail_test "Boot-time creation rule was not installed"
grep -q '^chown root:root ' "$CALL_LOG" || fail_test "Rule ownership was not set"
if [[ "$(uname -s)" == "Darwin" ]]; then
  [[ "$(stat -f '%Lp' "$TMPFILES_CONFIG")" == "644" ]] || fail_test "Wrong rule mode"
  [[ "$(stat -f '%Lp' "$LOCK_ROOT")" == "750" ]] || fail_test "Wrong lock root mode"
else
  [[ "$(stat -c '%a' "$TMPFILES_CONFIG")" == "644" ]] || fail_test "Wrong rule mode"
  [[ "$(stat -c '%a' "$LOCK_ROOT")" == "750" ]] || fail_test "Wrong lock root mode"
fi
assert_no_temporary_files

# Reapplying must preserve an active lock and the caller's EXIT cleanup.
mkdir "$LOCK_ROOT/operation.lock"
printf 'lock-owner-nonce\n' > "$LOCK_ROOT/operation.lock/owner"
original_rule="$(cksum < "$TMPFILES_CONFIG")"
original_trap="$(trap -p EXIT)"
configure_runtime_directory_persistence "$LOCK_ROOT" "$TMPFILES_ROOT"
[[ "$(cksum < "$TMPFILES_CONFIG")" == "$original_rule" ]] || fail_test "Rule changed"
[[ "$(cat "$LOCK_ROOT/operation.lock/owner")" == "lock-owner-nonce" ]] || \
  fail_test "Active lock was modified"
[[ "$(trap -p EXIT)" == "$original_trap" ]] || fail_test "Caller cleanup trap changed"
if (acquire_deployment_lock "$LOCK_ROOT") >/dev/null 2>&1; then
  fail_test "Existing deployment lock was bypassed"
fi
rm "$LOCK_ROOT/operation.lock/owner"
rmdir "$LOCK_ROOT/operation.lock"

# Model the loss of /run on reboot. Only the installed rule remains; replaying
# it must restore the directory without rerunning bootstrap or backup setup.
rmdir "$LOCK_ROOT"
systemd-tmpfiles --create "$TMPFILES_CONFIG"
[[ -d "$LOCK_ROOT" ]] || fail_test "Boot rule did not restore the runtime root"

printf 'operator-owned conflicting rule\n' > "$TMPFILES_CONFIG"
: > "$CALL_LOG"
if (configure_runtime_directory_persistence "$LOCK_ROOT" "$TMPFILES_ROOT") \
  > "$TEST_ROOT/conflict.log" 2>&1; then
  fail_test "Conflicting rule was accepted"
fi
[[ "$(cat "$TMPFILES_CONFIG")" == "operator-owned conflicting rule" ]] || \
  fail_test "Conflicting rule was overwritten"
[[ ! -s "$CALL_LOG" ]] || fail_test "Conflicting rule reached tmpfiles"
assert_no_temporary_files
rm "$TMPFILES_CONFIG"

printf 'sentinel\n' > "$TEST_ROOT/sentinel"
ln -s "$TEST_ROOT/sentinel" "$TMPFILES_CONFIG"
if (configure_runtime_directory_persistence "$LOCK_ROOT" "$TMPFILES_ROOT") \
  >/dev/null 2>&1; then
  fail_test "Symlink rule was accepted"
fi
[[ "$(cat "$TEST_ROOT/sentinel")" == "sentinel" ]] || fail_test "Symlink target changed"
rm "$TMPFILES_CONFIG"
mkdir "$TMPFILES_CONFIG"
if (configure_runtime_directory_persistence "$LOCK_ROOT" "$TMPFILES_ROOT") \
  >/dev/null 2>&1; then
  fail_test "Directory used as a rule was accepted"
fi
rmdir "$TMPFILES_CONFIG"

rmdir "$LOCK_ROOT"
mkdir "$TEST_ROOT/foreign-lock-root"
ln -s "$TEST_ROOT/foreign-lock-root" "$LOCK_ROOT"
if (configure_runtime_directory_persistence "$LOCK_ROOT" "$TMPFILES_ROOT") \
  >/dev/null 2>&1; then
  fail_test "Symlink lock root was accepted"
fi
rm "$LOCK_ROOT"
printf 'not-a-directory\n' > "$LOCK_ROOT"
if (configure_runtime_directory_persistence "$LOCK_ROOT" "$TMPFILES_ROOT") \
  >/dev/null 2>&1; then
  fail_test "Regular file used as lock root was accepted"
fi
rm "$LOCK_ROOT"

mv "$TMPFILES_ROOT" "$TMPFILES_ROOT.real"
ln -s "$TMPFILES_ROOT.real" "$TMPFILES_ROOT"
if (configure_runtime_directory_persistence "$LOCK_ROOT" "$TMPFILES_ROOT") \
  >/dev/null 2>&1; then
  fail_test "Symlink tmpfiles directory was accepted"
fi
rm "$TMPFILES_ROOT"
mv "$TMPFILES_ROOT.real" "$TMPFILES_ROOT"
for unsafe_root in relative / "$TEST_ROOT/space path" "$TEST_ROOT/%n"; do
  if (configure_runtime_directory_persistence "$unsafe_root" "$TMPFILES_ROOT") \
    >/dev/null 2>&1; then
    fail_test "Unsafe tmpfiles path was accepted: $unsafe_root"
  fi
done
[[ ! -e "$TMPFILES_CONFIG" ]] || fail_test "Rejected paths installed a rule"

if (FAIL_TMPFILES=1; configure_runtime_directory_persistence "$LOCK_ROOT" "$TMPFILES_ROOT") \
  >/dev/null 2>&1; then
  fail_test "tmpfiles failure was ignored"
fi
assert_no_temporary_files
[[ ! -d "$LOCK_ROOT" ]] || fail_test "Failed tmpfiles created a lock root"

# Install check mode must not configure the runtime root or enter apply.
(
  # shellcheck source=../../scripts/install.sh
  source "$REPOSITORY_ROOT/scripts/install.sh"
  configure_runtime_directory_persistence() { fail_test "Install check mutated runtime"; }
  apply_install_plan() { fail_test "Install check entered apply"; }
  main --module backup --check >/dev/null
)

# Exercise real deployment ordering with doubles for host/configuration work.
# The real helper and deployment lock operate only in the isolated fixture.
(
  # shellcheck source=../../scripts/deploy.sh
  source "$REPOSITORY_ROOT/scripts/deploy.sh"
  RUN_ROOT="$LOCK_ROOT"
  eval "$(declare -f configure_runtime_directory_persistence | \
    sed '1s/configure_runtime_directory_persistence/configure_fixture_runtime/')"
  configure_runtime_directory_persistence() {
    configure_fixture_runtime "$1" "$TMPFILES_ROOT"
  }
  load_external_context() {
    EXTERNAL_MODULES=(backup)
    EXTERNAL_HAS_HOST=1
    EXTERNAL_HAS_COMPOSE=0
  }
  prepare_external_tools() { :; }
  run_host_module_preflight() { :; }
  install_host_module_artifacts() {
    [[ -d "$LOCK_ROOT/operation.lock" ]] || fail_test "Artifacts installed without lock"
    printf 'artifacts\n' >> "$CALL_LOG"
  }
  systemctl() {
    [[ -d "$LOCK_ROOT/operation.lock" ]] || fail_test "Units activated without lock"
    printf 'systemctl %s\n' "$*" >> "$CALL_LOG"
  }
  : > "$CALL_LOG"
  deploy_external_environment "$TEST_ROOT/config" check 0 >/dev/null
  [[ ! -s "$CALL_LOG" && ! -d "$LOCK_ROOT" ]] || fail_test "Deploy check changed runtime"
  deploy_external_environment "$TEST_ROOT/config" apply 0 >/dev/null
  [[ "$(head -n 1 "$CALL_LOG")" == "tmpfiles" ]] || \
    fail_test "Deployment did not prepare runtime before artifacts/units"
  grep -q '^artifacts$' "$CALL_LOG" || fail_test "Host artifacts were not installed"
  grep -q '^systemctl daemon-reload$' "$CALL_LOG" || fail_test "Units were not reloaded"
  grep -q '^systemctl enable --now server-infra-backup.timer$' "$CALL_LOG" || \
    fail_test "Backup timer was not activated after preparation"
)
[[ ! -d "$LOCK_ROOT/operation.lock" ]] || fail_test "Deployment leaked its own lock"
assert_no_temporary_files
printf '[runtime-directory-test][ok] persistence, reboot replay, safety, and deployment checks passed\n'
