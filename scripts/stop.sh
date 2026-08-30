#!/bin/zsh
set -euo pipefail

pid_file=/tmp/airpods-fn-test/bridge.pid
launch_label=com.metame.airpods-siri-voice-bridge
launchd_pid=$(launchctl print "gui/$(id -u)/$launch_label" 2>/dev/null \
  | awk '/^[[:space:]]*pid = [0-9]+/ { print $3; exit }' || true)

if [[ "$launchd_pid" == <-> ]]; then
  bridge_pid=$launchd_pid
elif [[ -f "$pid_file" ]]; then
  bridge_pid=$(<"$pid_file")
else
  echo "Bridge is not running"
  exit 0
fi
if [[ "$bridge_pid" != <-> ]]; then
  echo "Invalid bridge PID file: $pid_file" >&2
  exit 1
fi

if kill -0 "$bridge_pid" 2>/dev/null; then
    executable=$(ps -p "$bridge_pid" -o comm=)
  if [[ "${executable:t}" != "airpods-siri-voice-bridge" ]]; then
    echo "PID $bridge_pid is not the bridge; refusing to stop it" >&2
    exit 1
  fi
  print -n > /tmp/airpods-fn-test/stop.request
  for _ in {1..30}; do
    kill -0 "$bridge_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$bridge_pid" 2>/dev/null; then
    echo "Bridge did not acknowledge graceful stop; it was left running to avoid a stuck Fn modifier" >&2
    exit 1
  fi
  echo "Bridge stopped gracefully (PID $bridge_pid)"
else
  echo "Bridge was already stopped"
fi
launchctl remove "$launch_label" 2>/dev/null || true
if [[ -e "$pid_file" ]]; then
  unlink "$pid_file"
fi
