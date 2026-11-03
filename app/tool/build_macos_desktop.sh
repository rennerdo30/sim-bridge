#!/usr/bin/env bash
# Build and package desktop macOS. Local optional signing or certificate-free CI.
# No uploads or notarization.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd -- "$script_dir/.." && pwd)"
cd "$app_dir"

skip_build=false
ci_build=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) skip_build=true ;;
    --ci) ci_build=true ;;
    --help|-h)
      echo "Usage: $0 [--skip-build] [--ci]"
      echo "--skip-build verifies and packages the existing app without rebuilding."
      echo "--ci creates an ad-hoc development build in separate CI output directories."
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--skip-build] [--ci]" >&2
      exit 2
      ;;
  esac
  shift
done

build_root="$app_dir/build/macos"
output_dir="$app_dir/build/desktop"
package_name="Sim-Bridge-macOS"
if [[ "$ci_build" == true ]]; then
  build_root="$app_dir/build/macos-ci"
  output_dir="$app_dir/build/desktop-ci"
  package_name="Sim-Bridge-macOS-$(uname -m)"
fi

if [[ "$skip_build" == false ]]; then
  if [[ "$ci_build" == true ]]; then
    # Config-only avoids Flutter's CI sandbox-removal behavior. xcodebuild
    # retains Runner's entitlements and overrides owner signing for every target.
    flutter build macos --release --config-only
    host_arch="$(uname -m)"
    xcrun xcodebuild -workspace "$app_dir/macos/Runner.xcworkspace" \
      -scheme Runner -configuration Release -derivedDataPath "$build_root" \
      -destination "generic/platform=macOS" \
      "OBJROOT=$build_root/Build/Intermediates.noindex" \
      "SYMROOT=$build_root/Build/Products" \
      "ARCHS=$host_arch" ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO \
      CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
      PROVISIONING_PROFILE_SPECIFIER= build
  else
    flutter build macos --release
  fi
fi
bundle="$build_root/Build/Products/Release/Sim Bridge.app"
if [[ ! -d "$bundle" ]]; then
  echo "Expected app bundle was not produced: $bundle" >&2
  exit 1
fi
if [[ "$ci_build" == true && "$skip_build" == false ]]; then
  # Flutter can re-sign App.framework during an incremental assemble while
  # Xcode retains the old outer seal. Seal the freshly built CI app after all
  # nested output is final, preserving its identifier and sandbox permissions.
  # --skip-build remains verification-only; local publisher signing is untouched.
  codesign --force --sign - \
    --preserve-metadata=identifier,entitlements,flags,requirements "$bundle"
fi
codesign --verify --deep --strict "$bundle"

mkdir -p "$output_dir"
if [[ "$ci_build" == true ]]; then
  # Release packages are zipped app bundles: the renner.dev launcher and the
  # homepage install a zip, and the zip keeps the bundle's signature intact.
  ditto -c -k --sequesterRsrc --keepParent "$bundle" "$output_dir/$package_name.zip"
  printf 'Created %s\n' "$output_dir/$package_name.zip"
  (
    cd "$output_dir"
    shasum -a 256 "$package_name.zip" > "$package_name.zip.sha256"
  )
  exit 0
fi

staging_dir="$(mktemp -d "$output_dir/.dmg-stage.XXXXXX")"
trap 'rm -rf -- "$staging_dir"' EXIT

ditto "$bundle" "$staging_dir/Sim Bridge.app"
ln -s /Applications "$staging_dir/Applications"
hdiutil create -volname "Sim Bridge" -srcfolder "$staging_dir" \
  -format UDZO -ov "$output_dir/$package_name.dmg"
printf 'Created %s\n' "$output_dir/$package_name.dmg"

(
  cd "$output_dir"
  shasum -a 256 "$package_name.dmg" > "$package_name.dmg.sha256"
)
