# Markdown preview memory and performance benchmark

Run on macOS with full Xcode:

```sh
python3 Tests/PreviewPerformance/run.py
```

The runner copies the current source into `.build/preview-performance/source`,
adds instrumentation to that copy, and builds the real FSNotes application in
Release mode. Its bundle identifier is `es.fsnotes.previewbenchmark`; its sandbox,
preferences and generated note workspace are isolated from the installed app.
The shipping Swift sources and the user's note library are not modified.

The test covers:

- The native editor with a small synthetic note.
- Opening a small note preview and switching 50 times between ten notes.
- Another 200 switches to check whether WebKit memory reaches a plateau.
- Creating and releasing the preview 30 times, with weak references checking lifetime.
- Five loads each of a roughly 525 KiB long note, 120 Swift code blocks (3,600 lines),
  and 20 Mermaid flowcharts.
- Opening and closing five independent preview windows, checking weak references
  to their controllers, text views, text processors and web views. Any retained
  controller, text view or processor fails the benchmark after the cleanup delay;
  WebKit views must all release after the final ten-second cooldown.
- Opening two windows for the same note, closing one without unregistering the
  other, then exercising the real edit handler and checking that close invalidates
  the undo and tag timers. Both windows must release their objects.
- A ten-second cooldown after returning to the editor.
- 100 native Markdown parses each of small and long content using the production
  renderer. Generated HTML must match the recorded fixture hashes. Physical
  footprint growth between iterations 10 and 100 must stay below 8 MiB;
  the previously leaking renderer grew about 360 MiB in the long fixture.

The output lives in `.build/preview-performance/`: `results.json`, `runtime.log`,
`summary.json`, `leaks.txt`, and `parser-current.jsonl`. Reuse the built app
with `--run-only`. Use `--parser-only` for the native parser regression; it needs
an existing Release `libcmark_gfm.o` and generated module map.

The preview timing includes editor fill, navigation, syntax highlighting, Mermaid
completion and two animation frames. The readiness polling interval is 20 ms,
so these measurements are coarse end-to-end latencies, not exact display timestamps.
Each load includes a unique DOM marker, preventing a previous document from being
mistaken for the new render. A frame timeout is recorded as a benchmark failure.
Window lifetime checks use a separate delay, not the frame timing measurement.
Timer-driven actions and diagnostic events use explicit autorelease pools: an idle
AppKit event loop can otherwise keep the most recent view autoreleased until the
next window event, contaminating a weak-reference lifetime check. After programmatic
window close, an empty application event also advances AppKit's event loop and drains
its outer pool before the lifetime assertion. This is test instrumentation only.
The readiness check also requires one copy button per ordinary code block.
The main-thread delay is measured by a 20 ms timer. The benchmark activates its
main window before timing; keep it visible and do not run heap profiling during
render measurements, since suspension or background frame throttling invalidates them.

Memory samples use RSS every 200 ms. RSS sums can count shared pages more than once;
they are not the same metric as physical footprint. Parser physical footprint is
measured with `TASK_VM_INFO`. Instrumentation in the temporary app queries WebKit
diagnostic PID getters to identify its content, GPU and network processes; these
private getters are used only in the test copy and are never added to the shipping app.
The raw samples also retain new-process candidates to expose any attribution gap.

This is a synthetic benchmark on the current machine, not an Electron comparison.
MathJax is disabled; large-image workloads and prolonged typing/scrolling are not covered.
The edit regression starts the real undo/tag timers, but does not measure typing latency.
