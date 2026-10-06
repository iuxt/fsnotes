# FSNotes

[简体中文](README_zh_CN.md) · [繁體中文](README_zh_TW.md)

**Own your notes. Find them instantly.**

FSNotes is a fast, native notes app for macOS and iOS. It gives you a focused writing experience while keeping every note in portable Markdown or plain-text files—not a proprietary database.

<img src="https://fsnot.es/img/fsnotes7/FSNotes7_macOS_Dark.webp?v=2" alt="FSNotes for macOS in Dark Mode" style="max-width:100%;">

## Why choose FSNotes

- **No lock-in.** Open and edit your notes with any compatible app, now or years from now.
- **Fast at any scale.** Search and navigate smoothly across collections of 10,000+ notes.
- **Built around your workflow.** Use multiple folders, external editors, iCloud Drive, Dropbox, and optional Git backups.
- **More than basic Markdown.** Connect ideas with tags and `[[links]]`, render code, Mermaid diagrams, and MathJax.

**Buy FSNotes and get regular updates through the App Store.**

<a href="https://itunes.apple.com/app/fsnotes/id1277179284">
	<img src="https://fsnot.es/img/badge-download-on-the-mac-app-store.svg" alt="Buy FSNotes on the Mac App Store">
</a>
<a href="https://itunes.apple.com/app/fsnotes-manager/id1346501102">
	<img src="https://fsnot.es/img/badge-download-on-the-app-store.svg" alt="Buy FSNotes on the App Store">
</a>

## FSNotes for iOS

<img width="300" alt="FSNotes for iOS" src="https://fsnot.es/img/fsnotes7/FSNotes7_iOS.webp?v=2"> <img width="300" alt="FSNotes for iOS in Dark Mode" src="https://fsnot.es/img/fsnotes7/FSNotes7_iOS_Dark.webp?v=2">

## Open source

FSNotes is written in **Swift 5** and released under the MIT license. App Store purchases support its continued development.

## GitHub Actions releases

Push a tag to build macOS apps and publish them to the matching GitHub Release:

```bash
git tag v7.3.4
git push origin v7.3.4
```

The workflow builds with Xcode 26.2 on an Apple Silicon runner. Packages require an Apple Silicon
Mac running macOS 15 or later to cover the bundled Git tools' system requirements. Once the build succeeds,
it uploads `FSNotes-<tag>-macos-arm64.zip` and its SHA-256 checksum.
No additional secrets are required. Rerunning the workflow replaces assets in the same Release.
Version tags such as `v7.3.4` or `v7.3.4-beta.1` set the app version to `7.3.4`;
the Actions run number supplies the build number. Other tags use the project's app version.
Version tags with a `-` suffix create prereleases. Unsafe filename characters in tags become `_`.

Extract the ZIP and drag `FSNotes.app` into `/Applications`. Git and Git LFS are bundled.
These builds use ad-hoc signatures and are not notarized. If macOS blocks the app, allow it in
System Settings → Privacy & Security → Open Anyway.

To package locally with Xcode and Git LFS installed, run
`bash Scripts/package-release.sh v7.3.4 "$(uname -m)"`.
Packages are written to `.build/release/dist/`; the build log is `.build/release/build.log`.
