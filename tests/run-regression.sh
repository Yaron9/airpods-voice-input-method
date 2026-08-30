#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
bridge="$project_dir/build/AirPods Siri Voice Bridge.app/Contents/MacOS/airpods-siri-voice-bridge"
result_dir=/tmp/airpods-fn-test/regression
installed_app=${AIRPODS_BRIDGE_TEST_INSTALLED_APP:-"$HOME/Applications/AirPods Siri Voice Bridge Regression.app"}
production_app="/Applications/AirPods Siri Voice Bridge.app"
production_executable="$production_app/Contents/MacOS/airpods-siri-voice-bridge"
production_pattern='^/Applications/AirPods Siri Voice Bridge[.]app/Contents/MacOS/airpods-siri-voice-bridge( |$)'
production_was_running=false
production_was_launchd_managed=false
if [[ "${installed_app:t}" != "AirPods Siri Voice Bridge Regression.app" ]]; then
  echo "Refusing non-regression app path: $installed_app" >&2
  exit 1
fi
cleanup_regression_app() {
  [[ ! -e "$installed_app" ]] || rm -rf -- "$installed_app"
  if $production_was_running && [[ -x "$production_executable" ]]; then
    if $production_was_launchd_managed; then
      "$project_dir/scripts/start.sh" >/dev/null
    else
      open "$production_app"
    fi
  fi
}
trap cleanup_regression_app EXIT
cleanup_regression_app
mkdir -p "$result_dir"

if pgrep -f "$production_pattern" >/dev/null; then
  production_was_running=true
  production_pid=$(pgrep -f "$production_pattern" | head -n 1)
  production_launchd_pid=$(launchctl print "gui/$(id -u)/com.metame.airpods-siri-voice-bridge" 2>/dev/null \
    | awk '/^[[:space:]]*pid = [0-9]+/ { print $3; exit }' || true)
  if [[ "$production_launchd_pid" == "$production_pid" ]]; then
    production_was_launchd_managed=true
    "$project_dir/scripts/stop.sh" >/dev/null
  else
    print -n > /tmp/airpods-fn-test/stop.request
    for _ in {1..30}; do
      pgrep -f "$production_pattern" >/dev/null || break
      sleep 0.1
    done
  fi
  if pgrep -f "$production_pattern" >/dev/null; then
    echo "TEST SETUP FAILED: installed production app did not stop gracefully" >&2
    exit 1
  fi
fi
launchctl remove com.metame.airpods-siri-voice-bridge 2>/dev/null || true

"$project_dir/scripts/build.sh" >/dev/null
swiftc "$project_dir/tests/select-wetype.swift" -framework Carbon \
  -o "$result_dir/select-wetype"
swiftc "$project_dir/tests/return-key-receiver.swift" -framework AppKit \
  -o "$result_dir/return-key-receiver"
"$bridge" --parser-test
"$bridge" --permission-recovery-test
"$bridge" --siri-reset-failure-test >"$result_dir/siri-reset-failure.log" 2>&1
rg -q 'Voice input start aborted; replacement Siri host was not ready' \
  "$result_dir/siri-reset-failure.log"
if rg -q 'Voice key .* down' "$result_dir/siri-reset-failure.log"; then
  echo "SIRI RESET FAILURE TEST FAILED: voice input started without a ready Siri host" >&2
  exit 1
fi
"$bridge" --stop-start-during-submit-test >"$result_dir/stop-start-during-submit.log" 2>&1
if [[ $(rg -c 'Voice key fn down' "$result_dir/stop-start-during-submit.log") != 2 ]]; then
  echo "STOP-START DURING SUBMIT TEST FAILED: stale per-session state blocked the second start" >&2
  exit 1
fi

"$project_dir/tests/run-multicycle-e2e.sh"
multicycle_log=/tmp/airpods-fn-test/multicycle-e2e/bridge.log
if [[ $(rg -c 'AirPods Siri invocation received' "$multicycle_log") != 4 ]] \
  || [[ $(rg -c 'Voice key fn down' "$multicycle_log") != 4 ]] \
  || [[ $(rg -c 'reason=AirPods single press' "$multicycle_log") != 4 ]]; then
  echo "MULTI-CYCLE FAILED: controller did not complete four voice interactions" >&2
  exit 1
fi

osascript -e 'tell application "TextEdit" to activate'
sleep 0.5
"$result_dir/select-wetype"
test_start=$(date '+%Y-%m-%d %H:%M:%S')
open -gj -a Siri
sleep 0.3
siri_pid_before=$(pgrep -x Siri | head -n 1)
"$bridge" --self-test >"$result_dir/bridge.log" 2>&1
siri_pid_after=$(pgrep -x Siri | head -n 1)
sleep 0.5
/usr/bin/log show --start "$test_start" --style compact \
  --predicate 'process == "WeType"' >"$result_dir/wetype.log"

rg -q 'AirPods Siri invocation received' "$result_dir/bridge.log"
rg -q 'Siri host restarted and prewarmed; hostReady=true' "$result_dir/bridge.log"
if [[ -z "$siri_pid_before" || -z "$siri_pid_after" \
      || "$siri_pid_before" == "$siri_pid_after" ]]; then
  echo "SIRI SESSION RESET FAILED: host was not replaced and prewarmed" >&2
  exit 1
fi
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

siri_stop_marker="$result_dir/siri-stop-return.received"
siri_stop_ready="$result_dir/siri-stop-receiver.ready"
[[ -e "$siri_stop_marker" ]] && unlink "$siri_stop_marker"
[[ -e "$siri_stop_ready" ]] && unlink "$siri_stop_ready"
"$result_dir/return-key-receiver" "$siri_stop_marker" "$siri_stop_ready" \
  >"$result_dir/siri-stop-receiver.log" 2>&1 &
siri_stop_receiver_pid=$!
for _ in {1..30}; do
  [[ -e "$siri_stop_ready" ]] && break
  sleep 0.1
done
"$bridge" --siri-stop-test >"$result_dir/siri-stop-delivery.log" 2>&1
for _ in {1..20}; do
  [[ -e "$siri_stop_marker" ]] && break
  sleep 0.1
done
if [[ ! -e "$siri_stop_marker" ]]; then
  kill "$siri_stop_receiver_pid" 2>/dev/null || true
  wait "$siri_stop_receiver_pid" 2>/dev/null || true
  echo "SIRI STOP SUBMIT FAILED: Siri-routed AirPods stop did not send Return" >&2
  exit 1
fi
wait "$siri_stop_receiver_pid"

"$bridge" --long-press-stop-test >"$result_dir/long-press-stop.log" 2>&1
rg -q 'Voice key fn up; voice input stopped' "$result_dir/long-press-stop.log"
if rg -q 'Return key posted' "$result_dir/long-press-stop.log"; then
  echo "LONG-PRESS SAFETY FAILED: a second long press submitted text" >&2
  exit 1
fi

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
echo "SIRI RESET GUARD PASSED: voice input is blocked until a replacement Siri host is ready"
echo "RETURN DELIVERY PASSED: frontmost application received commit + send Return sequence"
echo "SIRI STOP SUBMIT PASSED: Siri-routed AirPods stop also submitted voice input"
echo "LONG-PRESS SAFETY PASSED: a second long press stopped without submitting"
echo "CONFIGURABLE KEY PASSED: non-Fn option key performed down/up lifecycle"
echo "LIFECYCLE PASSED: stop request during Fn-down performs graceful Fn-up cleanup"
echo "LAUNCH RACE PASSED: a stop request present during launch is honored"
echo "SINGLETON PASSED: a bridge from another checkout is reused, not duplicated"
echo "APP SINGLETON PASSED: installed app closes downloaded or temporary copies"
echo "MULTI-CYCLE PASSED: four rounds each started WeType, stopped, and submitted"
