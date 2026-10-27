#!/usr/bin/env bash
# <xbar.title>会议录音</xbar.title>
# <swiftbar.title>会议录音</swiftbar.title>
# <swiftbar.refreshOn>2s</swiftbar.refreshOn>
# SwiftBar / xbar plugin. Refresh interval comes from the ".2s" filename.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

RECORD="${HOME}/.meeting-recorder/record.sh"

fmt_elapsed() {
  local total="${1:-0}"
  if [[ ! "$total" =~ ^[0-9]+$ ]]; then
    total=0
  fi
  local h=$((total / 3600)) m=$(((total % 3600) / 60)) s=$((total % 60))
  if (( h > 0 )); then
    printf '%d:%02d:%02d' "$h" "$m" "$s"
  else
    printf '%02d:%02d' "$m" "$s"
  fi
}

if [[ ! -x "$RECORD" ]]; then
  echo "● | color=#C47B00"
  echo "---"
  echo "会议录音还没安装 | color=#666666"
  echo "请在终端运行 fallback/install.sh | color=#666666"
  exit 0
fi

status="$("$RECORD" status 2>/dev/null || true)"
value() {
  printf '%s\n' "$status" | sed -n "s/^$1=//p" | head -n 1
}

state="$(value STATE)"
elapsed="$(value ELAPSED)"
error="$(value ERROR)"
last="$(value LAST)"
mic="$(value MIC)"
sys="$(value SYS)"

case "$state" in
  recording)
    printf '● %s | color=#E23B2F size=13\n' "$(fmt_elapsed "$elapsed")"
    ;;
  stale)
    echo "● ? | color=#E23B2F size=13"
    ;;
  *)
    echo "● | color=#8E8E93 size=13"
    ;;
esac

echo "---"
echo "会议录音 | size=14"
echo "本地 m4a，不上传 | color=#666666 size=11"

if [[ "$state" == "recording" ]]; then
  echo "停止录音 | bash='$RECORD' param1=stop terminal=false refresh=true"
elif [[ "$state" == "stale" ]]; then
  echo "保存并停止 | bash='$RECORD' param1=stop terminal=false refresh=true"
else
  echo "开始录音 | bash='$RECORD' param1=start terminal=false refresh=true"
fi

echo "打开录音文件夹 | bash='$RECORD' param1=open terminal=false refresh=true"

if [[ -n "$last" ]]; then
  base="$(basename "$last")"
  echo "在访达中显示：${base} | bash='$RECORD' param1=reveal terminal=false refresh=true"
fi

if [[ -n "$error" ]]; then
  safe="${error//|/／}"
  echo "⚠ ${safe} | color=#E23B2F length=90"
fi

echo "---"
if [[ -n "$mic" || -n "$sys" ]]; then
  echo "麦克风：${mic:-未选择} | color=#666666 size=11"
  echo "系统音频：${sys:-未选择} | color=#666666 size=11"
fi
echo "微信：输出用「多输出设备」（扬声器 + BlackHole） | color=#666666 size=11"
echo "设置多输出设备… | bash='$RECORD' param1=audio-midi terminal=false"
echo "检查音频设备 | bash='$RECORD' param1=devices terminal=true refresh=true"
