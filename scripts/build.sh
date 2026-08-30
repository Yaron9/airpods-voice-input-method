#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
build_dir="$project_dir/build"
app_dir="$build_dir/AirPods Siri Voice Bridge.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
executable="$macos_dir/airpods-siri-voice-bridge"
target_arch=$(uname -m)
deployment_target=13.0
if [[ -n "${AIRPODS_BRIDGE_SIGN_IDENTITY:-}" ]]; then
  sign_identity=$AIRPODS_BRIDGE_SIGN_IDENTITY
else
  sign_identity=$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
    | head -n 1)
fi
mkdir -p "$macos_dir"

if [[ -z "$sign_identity" ]] || ! security find-identity -v -p codesigning | grep -Fq "\"$sign_identity\""; then
  echo "No Apple Development signing identity is available." >&2
  echo "Add your Apple ID in Xcode, or set AIRPODS_BRIDGE_SIGN_IDENTITY explicitly." >&2
  exit 1
fi

clang -Wall -Wextra -Werror -Wno-deprecated-declarations \
  -mmacosx-version-min="$deployment_target" \
  -c "$project_dir/src/fn-injector.c" \
  -o "$build_dir/fn-injector.o"

swiftc \
  -target "${target_arch}-apple-macosx${deployment_target}" \
  "$project_dir/src/airpods-siri-voice-bridge.swift" \
  "$build_dir/fn-injector.o" \
  -framework AppKit \
  -framework CoreGraphics \
  -framework IOKit \
  -framework MediaPlayer \
  -o "$executable"

cp "$project_dir/resources/Info.plist" "$contents_dir/Info.plist"
codesign --force --sign "$sign_identity" \
  --identifier com.yaron.airpods-siri-voice-bridge \
  --options runtime --timestamp=none "$app_dir"
codesign --verify --strict --verbose=2 "$app_dir"

echo "$app_dir"
