# Metadata integration tests

Run `Tests/Metadata/run.sh` on macOS with Xcode's Swift compiler.
The runner compiles the production JSON-backed MetadataStore with its memory indexes and uses
isolated temporary directories and real Git repositories. No user preferences,
notes, installed applications or Git configuration are changed.

Coverage includes nested and empty folders, Markdown migration,
relative attachments in the root images directory and note links, recursive LFS
attribute configuration, virtual trash without a disk folder, untouched code blocks, Unicode/quoted names,
stable physical paths, metadata-only Git changes, trash and folder deletion,
external snapshot restoration, preservation of external edits, malformed JSON and
folder-cycle rejection, independent memory indexes, index rebuilding on reopening,
missing-manifest protection, and interrupted migration before/after publication.
An additional 2,000-note library checks UUID lookups, sorted folder/root groups
(including trash), edits and deletion, external snapshot replacement, independent
instances, rejection of duplicate IDs without replacing valid indexes, and reopening.

The second executable compiles the production MetadataLibrary adapter with minimal
UI/model scaffolding and exercises actual file import, attachment copying, whole
directory links, rename, move, duplication, persistent trash (including repeated deletion, empty notes),
case-insensitive title collisions, restoration, reopening and snapshot recovery.
It does not replace the macOS/iOS application build checks or a live UI smoke test.
