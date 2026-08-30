#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
app="$project_dir/build/AirPods Voice 输入法.app/Contents/MacOS/airpods-voice-input-method"
result_dir=/tmp/airpods-voice-input-method/regression
installed_app=${AIRPODS_VOICE_INPUT_TEST_APP:-"$HOME/Applications/AirPods Voice 输入法 Regression.app"}
runtime_dir=/tmp/airpods-voice-input-method

if [[ "${installed_app:t}" != "AirPods Voice 输入法 Regression.app" ]]; then
  echo "Refusing non-regression app path: $installed_app" >&2
  exit 1
fi
cleanup() {
  [[ ! -e "$installed_app" ]] || /bin/rm -R -- "$installed_app"
}
trap cleanup EXIT
cleanup
mkdir -p "$result_dir" "$runtime_dir"

"$project_dir/scripts/build.sh" >/dev/null

"$app" --parser-test
"$app" --permission-recovery-test
"$project_dir/tests/run-e2e.sh"

"$app" --self-test >"$result_dir/self-test.log" 2>&1
rg -q 'Voice key fn down' "$result_dir/self-test.log"
rg -q 'Voice key fn up; voice input stopped' "$result_dir/self-test.log"
rg -q 'Return key posted; stage=send' "$result_dir/self-test.log"

"$app" --voice-key option --self-test >"$result_dir/configurable-key.log" 2>&1
rg -q 'voiceKey=option' "$result_dir/configurable-key.log"
rg -q 'Voice key option down' "$result_dir/configurable-key.log"
rg -q 'Voice key option up' "$result_dir/configurable-key.log"

graceful_stop_request="$result_dir/graceful-stop.request"
[[ ! -e "$graceful_stop_request" ]] || unlink "$graceful_stop_request"
AIRPODS_VOICE_INPUT_STOP_REQUEST_PATH="$graceful_stop_request" \
  "$app" --self-test >"$result_dir/graceful-stop.log" 2>&1 &
test_pid=$!
for _ in {1..50}; do
  rg -q 'Voice key fn down' "$result_dir/graceful-stop.log" && break
  sleep 0.1
done
print -n > "$graceful_stop_request"
wait "$test_pid"
rg -q 'Voice key fn up; graceful shutdown cleanup' "$result_dir/graceful-stop.log"
if rg -q 'Return key posted' "$result_dir/graceful-stop.log"; then
  echo "SUBMIT SAFETY FAILED: graceful shutdown posted Return" >&2
  exit 1
fi

launch_stop_request="$result_dir/launch-stop.request"
print -n > "$launch_stop_request"
AIRPODS_VOICE_INPUT_STOP_REQUEST_PATH="$launch_stop_request" \
  "$app" >"$result_dir/launch-stop.log" 2>&1 &
launch_pid=$!
for _ in {1..30}; do
  kill -0 "$launch_pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$launch_pid" 2>/dev/null; then
  kill "$launch_pid"
  wait "$launch_pid" 2>/dev/null || true
  echo "LAUNCH RACE FAILED: app ignored a stop request present during launch" >&2
  exit 1
fi
wait "$launch_pid"
rg -q 'Graceful stop requested' "$result_dir/launch-stop.log"

foreign_app="$result_dir/foreign/AirPods Voice 输入法.app"
mkdir -p "${foreign_app:h}"
[[ ! -e "$foreign_app" ]] || /bin/rm -R -- "$foreign_app"
ditto "$project_dir/build/AirPods Voice 输入法.app" "$foreign_app"
foreign_executable="$foreign_app/Contents/MacOS/airpods-voice-input-method"
"$foreign_executable" >"$result_dir/foreign.log" 2>&1 &
foreign_pid=$!
print -r -- "$foreign_pid" > "$runtime_dir/app.pid"
sleep 0.3
start_result=$("$project_dir/scripts/start.sh")
if [[ "$start_result" != "AirPods Voice 输入法 already running (PID $foreign_pid)" ]]; then
  print -n > "$runtime_dir/stop.request"
  wait "$foreign_pid" 2>/dev/null || true
  echo "SINGLETON FAILED: start.sh did not reuse the running app" >&2
  exit 1
fi
"$project_dir/scripts/stop.sh" >/dev/null

ditto "$project_dir/build/AirPods Voice 输入法.app" "$installed_app"
codesign --verify --strict "$installed_app"
"$foreign_executable" >"$result_dir/lower-priority-copy.log" 2>&1 &
lower_priority_pid=$!
sleep 0.3
installed_executable="$installed_app/Contents/MacOS/airpods-voice-input-method"
"$installed_executable" --voice-key fn >"$result_dir/preferred-copy.log" 2>&1 &
preferred_pid=$!
for _ in {1..30}; do
  kill -0 "$lower_priority_pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$lower_priority_pid" 2>/dev/null; then
  print -n > "$runtime_dir/stop.request"
  wait "$lower_priority_pid" 2>/dev/null || true
  wait "$preferred_pid" 2>/dev/null || true
  echo "APP SINGLETON FAILED: installed app did not close the temporary copy" >&2
  exit 1
fi
wait "$lower_priority_pid"
print -n > "$runtime_dir/stop.request"
wait "$preferred_pid"
rg -q 'Closing lower-priority app copy' "$result_dir/preferred-copy.log"

echo "REGRESSION PASSED: four voice rounds, Fn lifecycle, send, permissions, launch safety, and singleton behavior"
