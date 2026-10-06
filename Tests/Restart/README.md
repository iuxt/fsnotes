# Restart regression checks

Run `bash Tests/Restart/run.sh` on macOS. The integration test uses a disposable
process and launcher to verify that relaunch waits for the old process to exit,
requests a new app instance, and passes paths with spaces, Unicode, quotes and
shell metacharacters literally. It also verifies that an empty file watch list
does not crash and that a valid watcher receives events before and after a
restart. It does not launch FSNotes or reset user data.

For an end-to-end check with a disposable workspace and app profile, click Reset
Caches and Reset Settings in Advanced preferences. Each should exit cleanly and
relaunch once. Reset Caches should rebuild the sidebar and project caches. Reset
Settings should clear preferences and window/bookmark state, then show the
workspace chooser on relaunch. Notes and workspace metadata should remain intact.
