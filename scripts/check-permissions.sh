#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/meeting-recorder-permissions.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -parse-as-library \
  "$ROOT/MeetingRecorder/Permissions/PermissionCenter.swift" \
  "$ROOT/tests/PermissionCenterChecks.swift" \
  -o "$CHECK_DIR/check-permissions"
"$CHECK_DIR/check-permissions"
