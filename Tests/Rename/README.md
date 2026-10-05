# Inline rename integration tests

Run `bash Tests/Rename/run.sh` on macOS. The runner compiles the production
NameTextField and MetadataStore and uses an offscreen AppKit window with an
isolated temporary library. It does not open or modify user notes or preferences.

Coverage includes selecting the stored name when a row displays a content heading,
Enter and Tab commits, Escape cancellation, focus-loss commits after selection
changes, late editing notifications, cell-reuse cancellation, stable UUID body
paths, unchanged contents, and name persistence after reopening the library.
