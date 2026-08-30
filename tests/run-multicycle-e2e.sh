#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
result_dir=/tmp/airpods-fn-test/multicycle-e2e
bridge="$project_dir/build/AirPods Siri Voice Bridge.app/Contents/MacOS/airpods-siri-voice-bridge"
marker="$result_dir/return-cycles.log"
ready="$result_dir/receiver.ready"
expected_cycles=4
receiver_pid=""

cleanup() {
  if [[ "$receiver_pid" == <-> ]] && kill -0 "$receiver_pid" 2>/dev/null; then
    kill "$receiver_pid" 2>/dev/null || true
    wait "$receiver_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p "$result_dir"
[[ -e "$marker" ]] && unlink "$marker"
[[ -e "$ready" ]] && unlink "$ready"
"$project_dir/scripts/build.sh" >/dev/null
swiftc "$project_dir/tests/select-wetype.swift" -framework Carbon \
  -o "$result_dir/select-wetype"
swiftc "$project_dir/tests/return-key-receiver.swift" -framework AppKit \
  -o "$result_dir/return-key-receiver"

osascript -e 'tell application "TextEdit" to activate'
sleep 0.3
"$result_dir/select-wetype"
"$result_dir/return-key-receiver" "$marker" "$ready" "$expected_cycles" \
  >"$result_dir/receiver.log" 2>&1 &
receiver_pid=$!
for _ in {1..30}; do
  [[ -e "$ready" ]] && break
  sleep 0.1
done
[[ -e "$ready" ]] || { print -u2 -- "MULTICYCLE RED: receiver was not ready"; exit 1; }

test_start=$(date '+%Y-%m-%d %H:%M:%S')
"$bridge" --cycle-test >"$result_dir/bridge.log" 2>&1
sleep 0.5
/usr/bin/log show --start "$test_start" --style compact \
  --predicate 'process == "WeType"' >"$result_dir/wetype.log"

if [[ -f "$marker" ]]; then
  completed_cycles=$(wc -l < "$marker")
else
  completed_cycles=0
fi
bridge_starts=$(rg -c 'Voice key fn down' "$result_dir/bridge.log" || true)
bridge_stops=$(rg -c 'Voice key fn up; voice input stopped' "$result_dir/bridge.log" || true)
wetype_starts=$(rg -c 'AVCaptureSession_Tundra startRunning' "$result_dir/wetype.log" || true)
wetype_stops=$(rg -c 'AVCaptureSession_Tundra stopRunning' "$result_dir/wetype.log" || true)

if (( completed_cycles != expected_cycles \
      || bridge_starts != expected_cycles \
      || bridge_stops != expected_cycles \
      || wetype_starts < expected_cycles \
      || wetype_stops < expected_cycles )); then
  print -u2 -- "MULTICYCLE RED: expected=$expected_cycles sent=$completed_cycles fnDown=$bridge_starts fnUp=$bridge_stops weTypeStart=$wetype_starts weTypeStop=$wetype_stops"
  exit 1
fi

wait "$receiver_pid"
receiver_pid=""
print -- "MULTICYCLE GREEN: $expected_cycles rounds started WeType, stopped, and submitted"
