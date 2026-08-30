#!/bin/zsh
set -euo pipefail

runtime_dir=/tmp/airpods-fn-test
bridge_log="$runtime_dir/siri-bridge.log"
result_dir="$runtime_dir/hitl-two-cycle"
bridge_capture="$result_dir/bridge.log"
system_capture="$result_dir/system.log"
latency_timeout_tenths=25
human_timeout_tenths=3000

mkdir -p "$result_dir"
: > "$bridge_capture"
: > "$system_capture"
initial_size=$(stat -f %z "$bridge_log" 2>/dev/null || echo 0)

/usr/bin/log stream --style compact --level debug \
  --predicate '(process == "Siri" AND eventMessage CONTAINS[c] "BluetoothHFP") OR (process == "WeType" AND eventMessage CONTAINS[c] "AVCaptureSession_Tundra")' \
  > "$system_capture" 2>/dev/null &
stream_pid=$!

cleanup() {
  kill "$stream_pid" 2>/dev/null || true
  wait "$stream_pid" 2>/dev/null || true
  if [[ -f "$bridge_log" ]]; then
    tail -c "+$((initial_size + 1))" "$bridge_log" > "$bridge_capture"
  fi
}
trap cleanup EXIT

count_bridge() {
  local pattern=$1
  local count=0
  if [[ -f "$bridge_log" ]]; then
    count=$(tail -c "+$((initial_size + 1))" "$bridge_log" | rg -c "$pattern" || true)
  fi
  print -r -- "${count:-0}"
}

count_system() {
  local pattern=$1
  local count
  count=$(rg -c "$pattern" "$system_capture" || true)
  print -r -- "${count:-0}"
}

wait_for_count() {
  local source=$1
  local pattern=$2
  local expected=$3
  local timeout_tenths=$4
  local failure=$5
  local actual=0
  local attempt
  for ((attempt = 0; attempt < timeout_tenths; attempt++)); do
    if [[ "$source" == bridge ]]; then
      actual=$(count_bridge "$pattern")
    else
      actual=$(count_system "$pattern")
    fi
    (( actual >= expected )) && return 0
    sleep 0.1
  done
  print -u2 -- "RED: $failure (expected=$expected actual=$actual)"
  cleanup
  trap - EXIT
  print -u2 -- "Bridge trace: $bridge_capture"
  print -u2 -- "System trace: $system_capture"
  exit 1
}

run_round() {
  local round=$1
  local invocation_before
  local fn_before
  local stop_before
  local send_before
  local wetype_before
  invocation_before=$(count_bridge 'AirPods Siri invocation received')
  fn_before=$(count_bridge 'Voice key fn down')
  stop_before=$(count_bridge 'reason=AirPods single press')
  send_before=$(count_bridge 'stage=send; voice input submitted')

  print -- "ROUND $round READY: 请长按 AirPods 左耳并开始说话。"
  wait_for_count bridge 'AirPods Siri invocation received' "$((invocation_before + 1))" \
    "$human_timeout_tenths" "第 $round 轮没有收到 AirPods 启动事件"
  # Take the WeType baseline only after this round's AirPods event. This prevents
  # keyboard-Fn dictation used to communicate during HITL from creating a false pass.
  wetype_before=$(count_system 'AVCaptureSession_Tundra startRunning')
  wait_for_count bridge 'Voice key fn down' "$((fn_before + 1))" \
    50 "第 $round 轮收到 AirPods 事件，但没有按下 Fn"
  wait_for_count system 'AVCaptureSession_Tundra startRunning' "$((wetype_before + 1))" \
    "$latency_timeout_tenths" "第 $round 轮 Fn 已按下，但微信语音输入未在 2.5 秒内启动"

  print -- "ROUND $round RECORDING: 现在单击 AirPods 停止并发送。"
  wait_for_count bridge 'reason=AirPods single press' "$((stop_before + 1))" \
    "$human_timeout_tenths" "第 $round 轮没有通过 AirPods 单击停止"
  wait_for_count bridge 'stage=send; voice input submitted' "$((send_before + 1))" \
    20 "第 $round 轮停止后没有自动发送"
  print -- "ROUND $round GREEN"
}

print -- "HITL READY: 两轮实体 AirPods 测试开始；每轮语音启动上限 2.5 秒。"
run_round 1
sleep 1
run_round 2
print -- "TWO-CYCLE HITL PASSED: 两轮均快速启动、单击停止并自动发送。"
