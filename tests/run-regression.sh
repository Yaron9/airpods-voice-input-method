#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
bridge="$project_dir/build/AirPods Siri Voice Bridge.app/Contents/MacOS/airpods-siri-voice-bridge"
result_dir=/tmp/airpods-fn-test/regression
installed_app=${AIRPODS_BRIDGE_TEST_INSTALLED_APP:-"$HOME/Applications/AirPods Siri Voice Bridge Regression.app"}
production_app="/Applications/AirPods Siri Voice Bridge.app"
production_executable="$production_app/Contents/MacOS/airpods-siri-voice-bridge"
production_pattern='^/Applications/AirPods Siri Voice Bridge[.]app/Contents/MacOS/airpods-siri-voice-bridge$'
production_was_running=false
if [[ "${installed_app:t}" != "AirPods Siri Voice Bridge Regression.app" ]]; then
  echo "Refusing non-regression app path: $installed_app" >&2
  exit 1
fi
cleanup_regression_app() {
  [[ ! -e "$installed_app" ]] || rm -rf -- "$installed_app"
  if $production_was_running && [[ -x "$production_executable" ]]; then
    open "$production_app"
  fi
}
trap cleanup_regression_app EXIT
cleanup_regression_app
mkdir -p "$result_dir"
launchctl remove com.metame.airpods-siri-voice-bridge 2>/dev/null || true

if pgrep -f "$production_pattern" >/dev/null; then
  production_was_running=true
  print -n > /tmp/airpods-fn-test/stop.request
  for _ in {1..30}; do
    pgrep -f "$production_pattern" >/dev/null || break
    sleep 0.1
  done
  if pgrep -f "$production_pattern" >/dev/null; then
    echo "TEST SETUP FAILED: installed production app did not stop gracefully" >&2
    exit 1
  fi
fi

"$project_dir/scripts/build.sh" >/dev/null
swiftc "$project_dir/tests/select-wetype.swift" -framework Carbon \
  -o "$result_dir/select-wetype"
swiftc "$project_dir/tests/return-key-receiver.swift" -framework AppKit \
  -o "$result_dir/return-key-receiver"
"$bridge" --parser-test
"$bridge" --permission-recovery-test

"$bridge" --cycle-test >"$result_dir/two-cycle.log" 2>&1
if [[ $(rg -c 'AirPods Siri invocation received' "$result_dir/two-cycle.log") != 2 ]] \
  || [[ $(rg -c 'Voice key fn down' "$result_dir/two-cycle.log") != 2 ]] \
  || [[ $(rg -c 'reason=AirPods single press' "$result_dir/two-cycle.log") != 2 ]]; then
  echo "TWO-CYCLE FAILED: controller did not reset for a second voice interaction" >&2
  exit 1
fi

osascript -e 'tell application "TextEdit" to activate'
sleep 0.5
"$result_dir/select-wetype"
test_start=$(date '+%Y-%m-%d %H:%M:%S')
"$bridge" --self-test >"$result_dir/bridge.log" 2>&1
sleep 0.5
/usr/bin/log show --start "$test_start" --style compact \
  --predicate 'process == "WeType"' >"$result_dir/wetype.log"

rg -q 'AirPods Siri invocation received' "$result_dir/bridge.log"
rg -q 'voiceKey=fn' "$result_dir/bridge.log"
rg -q 'Voice key fn down' "$result_dir/bridge.log"
rg -q 'Media remote stop controls active' "$result_dir/bridge.log"
rg -q 'AirPods single press received; recording=true' "$result_dir/bridge.log"
rg -q 'reason=AirPods single press' "$result_dir/bridge.log"
rg -q 'Media remote stop controls inactive' "$result_dir/bridge.log"
rg -q 'Voice key fn up' "$result_dir/bridge.log"
rg -q 'AVCaptureSession_Tundra startRunning' "$result_dir/wetype.log"
rg -q 'AVCaptureSession_Tundra stopRunning' "$result_dir/wetype.log"

return_marker="$result_dir/return.received"
receiver_ready="$result_dir/return-receiver.ready"
[[ -e "$return_marker" ]] && unlink "$return_marker"
[[ -e "$receiver_ready" ]] && unlink "$receiver_ready"
"$result_dir/return-key-receiver" "$return_marker" "$receiver_ready" \
  >"$result_dir/return-receiver.log" 2>&1 &
receiver_pid=$!
for _ in {1..30}; do
  [[ -e "$receiver_ready" ]] && break
  sleep 0.1
done
"$bridge" --return-test >"$result_dir/return-delivery.log" 2>&1
for _ in {1..20}; do
  [[ -e "$return_marker" ]] && break
  sleep 0.1
done
if [[ ! -e "$return_marker" ]]; then
  kill "$receiver_pid" 2>/dev/null || true
  for _ in {1..10}; do
    kill -0 "$receiver_pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL "$receiver_pid" 2>/dev/null || true
  wait "$receiver_pid" 2>/dev/null || true
  echo "RETURN DELIVERY FAILED: frontmost application did not receive commit + send Return sequence" >&2
  exit 1
fi
wait "$receiver_pid"

"$bridge" --voice-key option --self-test >"$result_dir/configurable-key.log" 2>&1
rg -q 'voiceKey=option' "$result_dir/configurable-key.log"
rg -q 'Voice key option down' "$result_dir/configurable-key.log"
rg -q 'Voice key option up' "$result_dir/configurable-key.log"

graceful_stop_request="$result_dir/graceful-stop.request"
[[ -e "$graceful_stop_request" ]] && unlink "$graceful_stop_request"
AIRPODS_BRIDGE_STOP_REQUEST_PATH="$graceful_stop_request" \
  "$bridge" --self-test >"$result_dir/graceful-stop.log" 2>&1 &
test_pid=$!
for _ in {1..50}; do
  rg -q 'Voice key fn down' "$result_dir/graceful-stop.log" && break
  sleep 0.1
done
print -n > "$graceful_stop_request"
wait "$test_pid"
rg -q 'Voice key fn up' "$result_dir/graceful-stop.log"
if rg -q 'Return key posted' "$result_dir/graceful-stop.log"; then
  echo "SUBMIT SAFETY FAILED: graceful shutdown posted Return" >&2
  exit 1
fi

launch_stop_request="$result_dir/launch-stop.request"
print -n > "$launch_stop_request"
AIRPODS_BRIDGE_STOP_REQUEST_PATH="$launch_stop_request" \
  "$bridge" >"$result_dir/launch-stop.log" 2>&1 &
launch_pid=$!
for _ in {1..30}; do
  kill -0 "$launch_pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$launch_pid" 2>/dev/null; then
  kill "$launch_pid"
  wait "$launch_pid" 2>/dev/null || true
  echo "LAUNCH RACE FAILED: bridge ignored a stop request present during launch" >&2
  exit 1
fi
wait "$launch_pid"
rg -q 'Graceful stop requested' "$result_dir/launch-stop.log"

foreign_app="$result_dir/foreign/AirPods Siri Voice Bridge.app"
mkdir -p "${foreign_app:h}"
ditto "$project_dir/build/AirPods Siri Voice Bridge.app" "$foreign_app"
foreign_bridge="$foreign_app/Contents/MacOS/airpods-siri-voice-bridge"
"$foreign_bridge" >"$result_dir/foreign.log" 2>&1 &
foreign_pid=$!
print -r -- "$foreign_pid" > /tmp/airpods-fn-test/bridge.pid
sleep 0.3
start_result=$("$project_dir/scripts/start.sh")
if [[ "$start_result" != "Bridge already running (PID $foreign_pid)" ]]; then
  print -n > /tmp/airpods-fn-test/stop.request
  for _ in {1..30}; do
    kill -0 "$foreign_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$foreign_pid" 2>/dev/null; then
    kill "$foreign_pid"
  fi
  wait "$foreign_pid" 2>/dev/null || true
  echo "SINGLETON FAILED: start.sh did not reuse the foreign bridge" >&2
  exit 1
fi
"$project_dir/scripts/stop.sh" >/dev/null

# Start a downloaded/temporary copy, then start the installed copy directly.
# The installed copy must take over and close the lower-priority copy.
ditto "$project_dir/build/AirPods Siri Voice Bridge.app" "$installed_app"
codesign --verify --strict "$installed_app"
"$foreign_bridge" >"$result_dir/lower-priority-copy.log" 2>&1 &
lower_priority_pid=$!
sleep 0.3
installed_bridge="$installed_app/Contents/MacOS/airpods-siri-voice-bridge"
"$installed_bridge" --voice-key fn >"$result_dir/preferred-copy.log" 2>&1 &
preferred_pid=$!
for _ in {1..30}; do
  kill -0 "$lower_priority_pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$lower_priority_pid" 2>/dev/null; then
  print -n > /tmp/airpods-fn-test/stop.request
  wait "$lower_priority_pid" 2>/dev/null || true
  wait "$preferred_pid" 2>/dev/null || true
  echo "APP SINGLETON FAILED: installed app did not close the temporary copy" >&2
  exit 1
fi
wait "$lower_priority_pid"
print -n > /tmp/airpods-fn-test/stop.request
wait "$preferred_pid"
rg -q 'Closing lower-priority app copy' "$result_dir/preferred-copy.log"

echo "REGRESSION PASSED: AirPods long press -> Siri release -> HID Fn hold -> AirPods single press stop"
echo "RETURN DELIVERY PASSED: frontmost application received commit + send Return sequence"
echo "CONFIGURABLE KEY PASSED: non-Fn option key performed down/up lifecycle"
echo "LIFECYCLE PASSED: stop request during Fn-down performs graceful Fn-up cleanup"
echo "LAUNCH RACE PASSED: a stop request present during launch is honored"
echo "SINGLETON PASSED: a bridge from another checkout is reused, not duplicated"
echo "APP SINGLETON PASSED: installed app closes downloaded or temporary copies"
echo "TWO-CYCLE PASSED: one process completes two consecutive voice interactions"
