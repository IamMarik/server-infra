#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_LIBRARY="$REPOSITORY_ROOT/backup/bin/server-infra-output"

fail_test() {
  printf '[backup-output-test][error] %s\n' "$*" >&2
  exit 1
}

# shellcheck source=../bin/server-infra-output
source "$OUTPUT_LIBRARY"

plain_output="$(
  SERVER_INFRA_OUTPUT=plain \
    server_infra_emit "[server-infra][backup]" ok 1 "plain output"
)"
[[ "$plain_output" == "[server-infra][backup][ok] plain output" ]] || \
  fail_test "Plain backup output changed the stable log format"

pretty_output="$(
  SERVER_INFRA_OUTPUT=pretty \
    NO_COLOR=1 \
    LC_ALL= \
    LC_CTYPE= \
    LANG=server-infra.UTF-8 \
    server_infra_emit "[server-infra][backup]" warn 1 "pretty output"
)"
[[ "$pretty_output" == \
  "[server-infra][backup][warn] ⚠ pretty output" ]] || \
  fail_test "Pretty backup output did not use the warning symbol"

ascii_output="$(
  SERVER_INFRA_OUTPUT=pretty \
    NO_COLOR=1 \
    LC_ALL=C \
    server_infra_emit "[server-infra][backup]" error 1 "ASCII output"
)"
[[ "$ascii_output" == \
  "[server-infra][backup][error] ERROR ASCII output" ]] || \
  fail_test "Backup output did not use the ASCII fallback"

printf '[backup-output-test][ok] terminal output contract passed\n'
