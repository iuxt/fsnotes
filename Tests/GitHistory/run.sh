#!/bin/bash
# Usage: Tests/GitHistory/run.sh /path/to/swift-cgit2/libgit2
# Uses the project's pinned libgit2 source; installs nothing on the host.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
git_source="${1:?Pass the libgit2 source directory from the swift-cgit2 package checkout}"
test_build="$(mktemp -d "${TMPDIR:-/tmp}/fsnotes-git-tests.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT
# Bundle.main resolves auxiliary tools beside these command-line executables.
# Exercise the same embedded-client lookup as the app, without a Homebrew PATH.
cp -L "${GIT_LFS_EXECUTABLE:-$(command -v git-lfs)}" "$test_build/git-lfs"
cp -L "${GIT_EXECUTABLE:-$(xcrun --find git)}" "$test_build/git"
ln -s git "$test_build/git-upload-pack"
ln -s git "$test_build/git-receive-pack"
cmake -S "$git_source" -B "$test_build/libgit2" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_CLAR=OFF -DUSE_HTTPS=OFF -DUSE_SSH=OFF > "$test_build/build.log" 2>&1
cmake --build "$test_build/libgit2" -j 6 >> "$test_build/build.log" 2>&1
mkdir -p "$test_build/Cgit2"
printf 'module Cgit2 [system] { header "%s/include/git2.h" export * }\n' "$git_source" > "$test_build/Cgit2/module.modulemap"
git_sources=(
    "$repo_root/FSNotesCore/Business/WorkspaceLocation.swift"
    "$repo_root/FSNotesCore/Git/repository/Repository.swift"
    "$repo_root/FSNotesCore/Git/repository/Repository+Lookup.swift"
    "$repo_root/FSNotesCore/Git/tree/Tree.swift"
    "$repo_root/FSNotesCore/Git/tree/TreeEntry.swift"
    "$repo_root/FSNotesCore/Git/commit/Commit.swift"
    "$repo_root/FSNotesCore/Git/commons/Blob.swift"
    "$repo_root/FSNotesCore/Git/commons/OID.swift"
    "$repo_root/FSNotesCore/Git/commons/Object.swift"
    "$repo_root/FSNotesCore/Git/commons/Error.swift"
    "$repo_root/FSNotesCore/Git/commons/Errors.swift"
    "$repo_root/FSNotesCore/Git/commons/Signature.swift"
    "$repo_root/FSNotesCore/Git/commons/Strings.swift"
    "$repo_root/FSNotes/HistoryDiff.swift"
    "$repo_root/Tests/GitHistory/Support.swift"
    "$repo_root/FSNotesCore/Git/index/Index.swift"
    "$repo_root/FSNotesCore/Git/index/Index+Files.swift"
    "$repo_root/FSNotesCore/Git/LFS/GitLFS.swift"
)
for executable in Integration LFSIntegration; do
    swiftc -I "$test_build/Cgit2" -I "$git_source/include" \
        -I "$repo_root/FSNotesCore/Git/LFS" \
        "${git_sources[@]}" "$repo_root/Tests/GitHistory/$executable.swift" \
        "$test_build/libgit2/libgit2.a" -lz -liconv -framework Security \
        -o "$test_build/$executable"
    PATH=/usr/bin:/bin:/usr/sbin:/sbin "$test_build/$executable"
done

# Repeat actual LFS push/pull in a signed sandboxed app. A plain CLI test cannot
# detect the denied access to Homebrew that originally broke image syncing.
sandbox_app="$test_build/LFSTests.app"
mkdir -p "$sandbox_app/Contents/MacOS"
cp "$test_build/LFSIntegration" "$sandbox_app/Contents/MacOS/LFSIntegration"
cat > "$sandbox_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>co.fluder.fsnotes.lfs-integration</string>
<key>CFBundleExecutable</key><string>LFSIntegration</string>
</dict></plist>
PLIST
SRCROOT="$repo_root" TARGET_BUILD_DIR="$test_build" \
    EXECUTABLE_FOLDER_PATH=LFSTests.app/Contents/MacOS \
    UNLOCALIZED_RESOURCES_FOLDER_PATH=LFSTests.app/Contents/Resources \
    ARCHS="$(uname -m)" PRODUCT_BUNDLE_IDENTIFIER=co.fluder.fsnotes.lfs-integration \
    GIT_LFS_EXECUTABLE="$test_build/git-lfs" EXPANDED_CODE_SIGN_IDENTITY=- \
    /bin/bash "$repo_root/Scripts/embed-git-lfs.sh"
codesign --force --sign - --entitlements "$repo_root/FSNotes/FSNotes.entitlements" "$sandbox_app"
codesign --verify --deep --strict "$sandbox_app"
PATH=/usr/bin:/bin:/usr/sbin:/sbin "$sandbox_app/Contents/MacOS/LFSIntegration"

sync_sources=()
while IFS= read -r source; do sync_sources+=("$source"); done < <(rg --files "$repo_root/FSNotesCore/Git" -g '*.swift')
swiftc -I "$test_build/Cgit2" -I "$git_source/include" \
    -I "$repo_root/FSNotesCore/Git/LFS" \
    "${sync_sources[@]}" \
    "$repo_root/FSNotesCore/Business/WorkspaceLocation.swift" \
    "$repo_root/FSNotesCore/Extensions/Project+Git.swift" \
    "$repo_root/FSNotesCore/RepositoryAction.swift" \
    "$repo_root/Tests/GitHistory/SyncSupport.swift" \
    "$repo_root/Tests/GitHistory/SyncIntegration.swift" \
    "$test_build/libgit2/libgit2.a" -lz -liconv -framework Security \
    -o "$test_build/sync-integration"
"$test_build/sync-integration"
