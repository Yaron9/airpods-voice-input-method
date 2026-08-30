#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
build_dir="$project_dir/build"
app_dir="$build_dir/AirPods Voice 输入法.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
executable="$macos_dir/airpods-voice-input-method"
icon_source="$project_dir/resources/AppIcon.png"
iconset_dir="$build_dir/AppIcon.iconset"
icon_file="$resources_dir/AppIcon.icns"
deployment_target=13.0
sign_identity=${AIRPODS_VOICE_INPUT_SIGN_IDENTITY:--}
mkdir -p "$macos_dir" "$resources_dir" "$iconset_dir"

icon_sizes=(16 32 128 256 512)
for icon_size in $icon_sizes; do
  retina_size=$((icon_size * 2))
  sips -z "$icon_size" "$icon_size" "$icon_source" \
    --out "$iconset_dir/icon_${icon_size}x${icon_size}.png" >/dev/null
  sips -z "$retina_size" "$retina_size" "$icon_source" \
    --out "$iconset_dir/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$icon_file"

if [[ "$sign_identity" != "-" ]] \
  && ! security find-identity -v -p codesigning | grep -Fq "\"$sign_identity\""; then
  echo "Code-signing identity is unavailable: $sign_identity" >&2
  exit 1
fi

architectures=(arm64 x86_64)
arch_executables=()
for target_arch in $architectures; do
  object_file="$build_dir/fn-injector-$target_arch.o"
  arch_executable="$build_dir/airpods-voice-input-method-$target_arch"

  clang -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -arch "$target_arch" \
    -mmacosx-version-min="$deployment_target" \
    -c "$project_dir/src/fn-injector.c" \
    -o "$object_file"

  swiftc \
    -target "${target_arch}-apple-macosx${deployment_target}" \
    "$project_dir/src/airpods-voice-input-method.swift" \
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
    --identifier com.yaron.airpods-voice-input-method \
    --options runtime --timestamp=none "$app_dir"
else
  codesign --force --sign "$sign_identity" \
    --identifier com.yaron.airpods-voice-input-method \
    --options runtime --timestamp "$app_dir"
fi
codesign --verify --strict --verbose=2 "$app_dir"

echo "$app_dir"
