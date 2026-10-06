# Metadata integration tests

Run `Tests/Metadata/run.sh` on macOS with Xcode's Swift compiler.
The runner compiles the production JSON-backed MetadataStore with its memory indexes and uses
isolated temporary directories and real Git repositories. No user preferences,
notes, installed applications or Git configuration are changed.

Coverage includes nested and empty folders, Markdown migration,
relative attachments in the root images directory and note links, recursive LFS
attribute configuration, virtual trash without a disk folder, untouched code blocks, Unicode/quoted names,
stable physical paths, metadata-only Git changes, folder promotion/reparenting,
cycle/name-collision rejection without partial changes, trash and folder deletion,
external snapshot restoration, preservation of external edits, malformed JSON and
folder-cycle rejection, independent memory indexes, index rebuilding on reopening,
missing-manifest protection, and interrupted migration before/after publication.
An additional 2,000-note library checks UUID lookups, sorted folder/root groups
(including trash), edits and deletion, external snapshot replacement, independent
instances, rejection of duplicate IDs without replacing valid indexes, and reopening.

The second executable compiles the production MetadataLibrary adapter with minimal
UI/model scaffolding and exercises actual file import, attachment copying, whole
directory links, rename, note and folder moves (including subtree identity and cross-library rejection),
duplication, persistent trash (including repeated deletion, empty notes),
permanent deletion of bodies and unshared attachments (including shared images and pasted resources), active-note protection,
missing bodies, malformed metadata, and rollback after failed metadata publication,
case-insensitive title collisions, restoration, reopening and snapshot recovery.
It does not replace the macOS/iOS application build checks or a live UI smoke test.

Explicit naming coverage rejects blank creation and rename without publishing metadata,
preserves source filenames during migration, and keeps stored names unchanged when
images, Markdown headings, or YAML titles change. Manual rename still persists aliases.
