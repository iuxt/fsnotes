#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_build="$(mktemp -d "${TMPDIR:-/tmp}/fsnotes-markdown-menu.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT
swiftc "$repo_root/FSNotes/View/EditTextView+MarkdownMenu.swift" \
    "$repo_root/Tests/MarkdownMenu/Support.swift" \
    "$repo_root/Tests/MarkdownMenu/Integration.swift" -o "$test_build/integration"
"$test_build/integration"
