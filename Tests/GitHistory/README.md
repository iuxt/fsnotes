# Git history integration tests

These tests compile the production repository, commit, and tree wrappers against
libgit2 and exercise temporary repositories. `Support.swift` supplies only the
unrelated app types needed to compile those wrappers; no Git operations are mocked.

Run with the libgit2 source from the project's resolved `swift-cgit2` checkout:

```sh
Tests/GitHistory/run.sh /path/to/DerivedData/SourcePackages/checkouts/swift-cgit2/libgit2
```

Requires Xcode's Swift compiler and CMake. The runner builds in a temporary directory
and installs nothing. Coverage includes empty repositories, initial commits,
file-specific history, merged branches, full and abbreviated commit lookup, invalid
IDs, literal and Unicode paths, staged and unstaged edits, unchanged index and HEAD,
deleted/recreated files, TextBundle content with preserved assets, symbolic links,
separated Git storage, subject-only commit messages, Unicode commit bodies,
workspace folder validation and portable colocated Git history after moving the library,
read-only and empty-file previews, and line differences with duplicate/Unicode lines.
