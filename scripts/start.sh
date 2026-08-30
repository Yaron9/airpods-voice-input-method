#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
runtime_dir=/tmp/airpods-fn-test
pid_file="$runtime_dir/bridge.pid"
launch_label=com.metame.airpods-siri-voice-bridge
installed_app="$HOME/Applications/AirPods Siri Voice Bridge.app"
installed_executable="$installed_app/Contents/MacOS/airpods-siri-voice-bridge"
voice_key_file=${AIRPODS_BRIDGE_VOICE_KEY_FILE:-"$project_dir/config/voice-key"}
if [[ -n "${AIRPODS_BRIDGE_VOICE_KEY:-}" ]]; then
  voice_key=${AIRPODS_BRIDGE_VOICE_KEY:l}
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

launchd_pid=$(launchctl print "gui/$(id -u)/$launch_label" 2>/dev/null \
  | awk '/^[[:space:]]*pid = [0-9]+/ { print $3; exit }' || true)
if [[ "$launchd_pid" == <-> ]] && kill -0 "$launchd_pid" 2>/dev/null; then
  print -r -- "$launchd_pid" >"$pid_file"
  echo "Bridge already running (PID $launchd_pid)"
  exit 0
fi

if [[ -f "$pid_file" ]]; then
  running_pid=$(<"$pid_file")
  if [[ "$running_pid" == <-> ]] && kill -0 "$running_pid" 2>/dev/null; then
    executable=$(ps -p "$running_pid" -o comm=)
    if [[ "${executable:t}" == "airpods-siri-voice-bridge" ]]; then
      echo "Bridge already running (PID $running_pid)"
      exit 0
    fi
  fi
fi

if [[ -e "$runtime_dir/stop.request" ]]; then
  unlink "$runtime_dir/stop.request"
fi
"$project_dir/scripts/build.sh" >/dev/null
built_app="$project_dir/build/AirPods Siri Voice Bridge.app"
ditto "$built_app" "$installed_app"
codesign --verify --strict --verbose=2 "$installed_app"
"$lsregister" -f "$installed_app"
launchctl remove "$launch_label" 2>/dev/null || true
launchctl submit -l "$launch_label" \
  -o "$runtime_dir/bridge.stdout.log" \
  -e "$runtime_dir/bridge.stderr.log" \
  -- "$installed_executable" --voice-key "$voice_key"

bridge_pid=""
for _ in {1..30}; do
  bridge_pid=$(launchctl print "gui/$(id -u)/$launch_label" 2>/dev/null \
    | awk '/^[[:space:]]*pid = [0-9]+/ { print $3; exit }' || true)
  [[ "$bridge_pid" == <-> ]] && kill -0 "$bridge_pid" 2>/dev/null && break
  sleep 0.1
done

if [[ "$bridge_pid" != <-> ]] || ! kill -0 "$bridge_pid" 2>/dev/null; then
  echo "Bridge failed to start under launchd; inspect $runtime_dir/bridge.stderr.log" >&2
  exit 1
fi
print -r -- "$bridge_pid" >"$pid_file"
echo "Bridge started (PID $bridge_pid, voice key: $voice_key)"
