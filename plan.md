# SSHot — Implementation Plan

## What It Is

A macOS menu bar app that monitors the clipboard for images and automatically uploads them to a remote server via SSH, replacing the clipboard with the remote file path.

**Target user**: Developers who SSH/mosh into remote machines and want to share screenshots with tools like Claude Code running on the remote.

## User Story

1. Take screenshot with CleanShot X → Cmd+C (image now in clipboard)
2. SSHot (running in menu bar, toggled ON) detects image in clipboard
3. Uploads to remote: `~/.paste/2026-03-17T103045.png` via `scp`
4. Replaces local clipboard with the remote path string
5. Switch to tmux → Cmd+V → path is ready to paste into Claude Code

**Key distinction from existing tools**: clipboard-first (not folder-watcher-based). Works with any screenshot tool that copies to clipboard (CleanShot X, Cmd+Ctrl+Shift+4, etc.).

## Tech Stack

- **Language**: Swift 6 (strict concurrency)
- **UI**: AppKit + SwiftUI hybrid — `NSStatusItem` for menu bar, SwiftUI for settings panel
- **No Dock icon**: `LSUIElement = YES` in `Info.plist`
- **Clipboard monitoring**: Poll `NSPasteboard.changeCount` every 150ms, check for image types
- **Upload**: `scp` via Foundation's `Process`
- **Config persistence**: `UserDefaults` under `com.cogell.sshot`
- **Launch at login**: `SMAppService` (macOS 13+ API)
- **Auto-updates**: Sparkle framework tied to GitHub Releases
- **Minimum macOS**: 14.0
- **Distribution**: GitHub Releases (`.dmg`) + Homebrew cask

## Features

### MVP
- [ ] Clipboard image detection (poll `NSPasteboard` for `public.png` / `public.tiff` / `NSImage`)
- [ ] 80ms grace delay before reading clipboard (handles "promised" lazy-loaded pasteboard data from apps like CleanShot X)
- [ ] Self-loop prevention via custom pasteboard marker type `com.cogell.sshot.marker` — prevents re-triggering when SSHot writes the path back to clipboard
- [ ] Extract image from clipboard as PNG
- [ ] SCP upload to configured remote host
- [ ] Timestamped remote filename: `~/.paste/YYYY-MM-DDTHHMMSS.png`
- [ ] Replace local clipboard with remote path string after upload
- [ ] Animated menu bar icon when upload fires (ambient feedback, no focus steal)
- [ ] macOS notification on success/failure

### Menu Bar UI
- [ ] Status icon (camera, dimmed/greyed when disabled)
- [ ] Toggle: Enabled / Disabled
- [ ] Last upload: path + timestamp (read-only, click to copy path again)
- [ ] Open Settings…
- [ ] Quit

### Settings Panel (SwiftUI, tabbed)
- [ ] **General tab**: SSH Host (default: `home`), Remote path (default: `~/.paste/`), Launch at Login toggle
- [ ] **About tab**: version, links to GitHub, update check via Sparkle

### Post-MVP
- [ ] Upload history list in menu (last N uploads, click to re-copy path)
- [ ] Multiple SSH host profiles
- [ ] Retry logic on upload failure
- [ ] `rsync` as alternative to `scp` (better for flaky connections)
- [ ] CLI companion (`sshot` binary): pipe stdin or pass file path, same upload logic, exits 0 on success

## Architecture

```
SSHot/
├── SSHotApp.swift              # @main entry point, NSApplication setup, LSUIElement
├── AppDelegate.swift           # App lifecycle, wires components together
├── StatusBarController.swift   # NSStatusItem, NSMenu, animated icon
├── ClipboardWatcher.swift      # 150ms NSPasteboard poller, self-loop guard
├── Uploader.swift              # scp via Process, async/await, error capture
├── Settings.swift              # UserDefaults-backed config (host, path)
├── SettingsView.swift          # SwiftUI tabbed settings panel
└── Assets.xcassets/            # App icon, menu bar icon (template image)
```

### Key design notes

- **Self-loop guard**: `ClipboardWatcher` writes a sentinel value (`com.cogell.sshot.marker`) to the pasteboard alongside the path string. On each poll, if this marker is present on the current pasteboard, skip processing. Learned from Trimmy's `com.steipete.trimmy` pattern.
- **Promised data grace delay**: After `changeCount` changes, wait 80ms before reading. CleanShot X and other apps may use NSPasteboard's lazy-loading ("promised") mechanism — reading too early returns empty data.
- **Polling interval**: 150ms (matches Trimmy's proven interval — fast enough to feel instant, low enough CPU impact).
- **Upload is async**: `Uploader` uses `async/await`; `StatusBarController` shows an in-progress state (spinner or animated icon) during upload.
- **`LSUIElement`**: Set in `Info.plist` to suppress Dock icon — pure menu bar app.
- **`SMAppService`**: Used for Launch at Login instead of old LaunchAgent plist approach.

## Distribution

- GitHub Actions CI: build `.app` → notarize → package `.dmg` → attach to GitHub Release on tag push
- Sparkle auto-update checks against GitHub Releases appcast
- Homebrew cask: `brew install --cask cogell/tap/sshot`
- MIT License

## Prior Art

- [claude-screenshot-uploader](https://github.com/mdrzn/claude-screenshot-uploader) — folder-watcher approach, xbar UI, bash script; does not handle clipboard images
- [claudecode-remote-server-copypaste-image](https://github.com/ooiyeefei/claudecode-remote-server-copypaste-image) — similar folder-watcher, rsync + launchd
- Ghostty [discussion #10517](https://github.com/ghostty-org/ghostty/discussions/10517) — proposed native terminal-level SSH image paste (not merged as of Feb 2026)
- [Trimmy](https://trimmy.app) — clipboard-monitoring menu bar app for trimming shell commands; informed our NSPasteboard polling strategy (150ms interval, 80ms grace delay, self-loop marker type, `LSUIElement`, `SMAppService`, Sparkle, animated icon pattern)

SSHot differentiates from the SSH uploaders by being clipboard-first. It differentiates from Trimmy by targeting a different clipboard content type (images vs text) and performing a network operation rather than local transformation.
