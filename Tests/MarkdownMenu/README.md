Run `bash Tests/MarkdownMenu/run.sh` on macOS. The suite compiles the production
Markdown context menu and heading/code actions with a small NSTextView app stub.
It checks action targets, editable Markdown gating, all heading levels, multi-line
and Unicode selections, CRLF preservation, embedded backticks, caret placement,
and code-block undo. Table checks cover hover sizing, native mouse coordinates,
grid boundaries, visible row counts, first-cell caret placement, Unicode/CRLF
paragraph separation, replacement, undo/redo, and note-switch protection.

Set `FSNOTES_MENU_DEMO=1` to open a small editor window for manual right-click
menu testing; hovering over Table opens the 12-column, 8-row size grid.
