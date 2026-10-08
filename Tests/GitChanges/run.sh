#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
git_source="${1:-$repo_root/.build/SourcePackages/checkouts/swift-cgit2/libgit2}"
test_build="$(mktemp -d "${TMPDIR:-/tmp}/fsnotes-changes-tests.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT
cmake -S "$git_source" -B "$test_build/libgit2" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_CLAR=OFF -DUSE_HTTPS=OFF -DUSE_SSH=OFF > "$test_build/build.log" 2>&1
cmake --build "$test_build/libgit2" -j 6 >> "$test_build/build.log" 2>&1
mkdir -p "$test_build/Cgit2"
printf 'module Cgit2 [system] { header "%s/include/git2.h" export * }\n' "$git_source" > "$test_build/Cgit2/module.modulemap"
git_sources=()
while IFS= read -r source; do git_sources+=("$source"); done < <(rg --files "$repo_root/FSNotesCore/Git" -g '*.swift')
swiftc -I "$test_build/Cgit2" -I "$git_source/include" -I "$repo_root/FSNotesCore/Git/LFS" \
    "${git_sources[@]}" \
    "$repo_root/FSNotesCore/Business/WorkspaceLocation.swift" \
    "$repo_root/FSNotesCore/Business/MetadataStore.swift" \
    "$repo_root/FSNotesCore/Extensions/Project+Git.swift" \
    "$repo_root/FSNotesCore/RepositoryAction.swift" \
    "$repo_root/FSNotes/GitDiffPage.swift" \
    "$repo_root/Tests/GitHistory/SyncSupport.swift" \
    "$repo_root/Tests/GitChanges/Integration.swift" \
    "$test_build/libgit2/libgit2.a" -lz -liconv -framework Security -o "$test_build/Integration"
"$test_build/Integration"
