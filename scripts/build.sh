#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
build_dir="$project_dir/build"
app_dir="$build_dir/AirPods Siri Voice Bridge.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
executable="$macos_dir/airpods-siri-voice-bridge"
deployment_target=13.0
sign_identity=${AIRPODS_BRIDGE_SIGN_IDENTITY:--}
mkdir -p "$macos_dir"

if [[ "$sign_identity" != "-" ]] \
  && ! security find-identity -v -p codesigning | grep -Fq "\"$sign_identity\""; then
  echo "Code-signing identity is unavailable: $sign_identity" >&2
  exit 1
fi

architectures=(arm64 x86_64)
arch_executables=()
for target_arch in $architectures; do
  object_file="$build_dir/fn-injector-$target_arch.o"
  arch_executable="$build_dir/airpods-siri-voice-bridge-$target_arch"

  clang -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -arch "$target_arch" \
    -mmacosx-version-min="$deployment_target" \
    -c "$project_dir/src/fn-injector.c" \
    -o "$object_file"

  swiftc \
    -target "${target_arch}-apple-macosx${deployment_target}" \
    "$project_dir/src/airpods-siri-voice-bridge.swift" \
    "$object_file" \
    -framework AppKit \
    -framework CoreGraphics \
    -framework IOKit \
    -framework MediaPlayer \
    -o "$arch_executable"
  arch_executables+=("$arch_executable")
done

lipo -create "${arch_executables[@]}" -output "$executable"

cp "$project_dir/resources/Info.plist" "$contents_dir/Info.plist"
if [[ "$sign_identity" == "-" ]]; then
  codesign --force --sign - \
    --identifier com.yaron.airpods-siri-voice-bridge \
    --options runtime --timestamp=none "$app_dir"
else
  codesign --force --sign "$sign_identity" \
    --identifier com.yaron.airpods-siri-voice-bridge \
    --options runtime --timestamp "$app_dir"
fi
codesign --verify --strict --verbose=2 "$app_dir"

echo "$app_dir"
