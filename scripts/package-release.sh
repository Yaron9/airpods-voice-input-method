#!/bin/zsh
set -euo pipefail
export COPYFILE_DISABLE=1

project_dir=${0:A:h:h}
dist_dir="$project_dir/dist"
app_dir="$project_dir/build/AirPods Voice 输入法.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$project_dir/resources/Info.plist")
package="$dist_dir/AirPods-Voice-Input-Method-$version-macOS.pkg"
component_plist="$project_dir/resources/package-components.plist"
app_sign_identity=${AIRPODS_VOICE_INPUT_SIGN_IDENTITY:--}
installer_sign_identity=${AIRPODS_VOICE_INPUT_INSTALLER_SIGN_IDENTITY:-}

if [[ "$app_sign_identity" != "-" && -z "$installer_sign_identity" ]] \
  || [[ "$app_sign_identity" == "-" && -n "$installer_sign_identity" ]]; then
  echo "App and installer signing identities must be provided together" >&2
  exit 1
fi

"$project_dir/scripts/build.sh" >/dev/null
mkdir -p "$dist_dir"
staging_root=$(mktemp -d /tmp/airpods-voice-input-pkg.XXXXXX)
cleanup_staging_root() {
  [[ ! -d "$staging_root" ]] || rm -rf -- "$staging_root"
}
trap cleanup_staging_root EXIT
ditto --norsrc --noextattr "$app_dir" "$staging_root/AirPods Voice 输入法.app"
xattr -cr "$staging_root/AirPods Voice 输入法.app"
codesign --verify --strict "$staging_root/AirPods Voice 输入法.app"
if [[ -e "$package" ]]; then
  unlink "$package"
fi
pkgbuild_args=(
  --root "$staging_root" \
  --component-plist "$component_plist" \
  --install-location /Applications \
  --identifier com.yaron.airpods-voice-input-method.installer \
  --version "$version"
)
if [[ -n "$installer_sign_identity" ]]; then
  pkgbuild_args+=(--sign "$installer_sign_identity")
fi
pkgbuild "${pkgbuild_args[@]}" "$package" >/dev/null
pkgutil --payload-files "$package" | grep -Fq './AirPods Voice 输入法.app/Contents/MacOS/airpods-voice-input-method'

echo "$package"
shasum -a 256 "$package"
