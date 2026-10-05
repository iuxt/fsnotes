Run `bash Tests/Editing/run.sh` on macOS. It compiles the production autosave
scheduler and preview image renderer, with no application UI or package setup.

Checks cover rapid switching between notes, per-note coalescing, writes arriving
while saving, synchronous restore superseding queued edits, and parent-relative
image previews. Ordinary previews preserve distinct images even when they have the same basename.
Web exports verify that repeated images reuse the filename expected by uploaders
and every local image is inside the exported page's directory.
Production attributed-string methods also verify shared attachment retention,
undo snapshots and Markdown-normalized history comparisons for images and tasks.
