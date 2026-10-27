#!/usr/bin/env bash
# Homebrew fallback recorder. Mixes BlackHole (system audio) + microphone
# into one AAC m4a. No Xcode, no Swift build. See README for the Multi-Output setup.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}"

STATE_DIR="${HOME}/.meeting-recorder"
RECORDINGS_DIR="${HOME}/Documents/MeetingRecordings"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$STATE_DIR" "$RECORDINGS_DIR"

usage() {
  cat <<'EOF'
用法：
  record.sh start        开始录音（麦克风 + BlackHole）
  record.sh stop         停止并保存 m4a
  record.sh toggle       开始或停止
  record.sh status       打印状态
  record.sh devices      列出将使用的设备
  record.sh open         打开录音文件夹
  record.sh reveal       在访达中显示最近一次
  record.sh audio-midi   打开「音频 MIDI 设置」
  record.sh self-test    检查设备名解析（不录音）

录音保存在：~/Documents/MeetingRecordings/会议录音_年月日_时分秒.m4a
系统音频要先做「多输出设备」（扬声器 + BlackHole 2ch），见 README。
EOF
}

fail() {
  printf '%s\n' "$1" >"$STATE_DIR/last_error"
  printf '%s\n' "$1" >&2
  exit 1
}

note() {
  printf '%s\n' "$1" >"$STATE_DIR/last_error"
}

clear_note() {
  : >"$STATE_DIR/last_error"
}

parse_avfoundation_audio() {
  local in_audio=0 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" == *"AVFoundation audio devices:"* ]]; then
      in_audio=1
      continue
    fi
    if [[ "$line" == *"AVFoundation video devices:"* ]]; then
      in_audio=0
      continue
    fi
    if [[ "$in_audio" -eq 1 && "$line" =~ \[([0-9]+)\][[:space:]]+(.+)$ ]]; then
      printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    fi
  done
}

# stdin: idx<TAB>name lines from parse_avfoundation_audio
# stdout: mic index, mic name, system index, system name
choose_devices() {
  local idx="" name="" low=""
  local best_mic_score=-1 best_mic_idx="" best_mic_name=""
  local best_sys_score=0 best_sys_idx="" best_sys_name=""
  local mic_score sys_score
  while IFS=$'\t' read -r idx name; do
    [[ -n "$idx" ]] || continue
    low=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    sys_score=0
    if [[ "$low" == *blackhole*2ch* || "$low" == *"blackhole 2"* ]]; then
      sys_score=3
    elif [[ "$low" == *blackhole* ]]; then
      sys_score=2
    fi
    if (( sys_score > best_sys_score )); then
      best_sys_score=$sys_score
      best_sys_idx=$idx
      best_sys_name=$name
    fi

    mic_score=1
    if [[ "$low" == *blackhole* || "$low" == *zoom* || "$low" == *teams* || "$low" == *krisp* || "$low" == *aggregate* || "$low" == *multi-output* || "$low" == *"multi output"* || "$low" == *soundflower* || "$low" == *vb-audio* || "$low" == *多输出* ]]; then
      mic_score=0
    elif [[ "$low" == *microphone* || "$low" == *麦克风* || "$low" == *built-in* || "$low" == *macbook* || "$low" == *imac* || "$low" == *内建* || "$low" == *內建* ]]; then
      mic_score=3
    fi
    if (( mic_score > best_mic_score )); then
      best_mic_score=$mic_score
      best_mic_idx=$idx
      best_mic_name=$name
    fi
  done

  if [[ -z "$best_mic_idx" || "$best_mic_score" -le 0 ]]; then
    printf '%s\n' "没有找到麦克风。请确认系统设置里能看到麦克风，并且 ffmpeg 列得出音频设备。" >&2
    return 10
  fi
  if [[ -z "$best_sys_idx" ]]; then
    printf '%s\n' "没有找到 BlackHole。先运行 fallback/install.sh，装好后如果仍没有，重启 Mac 再试。" >&2
    return 11
  fi
  printf '%s\n' "$best_mic_idx" "$best_mic_name" "$best_sys_idx" "$best_sys_name"
}

list_ffmpeg_devices() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    fail "找不到 ffmpeg。请先运行 fallback/install.sh（需要 Homebrew）。"
  fi
  ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true
}

read_choice() {
  local parsed choice
  parsed="$(list_ffmpeg_devices | parse_avfoundation_audio)"
  if [[ -z "$parsed" ]]; then
    fail "ffmpeg 没有列出音频设备。请确认已安装 ffmpeg，并且这台 Mac 允许终端或 SwiftBar 使用麦克风。"
  fi
  if ! choice="$(printf '%s\n' "$parsed" | choose_devices)"; then
    printf '%s\n' "$parsed" >&2
    exit 1
  fi
  MIC_INDEX="$(printf '%s\n' "$choice" | sed -n '1p')"
  MIC_NAME="$(printf '%s\n' "$choice" | sed -n '2p')"
  SYS_INDEX="$(printf '%s\n' "$choice" | sed -n '3p')"
  SYS_NAME="$(printf '%s\n' "$choice" | sed -n '4p')"
}

pid_alive() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  local pid
  pid="$(cat "$file" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

current_state() {
  if pid_alive "$STATE_DIR/sys.pid" || pid_alive "$STATE_DIR/mic.pid"; then
    printf 'recording'
    return
  fi
  if [[ -f "$STATE_DIR/started_at" ]]; then
    printf 'stale'
    return
  fi
  printf 'idle'
}

elapsed_seconds() {
  if [[ ! -f "$STATE_DIR/started_at" ]]; then
    printf '0'
    return
  fi
  local started now
  started="$(cat "$STATE_DIR/started_at")"
  now="$(date +%s)"
  if [[ "$started" =~ ^[0-9]+$ ]] && (( now >= started )); then
    printf '%s' "$((now - started))"
  else
    printf '0'
  fi
}

acquire_lock() {
  if ! mkdir "$STATE_DIR/lock" 2>/dev/null; then
    fail "上一个录音操作还在进行。如果确认没有在录音，删除这个文件夹后再试：${STATE_DIR}/lock"
  fi
  trap 'rmdir "$STATE_DIR/lock" 2>/dev/null || true' EXIT
}

wav_ok() {
  [[ -f "$1" ]] || return 1
  local size
  size="$(wc -c <"$1" | tr -d '[:space:]')"
  [[ "$size" =~ ^[0-9]+$ ]] && (( size > 1000 ))
}

stop_pid_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local pid
  pid="$(cat "$file" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 0
  kill -INT "$pid" 2>/dev/null || true
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  kill -TERM "$pid" 2>/dev/null || true
  sleep 0.4
  kill -KILL "$pid" 2>/dev/null || true
}

finalize() {
  local work out sys_wav mic_wav tmp
  work="$(cat "$STATE_DIR/work_dir" 2>/dev/null || true)"
  out="$(cat "$STATE_DIR/output_path" 2>/dev/null || true)"
  if [[ -z "$work" || -z "$out" || ! -d "$work" ]]; then
    rm -f "$STATE_DIR/started_at" "$STATE_DIR/sys.pid" "$STATE_DIR/mic.pid"
    fail "找不到这次录音的临时文件，无法保存。"
  fi
  sys_wav="$work/system.wav"
  mic_wav="$work/mic.wav"
  tmp="${out}.partial.m4a"
  mkdir -p "$RECORDINGS_DIR"

  if wav_ok "$sys_wav" && wav_ok "$mic_wav"; then
    local filter='[0:a]aresample=48000,aformat=channel_layouts=stereo[s];[1:a]aresample=48000,aformat=channel_layouts=stereo[m];[s][m]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0,alimiter=limit=0.95'
    if ! ffmpeg -y -hide_banner -loglevel error -i "$sys_wav" -i "$mic_wav" -filter_complex "$filter" -c:a aac -b:a 160k "$tmp"; then
      filter='[0:a]aresample=48000,aformat=channel_layouts=stereo[s];[1:a]aresample=48000,aformat=channel_layouts=stereo[m];[s][m]amix=inputs=2:duration=longest:dropout_transition=0'
      ffmpeg -y -hide_banner -loglevel error -i "$sys_wav" -i "$mic_wav" -filter_complex "$filter" -c:a aac -b:a 160k "$tmp"
    fi
    mv -f "$tmp" "$out"
    clear_note
  elif wav_ok "$sys_wav"; then
    ffmpeg -y -hide_banner -loglevel error -i "$sys_wav" -c:a aac -b:a 160k "$tmp"
    mv -f "$tmp" "$out"
    note "只录到系统音频，没有麦克风。已保存这一路。请检查麦克风权限。"
  elif wav_ok "$mic_wav"; then
    ffmpeg -y -hide_banner -loglevel error -i "$mic_wav" -c:a aac -b:a 160k "$tmp"
    mv -f "$tmp" "$out"
    note "只录到麦克风，没有系统音频。已保存这一路。请确认多输出设备里勾了 BlackHole，并且系统输出选的是它。"
  else
    rm -f "$STATE_DIR/started_at" "$STATE_DIR/sys.pid" "$STATE_DIR/mic.pid"
    fail "没有录到声音。临时文件在：${work}"
  fi

  printf '%s\n' "$out" >"$STATE_DIR/last_output"
  rm -f "$STATE_DIR/started_at" "$STATE_DIR/sys.pid" "$STATE_DIR/mic.pid"
  rm -rf "$work"
  rm -f "$STATE_DIR/work_dir"
  printf '%s\n' "已保存：$out"
}

cmd_status() {
  local state elapsed mic sys err last
  state="$(current_state)"
  elapsed="$(elapsed_seconds)"
  mic="$(cat "$STATE_DIR/mic_name" 2>/dev/null || true)"
  sys="$(cat "$STATE_DIR/sys_name" 2>/dev/null || true)"
  err="$(tr '\n' ' ' <"$STATE_DIR/last_error" 2>/dev/null || true)"
  last="$(cat "$STATE_DIR/last_output" 2>/dev/null || true)"
  printf 'STATE=%s\n' "$state"
  printf 'ELAPSED=%s\n' "$elapsed"
  printf 'MIC=%s\n' "$mic"
  printf 'SYS=%s\n' "$sys"
  printf 'ERROR=%s\n' "$err"
  printf 'LAST=%s\n' "$last"
}

cmd_devices() {
  local parsed
  parsed="$(list_ffmpeg_devices | parse_avfoundation_audio)"
  printf '%s\n' "ffmpeg 看到的音频设备："
  if [[ -z "$parsed" ]]; then
    printf '%s\n' "（空）"
    exit 1
  fi
  while IFS=$'\t' read -r idx name; do
    printf '  [%s] %s\n' "$idx" "$name"
  done <<<"$parsed"
  local choice
  if ! choice="$(printf '%s\n' "$parsed" | choose_devices)"; then
    exit 1
  fi
  printf '\n%s\n' "将使用："
  printf '  麦克风：[%s] %s\n' "$(printf '%s\n' "$choice" | sed -n '1p')" "$(printf '%s\n' "$choice" | sed -n '2p')"
  printf '  系统音频：[%s] %s\n' "$(printf '%s\n' "$choice" | sed -n '3p')" "$(printf '%s\n' "$choice" | sed -n '4p')"
  printf '\n%s\n' "请把系统输出设成「多输出设备」（你的扬声器 + BlackHole），输入保持麦克风。不要把输入改成 BlackHole。"
}

cmd_start() {
  local state
  state="$(current_state)"
  if [[ "$state" == "recording" ]]; then
    printf '%s\n' "已经在录音。"
    exit 0
  fi
  acquire_lock
  if [[ "$state" == "stale" ]]; then
    finalize || true
  fi
  read_choice
  local stamp work out
  stamp="$(date "+%Y%m%d_%H%M%S")"
  out="$RECORDINGS_DIR/会议录音_${stamp}.m4a"
  work="$(mktemp -d "${TMPDIR:-/tmp}/meeting-recorder.XXXXXX")"
  printf '%s\n' "$MIC_INDEX" >"$STATE_DIR/mic_index"
  printf '%s\n' "$MIC_NAME" >"$STATE_DIR/mic_name"
  printf '%s\n' "$SYS_INDEX" >"$STATE_DIR/sys_index"
  printf '%s\n' "$SYS_NAME" >"$STATE_DIR/sys_name"
  printf '%s\n' "$work" >"$STATE_DIR/work_dir"
  printf '%s\n' "$out" >"$STATE_DIR/output_path"
  printf '%s\n' "$(date +%s)" >"$STATE_DIR/started_at"
  clear_note

  # nohup so SwiftBar / Terminal exiting does not send SIGHUP to ffmpeg.
  nohup ffmpeg -hide_banner -loglevel warning \
    -f avfoundation -thread_queue_size 2048 \
    -i ":${SYS_INDEX}" \
    -ac 2 -ar 48000 -c:a pcm_s16le -y "$work/system.wav" \
    >"$work/system.log" 2>&1 &
  printf '%s\n' "$!" >"$STATE_DIR/sys.pid"

  nohup ffmpeg -hide_banner -loglevel warning \
    -f avfoundation -thread_queue_size 2048 \
    -i ":${MIC_INDEX}" \
    -ac 2 -ar 48000 -c:a pcm_s16le -y "$work/mic.wav" \
    >"$work/mic.log" 2>&1 &
  printf '%s\n' "$!" >"$STATE_DIR/mic.pid"

  sleep 0.8
  local sys_ok=0 mic_ok=0
  if pid_alive "$STATE_DIR/sys.pid"; then sys_ok=1; fi
  if pid_alive "$STATE_DIR/mic.pid"; then mic_ok=1; fi
  if [[ "$sys_ok" -eq 0 && "$mic_ok" -eq 0 ]]; then
    local sys_log mic_log
    sys_log="$(tail -n 8 "$work/system.log" 2>/dev/null || true)"
    mic_log="$(tail -n 8 "$work/mic.log" 2>/dev/null || true)"
    rm -f "$STATE_DIR/started_at"
    fail "录音进程没有留下来。系统音频：${sys_log} 麦克风：${mic_log}"
  fi
  if [[ "$sys_ok" -eq 0 ]]; then
    note "系统音频这一路没有启动，目前只在录麦克风。停止时会保存已有的声音。日志：$(tail -n 4 "$work/system.log" 2>/dev/null || true)"
  fi
  if [[ "$mic_ok" -eq 0 ]]; then
    note "麦克风这一路没有启动，目前只在录系统音频。请允许终端或 SwiftBar 使用麦克风。日志：$(tail -n 4 "$work/mic.log" 2>/dev/null || true)"
  fi
  printf '%s\n' "开始录音 → $out"
  printf '%s\n' "麦克风：[$MIC_INDEX] $MIC_NAME"
  printf '%s\n' "系统音频：[$SYS_INDEX] $SYS_NAME"
}

cmd_stop() {
  local state
  state="$(current_state)"
  if [[ "$state" == "idle" ]]; then
    printf '%s\n' "没有正在进行的录音。"
    exit 0
  fi
  acquire_lock
  stop_pid_file "$STATE_DIR/sys.pid"
  stop_pid_file "$STATE_DIR/mic.pid"
  finalize
}

cmd_toggle() {
  local state
  state="$(current_state)"
  if [[ "$state" == "recording" || "$state" == "stale" ]]; then
    cmd_stop
  else
    cmd_start
  fi
}

cmd_open() {
  mkdir -p "$RECORDINGS_DIR"
  open "$RECORDINGS_DIR"
}

cmd_reveal() {
  local last
  last="$(cat "$STATE_DIR/last_output" 2>/dev/null || true)"
  if [[ -n "$last" && -e "$last" ]]; then
    open -R "$last"
  else
    cmd_open
  fi
}

cmd_audio_midi() {
  open -a "Audio MIDI Setup" \
    || open "/System/Applications/Utilities/Audio MIDI Setup.app" \
    || open "/System/Applications/Utilities/音频 MIDI 设置.app" \
    || fail "没有打开「音频 MIDI 设置」。请用聚焦搜索打开它。"
}

cmd_self_test() {
  local fixture choice mic_idx mic_name sys_idx sys_name
  fixture="$SCRIPT_DIR/fixtures/avfoundation-devices.txt"
  [[ -f "$fixture" ]] || fail "缺少夹具：$fixture"
  choice="$(parse_avfoundation_audio <"$fixture" | choose_devices)"
  mic_idx="$(printf '%s\n' "$choice" | sed -n '1p')"
  mic_name="$(printf '%s\n' "$choice" | sed -n '2p')"
  sys_idx="$(printf '%s\n' "$choice" | sed -n '3p')"
  sys_name="$(printf '%s\n' "$choice" | sed -n '4p')"
  [[ "$mic_idx" == "0" ]] || fail "self-test mic index: $mic_idx"
  [[ "$mic_name" == "MacBook Pro Microphone" ]] || fail "self-test mic name: $mic_name"
  [[ "$sys_idx" == "1" ]] || fail "self-test blackhole index: $sys_idx"
  [[ "$sys_name" == "BlackHole 2ch" ]] || fail "self-test blackhole name: $sys_name"

  choice="$(printf '%s\n' '[AVFoundation indev @ 0x1] AVFoundation audio devices:
[AVFoundation indev @ 0x1] [0] BlackHole 16ch
[AVFoundation indev @ 0x1] [1] MacBook Pro麦克风' | parse_avfoundation_audio | choose_devices)"
  mic_idx="$(printf '%s\n' "$choice" | sed -n '1p')"
  sys_idx="$(printf '%s\n' "$choice" | sed -n '3p')"
  [[ "$mic_idx" == "1" ]] || fail "self-test zh mic index: $mic_idx"
  [[ "$sys_idx" == "0" ]] || fail "self-test 16ch index: $sys_idx"
  printf '%s\n' "self-test ok"
}

command_name="${1:-status}"
case "$command_name" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  toggle) cmd_toggle ;;
  status) cmd_status ;;
  devices) cmd_devices ;;
  open) cmd_open ;;
  reveal) cmd_reveal ;;
  audio-midi) cmd_audio_midi ;;
  self-test) cmd_self_test ;;
  -h|--help|help) usage ;;
  *)
    usage >&2
    exit 2
    ;;
esac
