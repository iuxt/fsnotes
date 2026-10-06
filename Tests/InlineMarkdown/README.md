Run `bash Tests/InlineMarkdown/run.sh` on macOS after building the Debug app into
`.build`. Set `FSNOTES_DERIVED_DATA` to use another derived-data directory. The
suite links the same cmark-gfm parser as the app and compiles the production
presentation planner, styles, TextKit layout and table editor with small app stubs.

Checks cover UTF-8 to UTF-16 source positions, CRLF, headings, emphasis, strike,
inline and fenced code, wiki and reference links, escaped punctuation, HTML tags
and entities, footnotes, list and task markers, caret and selection transitions,
focus changes, incomplete syntax, note switching, source preservation, image
sizing and completed-task styling. The existing InlineTables and Editing suites
cover table editing and attachment-to-source serialization.

Code fences and language labels stay visible while reading, editing and unfocused.
Checks also verify that entering or leaving a code block preserves its line position
and that mouse insertion can reach the end of the closing backticks.

Set `FSNOTES_MARKDOWN_PREVIEW` to an absolute PNG path to capture the actual
TextKit rendering for visual inspection.

Run `bash Tests/InlineMarkdown/visual.sh` to capture the production document and
native table editor in light and dark appearances, both reading and editing.
Images are written to `.build/MarkdownPreviews` by default; set
`FSNOTES_VISUAL_OUTPUT` to choose another output directory.
