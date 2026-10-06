Run `bash Tests/InlineTables/run.sh` on macOS after a Debug app build into `.build`
(or set `FSNOTES_DERIVED_DATA` to another derived-data directory). It compiles the production parser,
commands, renderer, TextKit layout manager, native cell editor and document editing
extension. Small stubs supply unrelated app settings and note metadata.

Checks exercise native cell input, Markdown escaping and whitespace preservation,
row and column insertion buttons, bottom append, Tab/Shift-Tab/Enter navigation,
hover controls, actual mouse events for row dragging, column deletion, selected
row deletion, undo/redo (including cell keyboard shortcuts), header retention,
resizing, long-table scroll retention, reusable cell input, header-to-body
typography, stable column widths during long input and note switching. Parser checks include Unicode, alignment, escaped
pipes, CRLF, fenced and indented code. Changes preserve surrounding note text.

To save a rendered editor image, set `FSNOTES_TABLE_PREVIEW` to an absolute PNG
path before running the script.
