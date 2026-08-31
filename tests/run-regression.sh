#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
app="$project_dir/build/AirPods Voice 输入法.app/Contents/MacOS/airpods-voice-input-method"
result_dir=/tmp/airpods-voice-input-method/regression
installed_app=${AIRPODS_VOICE_INPUT_TEST_APP:-"$HOME/Applications/AirPods Voice 输入法 Regression.app"}
runtime_dir=/tmp/airpods-voice-input-method
production_pattern='^/Applications/AirPods Voice 输入法[.]app/Contents/MacOS/airpods-voice-input-method( |$)'

production_pid=$(pgrep -f "$production_pattern" | head -n 1 || true)
if [[ "$production_pid" == <-> ]]; then
  echo "Refusing to run while the production app is active (PID $production_pid); stop it first" >&2
  exit 1
fi

if [[ "${installed_app:t}" != "AirPods Voice 输入法 Regression.app" ]]; then
  echo "Refusing non-regression app path: $installed_app" >&2
  exit 1
fi
cleanup() {
  [[ ! -x "$app" ]] || "$app" --release-fn >/dev/null 2>&1 || true
  [[ ! -e "$installed_app" ]] || /bin/rm -R -- "$installed_app"
}
trap cleanup EXIT
cleanup
mkdir -p "$result_dir" "$runtime_dir"

"$project_dir/scripts/build.sh" >/dev/null

if rg -q 'launchctl submit' "$project_dir/scripts/start.sh"; then
  echo "BACKGROUND LAUNCH FAILED: start.sh still creates a respawning launchctl job" >&2
  exit 1
fi
rg -q '/usr/bin/open -g .*--background-launch' "$project_dir/scripts/start.sh" \
  || { echo "BACKGROUND LAUNCH FAILED: start.sh may steal focus" >&2; exit 1; }
echo "BACKGROUND LAUNCH TEST PASSED: startup cannot respawn or steal focus"

app_icon="$project_dir/build/AirPods Voice 输入法.app/Contents/Resources/AppIcon.icns"
[[ -f "$app_icon" ]] || { echo "APP ICON TEST FAILED: AppIcon.icns is missing" >&2; exit 1; }
[[ "$(plutil -extract CFBundleIconFile raw "$project_dir/build/AirPods Voice 输入法.app/Contents/Info.plist")" == "AppIcon" ]] \
  || { echo "APP ICON TEST FAILED: Info.plist does not reference AppIcon" >&2; exit 1; }
echo "APP ICON TEST PASSED: desktop icon is bundled and referenced"

"$app" --parser-test
"$app" --permission-recovery-test
"$app" --status-icon-test
"$app" --status-visibility-test
"$app" --keyboard-monitor-unavailable-test >"$result_dir/monitor-fallback.log" 2>&1
rg -q 'ready in replay mode' "$result_dir/monitor-fallback.log"
rg -q 'Keyboard recovery monitor unavailable; continuing with Fn watchdog protection' \
  "$result_dir/monitor-fallback.log"
"$app" --voice-key option --keyboard-monitor-unavailable-test \
  >"$result_dir/monitor-required.log" 2>&1
rg -q 'Keyboard recovery monitor is required for non-Fn modifier safety' \
  "$result_dir/monitor-required.log"
if rg -q 'ready in replay mode' "$result_dir/monitor-required.log"; then
  echo "MONITOR SAFETY FAILED: non-Fn modifier started without keyboard recovery" >&2
  exit 1
fi
"$project_dir/tests/run-e2e.sh"
"$project_dir/tests/run-keyboard-safety.sh"

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
show_count_before=$(rg -c 'Control window shown' "$result_dir/foreign.log" || true)
start_result=$("$project_dir/scripts/start.sh")
if [[ "$start_result" != "AirPods Voice 输入法 already running (PID $foreign_pid)" ]]; then
  print -n > "$runtime_dir/stop.request"
  wait "$foreign_pid" 2>/dev/null || true
  echo "SINGLETON FAILED: start.sh did not reuse the running app" >&2
  exit 1
fi
for _ in {1..30}; do
  show_count_after=$(rg -c 'Control window shown' "$result_dir/foreign.log" || true)
  (( show_count_after > show_count_before )) && break
  sleep 0.1
done
if (( show_count_after <= show_count_before )); then
  print -n > "$runtime_dir/stop.request"
  wait "$foreign_pid" 2>/dev/null || true
  echo "REOPEN FAILED: start.sh did not show the running app control window" >&2
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

echo "REGRESSION PASSED: four voice rounds, AirPods status icon, Fn lifecycle, send, permissions, launch safety, and singleton behavior"
