#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
result_dir=/tmp/airpods-voice-input-method/keyboard-safety
app="$project_dir/build/AirPods Voice 输入法.app/Contents/MacOS/airpods-voice-input-method"
receiver="$result_dir/keyboard-safety-receiver"
marker="$result_dir/space.log"
ready="$result_dir/receiver.ready"
app_log="$result_dir/app.log"
receiver_pid=""
app_pid=""

fn_is_down() {
  "$app" --fn-is-down
}

release_fn() {
  "$app" --release-fn >/dev/null 2>&1 || true
  sleep 0.05
}

cleanup() {
  if [[ "$app_pid" == <-> ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  if [[ "$receiver_pid" == <-> ]] && kill -0 "$receiver_pid" 2>/dev/null; then
    kill "$receiver_pid" 2>/dev/null || true
    wait "$receiver_pid" 2>/dev/null || true
  fi
  release_fn
}
trap cleanup EXIT

mkdir -p "$result_dir"
release_fn
[[ ! -e "$marker" ]] || unlink "$marker"
[[ ! -e "$ready" ]] || unlink "$ready"
"$project_dir/scripts/build.sh" >/dev/null
swiftc "$project_dir/tests/keyboard-safety-receiver.swift" -framework AppKit -o "$receiver"

"$receiver" "$marker" "$ready" >"$result_dir/receiver.log" 2>&1 &
receiver_pid=$!
for _ in {1..40}; do
  [[ -e "$ready" ]] && break
  sleep 0.1
done
[[ -e "$ready" ]] || { print -u2 -- "KEYBOARD SAFETY RED: receiver not ready"; exit 1; }

AIRPODS_VOICE_INPUT_TEST_TARGET_PID="$receiver_pid" \
  "$app" --keyboard-safety-test >"$app_log" 2>&1 &
app_pid=$!
for _ in {1..50}; do
  rg -q 'Voice key fn down' "$app_log" && break
  sleep 0.1
done
rg -q 'Voice key fn down' "$app_log" \
  || { print -u2 -- "KEYBOARD SAFETY RED: Fn was not held"; exit 1; }
for _ in {1..20}; do
  fn_is_down && break
  sleep 0.05
done
fn_is_down || { print -u2 -- "KEYBOARD SAFETY RED: HID Fn flag was not set"; exit 1; }

"$app" --post-space
for _ in {1..60}; do
  [[ -e "$marker" ]] && rg -q 'Keyboard safety probe normalized; fn=false' "$app_log" \
    && ! fn_is_down && break
  sleep 0.05
done
rg -q 'Keyboard safety probe normalized; fn=false' "$app_log" \
  || { print -u2 -- "KEYBOARD SAFETY RED: Space retained the Fn modifier"; exit 1; }
space_result=""
[[ ! -e "$marker" ]] || space_result=$(<"$marker")
[[ "$space_result" == "plain-space" ]] \
  || { print -u2 -- "KEYBOARD SAFETY RED: receiver did not get plain Space"; exit 1; }
fn_is_down && { print -u2 -- "KEYBOARD SAFETY RED: Fn remained held after Space"; exit 1; }
rg -q 'Physical keyboard input interrupted voice hold' "$app_log" \
  || { print -u2 -- "KEYBOARD SAFETY RED: recovery path was not logged"; exit 1; }
wait "$receiver_pid"
receiver_pid=""
kill "$app_pid" 2>/dev/null || true
wait "$app_pid" 2>/dev/null || true
app_pid=""
release_fn

"$app" --crash-watchdog-test >"$result_dir/crash.log" 2>&1 &
app_pid=$!
for _ in {1..50}; do
  rg -q 'Voice key fn down' "$result_dir/crash.log" && break
  sleep 0.1
done
rg -q 'Voice key fn down' "$result_dir/crash.log" \
  || { print -u2 -- "CRASH RECOVERY RED: Fn was not held"; exit 1; }
for _ in {1..20}; do
  fn_is_down && break
  sleep 0.05
done
fn_is_down || { print -u2 -- "CRASH RECOVERY RED: HID Fn flag was not set"; exit 1; }
kill -9 "$app_pid"
wait "$app_pid" 2>/dev/null || true
app_pid=""
for _ in {1..40}; do
  ! fn_is_down && break
  sleep 0.05
done
fn_is_down && { print -u2 -- "CRASH RECOVERY RED: watchdog left Fn held"; exit 1; }

print -- "KEYBOARD SAFETY GREEN: Space was normalized without Fn and crash watchdog released Fn"
