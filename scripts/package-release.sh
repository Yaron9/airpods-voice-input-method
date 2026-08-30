#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
dist_dir="$project_dir/dist"
app_dir="$project_dir/build/AirPods Siri Voice Bridge.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$project_dir/resources/Info.plist")
package="$dist_dir/AirPods-Siri-Voice-Bridge-$version-macOS.pkg"
component_plist="$project_dir/resources/package-components.plist"
app_sign_identity=${AIRPODS_BRIDGE_SIGN_IDENTITY:--}
installer_sign_identity=${AIRPODS_BRIDGE_INSTALLER_SIGN_IDENTITY:-}

if [[ "$app_sign_identity" != "-" && -z "$installer_sign_identity" ]] \
  || [[ "$app_sign_identity" == "-" && -n "$installer_sign_identity" ]]; then
  echo "App and installer signing identities must be provided together" >&2
  exit 1
fi

"$project_dir/scripts/build.sh" >/dev/null
mkdir -p "$dist_dir"
staging_root=$(mktemp -d /tmp/airpods-voice-bridge-pkg.XXXXXX)
cleanup_staging_root() {
  [[ ! -d "$staging_root" ]] || rm -rf -- "$staging_root"
}
trap cleanup_staging_root EXIT
ditto "$app_dir" "$staging_root/AirPods Siri Voice Bridge.app"
if [[ -e "$package" ]]; then
  unlink "$package"
fi
pkgbuild_args=(
  --root "$staging_root" \
  --component-plist "$component_plist" \
  --install-location /Applications \
  --identifier com.yaron.airpods-siri-voice-bridge.installer \
  --version "$version"
)
if [[ -n "$installer_sign_identity" ]]; then
  pkgbuild_args+=(--sign "$installer_sign_identity")
fi
pkgbuild "${pkgbuild_args[@]}" "$package" >/dev/null
pkgutil --payload-files "$package" | grep -Fq './AirPods Siri Voice Bridge.app/Contents/MacOS/airpods-siri-voice-bridge'

echo "$package"
shasum -a 256 "$package"
