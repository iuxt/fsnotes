#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_build="$(mktemp -d "${TMPDIR:-/tmp}/fsnotes-rename-tests.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT
swiftc "$repo_root/FSNotes/View/NameTextField.swift" \
    "$repo_root/FSNotesCore/Business/MetadataStore.swift" \
    "$repo_root/Tests/Rename/Integration.swift" -o "$test_build/integration"
"$test_build/integration"
