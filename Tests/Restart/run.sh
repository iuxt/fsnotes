#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_build="$(mktemp -d "${TMPDIR:-/tmp}/fsnotes-restart-tests.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT
swiftc "$repo_root/FSNotes/Helpers/ApplicationRelaunch.swift" \
    "$repo_root/FSNotes/Helpers/FileWatcher.swift" \
    "$repo_root/FSNotes/Helpers/FileWatcherEvent.swift" \
    "$repo_root/Tests/Restart/Integration.swift" -o "$test_build/integration"
"$test_build/integration"
