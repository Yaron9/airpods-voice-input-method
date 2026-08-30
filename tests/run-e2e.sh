#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
result_dir=/tmp/airpods-voice-input-method/e2e
app="$project_dir/build/AirPods Voice 输入法.app/Contents/MacOS/airpods-voice-input-method"
expected_cycles=4

mkdir -p "$result_dir"
"$project_dir/scripts/build.sh" >/dev/null

"$app" --single-click-cycle-test >"$result_dir/app.log" 2>&1
downs=$(rg -c 'Voice key fn down' "$result_dir/app.log" || true)
ups=$(rg -c 'Voice key fn up; voice input stopped' "$result_dir/app.log" || true)
commits=$(rg -c 'Return key posted; stage=commit' "$result_dir/app.log" || true)
sends=$(rg -c 'Return key posted; stage=send' "$result_dir/app.log" || true)
if (( downs != expected_cycles || ups != expected_cycles \
      || commits != expected_cycles || sends != expected_cycles )); then
  print -u2 -- "E2E RED: expected=$expected_cycles fnDown=$downs fnUp=$ups commits=$commits sends=$sends"
  exit 1
fi
print -- "E2E GREEN: four click-to-start/click-to-send rounds completed"
