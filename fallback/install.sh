#!/usr/bin/env bash
# One-command setup for the no-compile fallback.
# Installs ffmpeg, BlackHole 2ch, and (if it can) SwiftBar, then a menu-bar plugin.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${HOME}/.meeting-recorder"
PLUGIN_DIR="${HOME}/Library/Application Support/SwiftBar/Plugins"
LOCAL_BIN="${HOME}/.local/bin"

if ! command -v brew >/dev/null 2>&1; then
  printf '%s\n' "没有找到 Homebrew。先安装它（官方脚本在 https://brew.sh ），然后再运行："
  printf '%s\n' "  bash fallback/install.sh"
  exit 1
fi

printf '%s\n' "安装 ffmpeg…"
brew install ffmpeg

printf '%s\n' "安装 BlackHole 2ch（安装器会向你要管理员密码，这是声卡驱动，正常）…"
brew install --cask blackhole-2ch

printf '%s\n' "安装 SwiftBar（菜单栏插件，装不上也能用终端录音）…"
if ! brew install --cask swiftbar; then
  printf '%s\n' "SwiftBar 没有装上。终端里仍然可以录音。"
fi

mkdir -p "$STATE_DIR" "$PLUGIN_DIR" "$LOCAL_BIN" "${HOME}/Documents/MeetingRecordings"
cp "$ROOT/record.sh" "$STATE_DIR/record.sh"
chmod +x "$STATE_DIR/record.sh" "$ROOT/record.sh"
cp "$ROOT/meeting-recorder.2s.sh" "$PLUGIN_DIR/meeting-recorder.2s.sh"
chmod +x "$PLUGIN_DIR/meeting-recorder.2s.sh"
ln -sfn "$STATE_DIR/record.sh" "$LOCAL_BIN/meeting-recorder"

printf '\n%s\n' "文件已放好。接下来这一步只能手动做一次："
cat <<'EOF'

1. 打开「音频 MIDI 设置」（马上会尝试帮你打开）。
2. 左下角点「+」→「创建多输出设备」。
3. 勾选两样东西：
   - 你的扬声器或耳机（这样你听得到）
   - BlackHole 2ch（这样录得到对方）
4. 「主设备」选你的扬声器，不要选 BlackHole。
5. 「系统设置 → 声音 → 输出」选这个多输出设备。
6. 「系统设置 → 声音 → 输入」保持你的麦克风，不要改成 BlackHole。

然后检查设备：

  ~/.meeting-recorder/record.sh devices

开始 / 停止：

  ~/.meeting-recorder/record.sh start
  ~/.meeting-recorder/record.sh stop

菜单栏：打开 SwiftBar，应出现一个圆点。录音时变红并显示时间。
第一次用 ffmpeg 录音，macOS 可能询问是否允许「终端」或 SwiftBar 使用麦克风，请允许。

录音文件在：文稿/MeetingRecordings/
EOF

"$STATE_DIR/record.sh" audio-midi || true
if "$STATE_DIR/record.sh" devices; then
  printf '%s\n' "设备看起来可用。"
else
  printf '%s\n' "还没有同时看到麦克风和 BlackHole。如果安装器要求重启，重启后再运行： ~/.meeting-recorder/record.sh devices"
fi

if [[ -d "/Applications/SwiftBar.app" ]]; then
  open -a SwiftBar || true
fi
