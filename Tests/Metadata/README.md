# Metadata integration tests

Run `Tests/Metadata/run.sh` on macOS with Xcode's Swift compiler.
The runner compiles the production MetadataStore against system SQLite and uses
isolated temporary directories and real Git repositories. No user preferences,
notes, installed applications or Git configuration are changed.

Coverage includes nested and empty folders, Markdown and TextBundle migration,
relative attachments and note links, untouched code blocks, Unicode/quoted names,
stable physical paths, metadata-only Git changes, trash and folder deletion,
external snapshot restoration, preservation of external edits, malformed JSON and
folder-cycle rejection, independent indexes, deleted/corrupt index rebuilding,
missing-manifest protection, and interrupted migration before/after publication.

The second executable compiles the production MetadataLibrary adapter with minimal
UI/model scaffolding and exercises actual file import, attachment copying, whole
directory links, rename, move, duplication, persistent trash (including repeated deletion, empty notes and bundles),
case-insensitive title collisions, restoration, reopening and snapshot recovery.
It does not replace the macOS/iOS application build checks or a live UI smoke test.
