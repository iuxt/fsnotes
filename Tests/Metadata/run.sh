#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_build="$(mktemp -d "${TMPDIR:-/tmp}/fsnotes-metadata-tests.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT
swiftc "$repo_root/FSNotesCore/Business/MetadataStore.swift" \
    "$repo_root/Tests/Metadata/Integration.swift" -o "$test_build/integration"
"$test_build/integration"

swiftc "$repo_root/FSNotesCore/Business/MetadataStore.swift" \
    "$repo_root/FSNotesCore/Business/MetadataLibrary.swift" \
    "$repo_root/Tests/Metadata/AppSupport.swift" \
    "$repo_root/Tests/Metadata/AppIntegration.swift" -o "$test_build/adapter"
"$test_build/adapter"
