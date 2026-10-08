#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_build="$(mktemp -d "${TMPDIR:-/tmp}/fsnotes-inline-markdown.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT
derived_data="${FSNOTES_DERIVED_DATA:-$repo_root/.build}"
swiftc "$repo_root/FSNotes/MarkdownEditorStyle.swift" \
    "$repo_root/FSNotes/MarkdownPresentation.swift" \
    "$repo_root/FSNotesCore/Business/Markdown.swift" \
    "$repo_root/FSNotes/InlineMarkdownLayout.swift" \
    "$repo_root/FSNotes/View/EditTextView+Images.swift" \
    "$repo_root/FSNotes/View/EditTextView+Code.swift" \
    "$repo_root/FSNotes/MarkdownTable.swift" \
    "$repo_root/FSNotes/InlineTableLayout.swift" \
    "$repo_root/FSNotes/LayoutManager.swift" \
    "$repo_root/FSNotes/View/InlineTableEditorView.swift" \
    "$repo_root/FSNotes/View/EditTextView+Tables.swift" \
    "$repo_root/Tests/InlineTables/Support.swift" \
    "$repo_root/Tests/InlineMarkdown/Integration.swift" "$derived_data/Build/Products/Debug/libcmark_gfm.o" \
    -Xcc "-fmodule-map-file=$derived_data/Build/Intermediates.noindex/GeneratedModuleMaps/libcmark_gfm.modulemap" \
    -o "$test_build/integration"
"$test_build/integration"
