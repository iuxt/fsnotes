Run `bash Tests/MarkdownMenu/run.sh` on macOS. The suite compiles the production
Markdown context menu and heading/code actions with a small NSTextView app stub.
It checks action targets, editable Markdown gating, all heading levels, multi-line
and Unicode selections, CRLF preservation, embedded backticks, caret placement,
and code-block undo.
