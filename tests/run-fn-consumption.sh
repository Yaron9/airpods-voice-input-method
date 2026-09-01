#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
result_dir=/tmp/airpods-voice-input-method/fn-consumption
app="$project_dir/build/AirPods Voice 输入法.app/Contents/MacOS/airpods-voice-input-method"
app_log="$result_dir/app.log"
app_pid=""

release_fn() {
  "$app" --release-fn >/dev/null 2>&1 || true
}

cleanup() {
  if [[ "$app_pid" == <-> ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  release_fn
}
trap cleanup EXIT

mkdir -p "$result_dir"
: > "$app_log"
release_fn
"$project_dir/scripts/build.sh" >/dev/null

"$app" --keyboard-safety-test >"$app_log" 2>&1 &
app_pid=$!
for _ in {1..50}; do
  rg -q 'Voice key fn down' "$app_log" && break
  sleep 0.05
done
rg -q 'Voice key fn down' "$app_log" \
  || { print -u2 -- "FN CONSUMPTION RED: initial Fn down was not posted"; exit 1; }

# Voice input methods consume the synthetic Fn transition after activation.
# Recording must remain logically active, but the bridge must not fight macOS by
# posting another Fn-down every 100 ms.
release_fn
sleep 0.35
if "$app" --fn-is-down; then
  print -u2 -- "FN CONSUMPTION RED: externally consumed Fn was reasserted"
  exit 1
fi
if rg -q 'Voice key fn up; voice input stopped' "$app_log"; then
  print -u2 -- "FN CONSUMPTION RED: consuming Fn stopped the logical recording session"
  exit 1
fi
if rg -q 'reasserted while voice input is active' "$app_log"; then
  print -u2 -- "FN CONSUMPTION RED: bridge repeatedly reposted Fn-down"
  exit 1
fi

print -- "FN CONSUMPTION GREEN: input method consumed Fn without repost storm"
