#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
result_dir=/tmp/airpods-voice-input-method/e2e
app="$project_dir/build/AirPods Voice 输入法.app/Contents/MacOS/airpods-voice-input-method"
expected_cycles=4
marker="$result_dir/return-cycles.log"
ready="$result_dir/receiver.ready"
receiver="$result_dir/return-key-receiver"
receiver_pid=""

cleanup() {
  if [[ "$receiver_pid" == <-> ]] && kill -0 "$receiver_pid" 2>/dev/null; then
    kill "$receiver_pid" 2>/dev/null || true
    wait "$receiver_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p "$result_dir"
[[ ! -e "$marker" ]] || unlink "$marker"
[[ ! -e "$ready" ]] || unlink "$ready"
"$project_dir/scripts/build.sh" >/dev/null
swiftc "$project_dir/tests/return-key-receiver.swift" -framework AppKit -o "$receiver"

"$receiver" "$marker" "$ready" "$expected_cycles" >"$result_dir/receiver.log" 2>&1 &
receiver_pid=$!
for _ in {1..40}; do
  [[ -e "$ready" ]] && break
  sleep 0.1
done
if [[ ! -e "$ready" ]]; then
  print -u2 -- "E2E RED: Return receiver could not become frontmost"
  exit 1
fi

"$app" --single-click-cycle-test >"$result_dir/app.log" 2>&1
downs=$(rg -c 'Voice key fn down' "$result_dir/app.log" || true)
ups=$(rg -c 'Voice key fn up; voice input stopped' "$result_dir/app.log" || true)
commits=$(rg -c 'Return key posted; stage=commit' "$result_dir/app.log" || true)
sends=$(rg -c 'Return key posted; stage=send' "$result_dir/app.log" || true)
received_cycles=0
[[ ! -f "$marker" ]] || received_cycles=$(wc -l < "$marker")
if (( downs != expected_cycles || ups != expected_cycles \
      || commits != expected_cycles || sends != expected_cycles \
      || received_cycles != expected_cycles )); then
  print -u2 -- "E2E RED: expected=$expected_cycles fnDown=$downs fnUp=$ups commits=$commits sends=$sends received=$received_cycles"
  exit 1
fi
wait "$receiver_pid"
receiver_pid=""
print -- "E2E GREEN: four click-to-start/click-to-send rounds completed"
