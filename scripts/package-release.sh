#!/bin/bash

set -euo pipefail

version="${1:-1.0.0}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]]; then
    echo "Invalid release version: $version" >&2
    exit 1
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
release_dir="$project_root/release"
artifact="$release_dir/macro-pad-$version-unsigned.dmg"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
derived_dir="$(mktemp -d /tmp/macro-pad-release.XXXXXX)"
staging_dir="$(mktemp -d /tmp/macro-pad-dmg.XXXXXX)"
mount_point=""

cleanup() {
    if [[ -n "$mount_point" ]] && mount | grep -Fq " on $mount_point "; then
        hdiutil detach "$mount_point" >/dev/null
    fi
    rm -rf "$derived_dir" "$staging_dir"
}
trap cleanup EXIT

if [[ -e "$artifact" ]]; then
    echo "Refusing to overwrite existing artifact: $artifact" >&2
    echo "Move or archive it explicitly before packaging again." >&2
    exit 1
fi

mkdir -p "$release_dir"

DEVELOPER_DIR="$developer_dir" xcodebuild \
    -project "$project_root/macro-pad.xcodeproj" \
    -scheme macro-pad \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_dir" \
    CODE_SIGNING_ALLOWED=NO \
    clean build

app_path="$derived_dir/Build/Products/Release/macro-pad.app"

# Xcode has finished copying resources. Replace the linker's incomplete ad-hoc
# signature with a bundle-level signature that seals the completed application.
codesign \
    --force \
    --sign - \
    --options runtime \
    --timestamp=none \
    "$app_path"

# Packaging must never proceed unless the completed bundle verifies strictly.
codesign --verify --deep --strict --verbose=4 "$app_path"

ditto "$app_path" "$staging_dir/macro-pad.app"
ln -s /Applications "$staging_dir/Applications"
codesign --verify --deep --strict --verbose=4 "$staging_dir/macro-pad.app"

hdiutil create \
    -quiet \
    -volname "macro-pad $version (ad-hoc signed, unnotarized)" \
    -srcfolder "$staging_dir" \
    -format UDZO \
    "$artifact"

hdiutil verify "$artifact"

mount_output="$(hdiutil attach -readonly -nobrowse "$artifact")"
mount_point="$(printf '%s\n' "$mount_output" | awk -F '\t' '/\/Volumes\// {print $NF; exit}')"

if [[ -z "$mount_point" ]]; then
    echo "Unable to determine the mounted DMG path." >&2
    exit 1
fi

packaged_app="$mount_point/macro-pad.app"
applications_alias="$mount_point/Applications"

if [[ ! -d "$packaged_app" ]] || [[ "$(readlink "$applications_alias")" != "/Applications" ]]; then
    echo "The mounted DMG does not contain the expected app and Applications alias." >&2
    exit 1
fi

# Verify the packaged copy independently, not the pre-image staging bundle.
codesign --verify --deep --strict --verbose=4 "$packaged_app"
codesign --display --verbose=4 "$packaged_app" 2>&1

hdiutil detach "$mount_point" >/dev/null
mount_point=""

artifact_size="$(stat -f '%z' "$artifact")"
artifact_checksum="$(shasum -a 256 "$artifact" | awk '{print $1}')"

echo "Artifact: $artifact"
echo "Size: $artifact_size bytes"
echo "SHA-256: $artifact_checksum"
echo "Signature: ad-hoc"
echo "Notarization: none"
