#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
runtime_dir=/tmp/airpods-voice-input-method
pid_file="$runtime_dir/app.pid"
launch_label=com.metame.airpods-voice-input-method
installed_app="/Applications/AirPods Voice 输入法.app"
installed_executable="$installed_app/Contents/MacOS/airpods-voice-input-method"
voice_key_file=${AIRPODS_VOICE_INPUT_KEY_FILE:-"$project_dir/config/voice-key"}
if [[ -n "${AIRPODS_VOICE_INPUT_KEY:-}" ]]; then
  voice_key=${AIRPODS_VOICE_INPUT_KEY:l}
elif [[ -f "$voice_key_file" ]]; then
  voice_key=$(awk 'NF && $1 !~ /^#/ { print tolower($1); exit }' "$voice_key_file")
else
  voice_key=fn
fi
voice_key=${voice_key:-fn}
case "$voice_key" in
  fn|control|option|command|shift|f1|f2|f3|f4|f5|f6|f7|f8|f9|f10|f11|f12) ;;
  *)
    echo "Unsupported voice key: $voice_key" >&2
    echo "Supported: fn control option command shift f1...f12" >&2
    exit 1
    ;;
esac
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p "$runtime_dir"

legacy_label=com.metame.airpods-siri-voice-bridge
legacy_pattern='^/Applications/AirPods Siri Voice Bridge[.]app/Contents/MacOS/airpods-siri-voice-bridge( |$)'
legacy_pid=$(pgrep -f "$legacy_pattern" | head -n 1 || true)
if [[ "$legacy_pid" == <-> ]]; then
  mkdir -p /tmp/airpods-fn-test
  print -n > /tmp/airpods-fn-test/stop.request
  for _ in {1..50}; do
    kill -0 "$legacy_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$legacy_pid" 2>/dev/null; then
    echo "Pre-1.0 app did not stop; quit it before starting AirPods Voice 输入法 1.0" >&2
    exit 1
  fi
fi
launchctl remove "$legacy_label" 2>/dev/null || true

launchd_pid=$(launchctl print "gui/$(id -u)/$launch_label" 2>/dev/null \
  | awk '/^[[:space:]]*pid = [0-9]+/ { print $3; exit }' || true)
if [[ "$launchd_pid" == <-> ]] && kill -0 "$launchd_pid" 2>/dev/null; then
  print -r -- "$launchd_pid" >"$pid_file"
  echo "AirPods Voice 输入法 already running (PID $launchd_pid)"
  exit 0
fi

if [[ -f "$pid_file" ]]; then
  running_pid=$(<"$pid_file")
  if [[ "$running_pid" == <-> ]] && kill -0 "$running_pid" 2>/dev/null; then
    executable=$(ps -p "$running_pid" -o comm=)
    if [[ "${executable:t}" == "airpods-voice-input-method" ]]; then
      echo "AirPods Voice 输入法 already running (PID $running_pid)"
      exit 0
    fi
  fi
fi

if [[ -e "$runtime_dir/stop.request" ]]; then
  unlink "$runtime_dir/stop.request"
fi
if [[ -x "$installed_executable" ]]; then
  app_to_launch="$installed_app"
else
  "$project_dir/scripts/build.sh" >/dev/null
  app_to_launch="$project_dir/build/AirPods Voice 输入法.app"
fi
executable_to_launch="$app_to_launch/Contents/MacOS/airpods-voice-input-method"
codesign --verify --strict --verbose=2 "$app_to_launch"
"$lsregister" -f "$app_to_launch"
launchctl remove "$launch_label" 2>/dev/null || true
launchctl submit -l "$launch_label" \
  -o "$runtime_dir/app.stdout.log" \
  -e "$runtime_dir/app.stderr.log" \
  -- "$executable_to_launch" --voice-key "$voice_key"

app_pid=""
for _ in {1..30}; do
  app_pid=$(launchctl print "gui/$(id -u)/$launch_label" 2>/dev/null \
    | awk '/^[[:space:]]*pid = [0-9]+/ { print $3; exit }' || true)
  [[ "$app_pid" == <-> ]] && kill -0 "$app_pid" 2>/dev/null && break
  sleep 0.1
done

if [[ "$app_pid" != <-> ]] || ! kill -0 "$app_pid" 2>/dev/null; then
  echo "AirPods Voice 输入法 failed to start; inspect $runtime_dir/app.stderr.log" >&2
  exit 1
fi
print -r -- "$app_pid" >"$pid_file"
echo "AirPods Voice 输入法 started (PID $app_pid, voice key: $voice_key)"
