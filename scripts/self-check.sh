#!/usr/bin/env bash
# Structure checks that can run without Xcode or a Mac.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

need() {
  if [[ ! -e "$1" ]]; then
    echo "missing: $1" >&2
    exit 1
  fi
}

need MeetingRecorder.xcodeproj/project.pbxproj
need MeetingRecorder.xcodeproj/xcshareddata/xcschemes/MeetingRecorder.xcscheme
need MeetingRecorder/Info.plist
need MeetingRecorder/AppMain.swift
need MeetingRecorder/Recorder/SystemAudioCapture.swift
need MeetingRecorder/Recorder/MicrophoneCapture.swift
need MeetingRecorder/Recorder/RecordingEngine.swift
need .github/workflows/build-macos-app.yml
need scripts/build-app.sh
need fallback/install.sh
need fallback/record.sh
need fallback/meeting-recorder.2s.sh
need packaging/请先读我.txt
need README.md

python3 - <<'PY'
import plistlib
from pathlib import Path
plist = plistlib.loads(Path("MeetingRecorder/Info.plist").read_bytes())
for key in (
    "NSMicrophoneUsageDescription",
    "NSScreenCaptureUsageDescription",
    "NSAudioCaptureUsageDescription",
):
    text = plist[key]
    if "本机" not in text and "本地" not in text and "只" not in text:
        raise SystemExit(f"{key} does not say the recording stays local: {text}")
    print(f"{key}: ok")
if plist["LSUIElement"] is not True:
    raise SystemExit("LSUIElement should be true")
if plist["CFBundleDisplayName"] != "会议录音":
    raise SystemExit("display name")
print("plist ok")
PY

grep -q "开始录音" MeetingRecorder/Recorder/MeetingSession.swift
grep -q "停止录音" MeetingRecorder/Recorder/MeetingSession.swift
grep -q "打开录音文件夹" MeetingRecorder/UI/PopoverView.swift
grep -q "capturesAudio" MeetingRecorder/Recorder/SystemAudioCapture.swift
grep -q "excludesCurrentProcessAudio" MeetingRecorder/Recorder/SystemAudioCapture.swift
grep -q "CMTime(value: 1, timescale: 1)" MeetingRecorder/Recorder/SystemAudioCapture.swift
grep -q "noAudioAppsSelected" MeetingRecorder/Support/RecorderError.swift
grep -q "全部应用" MeetingRecorder/UI/PopoverView.swift
grep -q "com.tencent.xinWeChat" MeetingRecorder/Support/CapturePreferences.swift
grep -q "com.tencent.WeWorkMac" MeetingRecorder/Support/CapturePreferences.swift
grep -q "systemAudio.selectedBundleIDs" MeetingRecorder/Support/CapturePreferences.swift
grep -q "SCContentFilter(display: display, including:" MeetingRecorder/Recorder/SystemAudioCapture.swift
if grep -q "CMTimeScale.max" MeetingRecorder/Recorder/SystemAudioCapture.swift; then
  echo "SystemAudioCapture must not use CMTimeScale.max" >&2
  exit 1
fi
grep -q "setVoiceProcessingEnabled" MeetingRecorder/Recorder/MicrophoneCapture.swift
grep -q "macos-latest" .github/workflows/build-macos-app.yml
grep -q "MeetingRecordings" MeetingRecorder/Support/RecordingPaths.swift
grep -q "MeetingRecordings" fallback/record.sh

if grep -R -n -E "https?://" MeetingRecorder --include='*.swift'; then
  echo "Swift sources should not call the network." >&2
  exit 1
fi

bash -n fallback/record.sh
bash -n fallback/install.sh
bash -n fallback/meeting-recorder.2s.sh
bash -n scripts/build-app.sh
bash fallback/record.sh self-test

# Every Swift file is listed in the Xcode project.
while IFS= read -r file; do
  base="$(basename "$file")"
  if ! grep -q "$base" MeetingRecorder.xcodeproj/project.pbxproj; then
    echo "not in pbxproj: $file" >&2
    exit 1
  fi
done < <(find MeetingRecorder -name '*.swift' -print)

for icon in 16 32 64 128 256 512 1024; do
  need "MeetingRecorder/Assets.xcassets/AppIcon.appiconset/icon_${icon}.png"
done

echo "self-check ok"
