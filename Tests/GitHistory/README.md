# Git history integration tests

These tests compile the production repository, commit, and tree wrappers against
libgit2 and exercise temporary repositories. `Support.swift` supplies only the
unrelated app types needed to compile those wrappers; no Git operations are mocked.

Run with the libgit2 source from the project's resolved `swift-cgit2` checkout:

```sh
Tests/GitHistory/run.sh /path/to/DerivedData/SourcePackages/checkouts/swift-cgit2/libgit2
```

Requires Xcode's Swift compiler, CMake and `git-lfs`. The runner builds in a temporary directory
and installs nothing. Coverage includes empty repositories, initial commits,
file-specific history, merged branches, full and abbreviated commit lookup, invalid
IDs, literal and Unicode paths, staged and unstaged edits, unchanged index and HEAD,
deleted/recreated files, nested Markdown content with preserved images, symbolic links,
subject-only commit messages, Unicode commit bodies,
workspace folder validation, portable colocated Git history after moving the library,
cloning through a temporary folder with history restored into the workspace,
read-only and empty-file previews, and line differences with duplicate/Unicode lines.

The LFS executable compiles the production clean/smudge filter and verifies actual
libgit2 staging, recursive image paths, SHA-256 pointers and object storage, empty
images, ordinary note blobs, clean status, checkout, corrupt-object rejection,
and Git LFS push/pull through a temporary local bare remote and fresh clone.
The runner embeds the LFS client beside its executables and runs them with the
system-only PATH used by Finder, so transfers also verify bundled helper discovery.
It repeats the LFS tests inside a signed sandboxed app, using the production helper
embedding script and entitlements, to verify image push/pull under App Sandbox.

The sync executable compiles the production Project Git adapter and all repository
wrappers. It checks an empty remote's first push, no-change sync, pull before local
commit with unrelated local edits, final remote content, and stopping on conflicting
uncommitted edits without changing HEAD, deleting local edits or pushing.
Only UI and settings are scaffolded. Its temporary history cache uses a unique name
and is removed on exit; existing application caches are untouched.
