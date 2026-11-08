#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/meeting-recorder-audio-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -O -parse-as-library \
  "$ROOT/MeetingRecorder/Recorder/M4AWriter.swift" \
  "$ROOT/MeetingRecorder/Recorder/AudioMix.swift" \
  "$ROOT/MeetingRecorder/Support/RecorderError.swift" \
  "$ROOT/tests/M4AWriterChecks.swift" \
  -o "$CHECK_DIR/check-audio"
"$CHECK_DIR/check-audio" "$@"
