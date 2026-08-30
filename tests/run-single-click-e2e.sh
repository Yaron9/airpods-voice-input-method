#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
result_dir=/tmp/airpods-fn-test/single-click-e2e
bridge="$project_dir/build/AirPods Siri Voice Bridge.app/Contents/MacOS/airpods-siri-voice-bridge"
marker="$result_dir/return-cycles.log"
ready="$result_dir/receiver.ready"
expected_cycles=4

mkdir -p "$result_dir"
rm -f -- "$marker" "$ready"
"$project_dir/scripts/build.sh" >/dev/null
swiftc "$project_dir/tests/return-key-receiver.swift" -framework AppKit \
  -o "$result_dir/return-key-receiver"

osascript -e 'tell application "TextEdit" to activate'
sleep 0.3
"$result_dir/return-key-receiver" "$marker" "$ready" "$expected_cycles" \
  >"$result_dir/receiver.log" 2>&1 &
receiver_pid=$!
cleanup() {
  kill "$receiver_pid" 2>/dev/null || true
  wait "$receiver_pid" 2>/dev/null || true
}
trap cleanup EXIT
for _ in {1..30}; do
  [[ -e "$ready" ]] && break
  sleep 0.1
done
[[ -e "$ready" ]] || { print -u2 -- "SINGLE CLICK RED: receiver not ready"; exit 1; }

"$bridge" --single-click-cycle-test >"$result_dir/bridge.log" 2>&1
sent=$(wc -l < "$marker" 2>/dev/null || echo 0)
downs=$(rg -c 'Voice key fn down' "$result_dir/bridge.log" || true)
ups=$(rg -c 'Voice key fn up; voice input stopped' "$result_dir/bridge.log" || true)
siri=$(rg -c 'Siri invocation|Siri Escape|DoAP|Siri host' "$result_dir/bridge.log" || true)
if (( sent != expected_cycles || downs != expected_cycles \
      || ups != expected_cycles || siri != 0 )); then
  print -u2 -- "SINGLE CLICK RED: expected=$expected_cycles sent=$sent fnDown=$downs fnUp=$ups siri=$siri"
  exit 1
fi

wait "$receiver_pid"
receiver_pid=0
trap - EXIT
print -- "SINGLE CLICK GREEN: four click-to-start/click-to-send rounds completed without Siri"
