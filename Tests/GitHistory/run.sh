#!/bin/bash
# Usage: Tests/GitHistory/run.sh /path/to/swift-cgit2/libgit2
# Uses the project's pinned libgit2 source; installs nothing on the host.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
git_source="${1:?Pass the libgit2 source directory from the swift-cgit2 package checkout}"
test_build="$(mktemp -d "${TMPDIR:-/tmp}/fsnotes-git-tests.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT
cmake -S "$git_source" -B "$test_build/libgit2" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_CLAR=OFF -DUSE_HTTPS=OFF -DUSE_SSH=OFF > "$test_build/build.log" 2>&1
cmake --build "$test_build/libgit2" -j 6 >> "$test_build/build.log" 2>&1
mkdir -p "$test_build/Cgit2"
printf 'module Cgit2 [system] { header "%s/include/git2.h" export * }\n' "$git_source" > "$test_build/Cgit2/module.modulemap"
swiftc -I "$test_build/Cgit2" -I "$git_source/include" \
    "$repo_root/FSNotesCore/Business/WorkspaceLocation.swift" \
    "$repo_root/FSNotesCore/Git/repository/Repository.swift" \
    "$repo_root/FSNotesCore/Git/repository/Repository+Lookup.swift" \
    "$repo_root/FSNotesCore/Git/tree/Tree.swift" \
    "$repo_root/FSNotesCore/Git/tree/TreeEntry.swift" \
    "$repo_root/FSNotesCore/Git/commit/Commit.swift" \
    "$repo_root/FSNotesCore/Git/commons/Blob.swift" \
    "$repo_root/FSNotesCore/Git/commons/OID.swift" \
    "$repo_root/FSNotesCore/Git/commons/Object.swift" \
    "$repo_root/FSNotesCore/Git/commons/Error.swift" \
    "$repo_root/FSNotesCore/Git/commons/Errors.swift" \
    "$repo_root/FSNotesCore/Git/commons/Signature.swift" \
    "$repo_root/FSNotesCore/Git/commons/Strings.swift" \
    "$repo_root/FSNotes/HistoryDiff.swift" \
    "$repo_root/Tests/GitHistory/Support.swift" \
    "$repo_root/Tests/GitHistory/Integration.swift" \
    "$test_build/libgit2/libgit2.a" -lz -liconv -framework Security \
    -o "$test_build/integration"
"$test_build/integration"
