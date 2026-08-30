#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
dist_dir="$project_dir/dist"
app_dir="$project_dir/build/AirPods Siri Voice Bridge.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$project_dir/resources/Info.plist")
archive="$dist_dir/AirPods-Siri-Voice-Bridge-$version-macOS.zip"

"$project_dir/scripts/build.sh" >/dev/null
mkdir -p "$dist_dir"
if [[ -e "$archive" ]]; then
  unlink "$archive"
fi
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive"
unzip -tq "$archive" >/dev/null

echo "$archive"
shasum -a 256 "$archive"
