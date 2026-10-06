#!/bin/bash
# Build a distributable macOS app without installing or launching it.
set -euo pipefail

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[[ $# -eq 2 ]] || fail 'Usage: bash Scripts/package-release.sh <tag> <arm64|x86_64>'
release_tag="$1"
architecture="$2"
[[ -n "$release_tag" ]] || fail 'The release tag must not be empty.'
[[ "$(uname -s)" == Darwin ]] || fail 'Packaging requires macOS and full Xcode.'
case "$architecture" in
    arm64|x86_64) ;;
    *) fail "Unsupported architecture: $architecture" ;;
esac
[[ "$(uname -m)" == "$architecture" ]] || fail 'Run packaging on a Mac with the requested architecture.'
xcodebuild -version >/dev/null

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$project_dir/.build/release"
dist_dir="$build_dir/dist"
app="$build_dir/Build/Products/Release/FSNotes.app"
# Tags may contain slashes and other characters unsuitable for asset filenames.
asset_tag="$(printf '%s' "$release_tag" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/_/g')"
archive_name="FSNotes-$asset_tag-macos-$architecture.zip"
mkdir -p "$dist_dir"

build_number="${GITHUB_RUN_NUMBER:-1}"
[[ "$build_number" =~ ^[0-9]+$ ]] || fail 'The build number must be numeric.'
version_settings=("CURRENT_PROJECT_VERSION=$build_number")
version="${release_tag#v}"
if [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)([-+].*)?$ ]]; then
    version_settings+=("MARKETING_VERSION=${BASH_REMATCH[1]}")
fi

xcodebuild \
    -project "$project_dir/FSNotes.xcodeproj" \
    -scheme FSNotes \
    -configuration Release \
    -destination "platform=macOS,arch=$architecture" \
    -derivedDataPath "$build_dir" \
    -clonedSourcePackagesDirPath "$project_dir/.build/SourcePackages" \
    -onlyUsePackageVersionsFromResolvedFile \
    -quiet \
    "ARCHS=$architecture" \
    ONLY_ACTIVE_ARCH=YES \
    MACOSX_DEPLOYMENT_TARGET=15.0 \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE= \
    PROVISIONING_PROFILE_SPECIFIER= \
    "${version_settings[@]}" \
    build 2>&1 | tee "$build_dir/build.log"

[[ -f "$app/Contents/Info.plist" ]] || fail "Missing app bundle: $app"
for executable in FSNotes git git-lfs git-credential-osxkeychain; do
    binary="$app/Contents/MacOS/$executable"
    [[ -x "$binary" ]] || fail "Missing executable: $binary"
    /usr/bin/lipo "$binary" -verify_arch "$architecture"
    /usr/bin/codesign --verify --strict "$binary"
done
[[ -L "$app/Contents/MacOS/git-upload-pack" && -L "$app/Contents/MacOS/git-receive-pack" ]] ||
    fail 'Missing Git transport helpers.'
/usr/bin/codesign --verify --deep --strict "$app"

# ditto preserves executable permissions, symlinks and the complete app bundle.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$dist_dir/$archive_name"
(
    cd "$dist_dir"
    /usr/bin/shasum -a 256 "$archive_name" > "$archive_name.sha256"
)
printf 'Release package: %s\n' "$dist_dir/$archive_name"
