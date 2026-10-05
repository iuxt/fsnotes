#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_build="$(mktemp -d "${TMPDIR:-/tmp}/fsnotes-editing-tests.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT
swiftc "$repo_root/FSNotesCore/Business/NoteAutosave.swift" \
    "$repo_root/FSNotesCore/Business/PreviewImages.swift" \
    "$repo_root/FSNotesCore/Extensions/NSAttributedStringKey+.swift" \
    "$repo_root/FSNotesCore/Extensions/NSMutableAttributedString+.swift" \
    "$repo_root/FSNotesCore/Extensions/NSTextCheckingResult+.swift" \
    "$repo_root/FSNotes/HistoryDiff.swift" \
    "$repo_root/Tests/Editing/Support.swift" \
    "$repo_root/Tests/Editing/Integration.swift" -o "$test_build/integration"
"$test_build/integration"
