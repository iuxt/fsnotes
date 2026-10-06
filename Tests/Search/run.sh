#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_build="$(mktemp -d "${TMPDIR:-/tmp}/fsnotes-search-tests.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT
swiftc "$repo_root/FSNotesCore/Business/SearchQuery.swift" \
    "$repo_root/FSNotes/View/SearchTextField.swift" \
    "$repo_root/Tests/Search/Support.swift" \
    "$repo_root/Tests/Search/Integration.swift" -o "$test_build/integration"
"$test_build/integration"
