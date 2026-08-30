#!/bin/zsh
set -euo pipefail

runtime_dir=/tmp/airpods-voice-input-method
pid_file="$runtime_dir/app.pid"
launch_label=com.metame.airpods-voice-input-method
launchd_pid=$(launchctl print "gui/$(id -u)/$launch_label" 2>/dev/null \
  | awk '/^[[:space:]]*pid = [0-9]+/ { print $3; exit }' || true)

if [[ "$launchd_pid" == <-> ]]; then
  app_pid=$launchd_pid
elif [[ -f "$pid_file" ]]; then
  app_pid=$(<"$pid_file")
else
  echo "AirPods Voice 输入法 is not running"
  exit 0
fi
if [[ "$app_pid" != <-> ]]; then
  echo "Invalid app PID file: $pid_file" >&2
  exit 1
fi

if kill -0 "$app_pid" 2>/dev/null; then
    executable=$(ps -p "$app_pid" -o comm=)
  if [[ "${executable:t}" != "airpods-voice-input-method" ]]; then
    echo "PID $app_pid is not AirPods Voice 输入法; refusing to stop it" >&2
    exit 1
  fi
  print -n > "$runtime_dir/stop.request"
  for _ in {1..30}; do
    kill -0 "$app_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$app_pid" 2>/dev/null; then
    echo "App did not acknowledge graceful stop; it was left running to avoid a stuck Fn modifier" >&2
    exit 1
  fi
  echo "AirPods Voice 输入法 stopped gracefully (PID $app_pid)"
else
  echo "AirPods Voice 输入法 was already stopped"
fi
launchctl remove "$launch_label" 2>/dev/null || true
if [[ -e "$pid_file" ]]; then
  unlink "$pid_file"
fi
