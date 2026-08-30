#!/bin/zsh
set -euo pipefail

runtime_dir=/tmp/airpods-voice-input-method
app_log="$runtime_dir/app.log"
result_dir="$runtime_dir/hitl-two-cycle"
app_capture="$result_dir/app.log"
system_capture="$result_dir/system.log"
human_timeout_tenths=3000

mkdir -p "$result_dir"
: > "$app_capture"
: > "$system_capture"
initial_size=$(stat -f %z "$app_log" 2>/dev/null || echo 0)

/usr/bin/log stream --style compact --level debug \
  --predicate 'process == "WeType" AND eventMessage CONTAINS[c] "AVCaptureSession_Tundra"' \
  > "$system_capture" 2>/dev/null &
stream_pid=$!

cleanup() {
  kill "$stream_pid" 2>/dev/null || true
  wait "$stream_pid" 2>/dev/null || true
  if [[ -f "$app_log" ]]; then
    tail -c "+$((initial_size + 1))" "$app_log" > "$app_capture"
  fi
}
trap cleanup EXIT

count_app() {
  local pattern=$1
  local count=0
  if [[ -f "$app_log" ]]; then
    count=$(tail -c "+$((initial_size + 1))" "$app_log" | rg -c "$pattern" || true)
  fi
  print -r -- "${count:-0}"
}

wait_for_app_count() {
  local pattern=$1
  local expected=$2
  local timeout_tenths=$3
  local failure=$4
  local actual=0
  for ((attempt = 0; attempt < timeout_tenths; attempt++)); do
    actual=$(count_app "$pattern")
    (( actual >= expected )) && return 0
    sleep 0.1
  done
  print -u2 -- "RED: $failure (expected=$expected actual=$actual)"
  cleanup
  trap - EXIT
  print -u2 -- "App trace: $app_capture"
  print -u2 -- "System trace: $system_capture"
  exit 1
}

run_round() {
  local round=$1
  local bluetooth_before down_before up_before send_before
  bluetooth_before=$(count_app 'Bluetooth media remote command received')
  down_before=$(count_app 'Voice key fn down')
  up_before=$(count_app 'Voice key fn up; voice input stopped')
  send_before=$(count_app 'stage=send; voice input submitted')

  print -- "ROUND $round READY: 请单击一次 AirPods 开始说话。"
  wait_for_app_count 'Bluetooth media remote command received' "$((bluetooth_before + 1))" \
    "$human_timeout_tenths" "第 $round 轮没有收到 bluetoothd 单击"
  wait_for_app_count 'Voice key fn down' "$((down_before + 1))" 25 \
    "第 $round 轮收到 AirPods 单击，但 2.5 秒内没有按下 Fn"

  print -- "ROUND $round RECORDING: 请再单击一次 AirPods 停止并发送。"
  wait_for_app_count 'Bluetooth media remote command received' "$((bluetooth_before + 2))" \
    "$human_timeout_tenths" "第 $round 轮没有收到停止单击"
  wait_for_app_count 'Voice key fn up; voice input stopped' "$((up_before + 1))" 25 \
    "第 $round 轮停止单击后没有释放 Fn"
  wait_for_app_count 'stage=send; voice input submitted' "$((send_before + 1))" 25 \
    "第 $round 轮停止后没有自动发送"
  print -- "ROUND $round GREEN"
}

print -- "HITL READY: AirPods Voice 输入法两轮实体测试开始。"
run_round 1
sleep 1
run_round 2
cleanup
trap - EXIT

print -- "HITL PASSED: 两轮均由 bluetoothd 单击启动、停止并发送。"
