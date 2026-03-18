---
status: completed
feature: mvp
created: 2026-03-17
completed: 2026-03-17
---

# SSHot — Implementation Plan

## What It Is

A macOS menu bar app that monitors the clipboard for images and automatically uploads them to a remote server via SSH, replacing the clipboard with the remote file path.

**Target user**: Developers who SSH/mosh into remote machines and want to share screenshots with tools like Claude Code running on the remote.

## User Story

1. Take screenshot with CleanShot X -> Cmd+C (image now in clipboard)
2. SSHot (running in menu bar, toggled ON) detects image in clipboard
3. Uploads to remote: `~/.paste/2026-03-17T103045_a3f2.png` via `scp`
4. Replaces local clipboard with the remote path string
5. Switch to tmux -> Cmd+V -> path is ready to paste into Claude Code

**Key distinction from existing tools**: clipboard-first (not folder-watcher-based). Works with any screenshot tool that copies to clipboard (CleanShot X, Cmd+Ctrl+Shift+4, etc.).

## Distribution Scope

- **GitHub Releases** (.dmg) + **Homebrew cask** only
- **Mac App Store: permanently out of scope** — the app launches `scp` as a subprocess via `Foundation.Process`, which is incompatible with App Sandbox. The sandbox entitlement is omitted entirely (not set to `false`). Hardened Runtime is enabled for notarization.

## Tech Stack

- **Language**: Swift 6 (strict concurrency)
- **UI**: AppKit + SwiftUI hybrid — `NSStatusItem` for menu bar, SwiftUI for settings panel
- **No Dock icon**: `LSUIElement = YES` in `Info.plist`
- **Clipboard monitoring**: Poll `NSPasteboard.general.changeCount` every 150ms on `@MainActor`. No TCC permission required — `NSPasteboard` is freely accessible on macOS (as of macOS 15; Apple may tighten this in future versions as they did on iOS).
- **Upload**: `/usr/bin/scp` via `Foundation.Process` (hardcoded path, not `PATH`-dependent). Note: OpenSSH 9.0+ defaults `scp` to SFTP protocol internally; `/usr/bin/scp` may change or be removed in future macOS. `sftp`/`rsync` transport is planned post-MVP.
- **Logging**: `os.Logger(subsystem: "com.cogell.sshot", category: ...)` — log clipboard events, upload start/end, SCP exit codes, errors. Viewable in Console.app. Note: as of Xcode 16.x, `os.Logger` is still not marked `Sendable` on any macOS version. Create separate Logger instances per isolation domain (one in `ClipboardWatcher`, one in `Uploader`) or mark with `nonisolated(unsafe)` to satisfy Swift 6.
- **Config persistence**: `UserDefaults` under `com.cogell.sshot`
- **Launch at login**: `SMAppService` (macOS 13+ API)
- **Auto-updates**: Sparkle framework tied to GitHub Releases
- **Minimum macOS**: 14.0
- **Project scaffolding**: XcodeGen (`project.yml` -> `xcodegen generate`)

## Features

### MVP

- [x] Clipboard image detection — poll `NSPasteboard.general.changeCount` at 150ms on main thread
- [x] Pasteboard type priority: check `public.png` first, fall back to `public.tiff` -> PNG conversion
- [x] 80ms grace delay after `changeCount` change (handles promised/lazy pasteboard data from CleanShot X)
- [x] `isProcessing` flag to prevent concurrent grace-delay sequences
- [x] Upload task cancellation on disable/quit
- [x] Self-loop prevention via custom pasteboard marker type `com.cogell.sshot.marker`
- [x] Extract image as PNG data
- [x] Remote directory preflight: `ssh mkdir -p` before every upload
- [x] SCP upload with `BatchMode=yes`, `StrictHostKeyChecking=accept-new`, `ConnectTimeout=10`
- [x] Process timeout: race SCP against 30-second timeout
- [x] Timestamped remote filename with 4-char random suffix
- [x] Replace local clipboard with remote path string after upload
- [x] Animated menu bar icon during upload
- [x] macOS notification on success/failure with error-specific guidance
- [x] Temp file lifecycle with deferred cleanup
- [x] One automatic retry on transient SCP failure
- [x] Image size guard (20MB max)

### Menu Bar UI

- [x] Status icon (camera template image, greyed when disabled)
- [x] Toggle: Enabled / Disabled
- [x] Last upload: path + timestamp (click to re-copy path to clipboard)
- [x] "Test Connection" — SSH connectivity check with error classification
- [x] Open Settings
- [x] Quit

### Settings Panel (SwiftUI, tabbed)

- [x] **General tab**: SSH Host, Remote Path, Identity File, Launch at Login toggle
- [x] **About tab**: version, links to GitHub, Sparkle update check button
- [x] Real-time validation with error display

### Post-MVP

- [ ] Upload history list in menu (last N uploads, click to re-copy path)
- [ ] Multiple SSH host profiles
- [ ] `sftp` or `rsync` as alternative transport
- [ ] CLI companion (`sshot` binary)

## Architecture

```
SSHot/
├── SSHotApp.swift              # @main, NSApplication
├── AppDelegate.swift           # wires ClipboardWatcher -> Uploader -> StatusBarController
├── StatusBarController.swift   # @MainActor, NSStatusItem, NSMenu, frame-swap animation
├── ClipboardWatcher.swift      # @MainActor, 150ms Timer, isProcessing guard, self-loop guard
├── Uploader.swift              # not @MainActor, async via terminationHandler + continuation
├── Settings.swift              # Sendable, nonisolated — reads UserDefaults at init
├── SettingsView.swift          # SwiftUI settings content hosted in NSWindow + NSHostingView
├── SettingsWindowController.swift  # NSWindow host for SwiftUI settings
├── NotificationManager.swift   # macOS notifications for success/failure
├── ProcessRunner.swift         # Shared async subprocess helper
├── SSHBaseArgs.swift           # Centralized SSH option construction
├── SSHotError.swift            # Error types and classification
├── PasteboardConstants.swift   # Pasteboard marker type constant
└── Assets.xcassets/            # app icon, menu bar icon frames (all Template Images)
```

## Concurrency Model (Swift 6)

`NSPasteboard` must be accessed on the main thread. The upload must NOT block the main thread. Bridge:

```
ClipboardWatcher (@MainActor)
  Timer fires on main run loop
  -> reads NSPasteboard (main thread)
  -> sets isProcessing = true
  -> stores Task handle from Task.detached { await uploader.upload(imageData: data) }
  -> on disable/quit: cancel stored Task handle

Uploader (not @MainActor)
  -> writes Data to temp file
  -> defer { delete temp file }
  -> runs /usr/bin/scp via Process with continuation bridge
  -> races upload against timeout using withThrowingTaskGroup
  -> on transient failure: retry once after 2s delay
  -> on completion: await MainActor.run { statusBarController.uploadDidFinish(...) }

StatusBarController (@MainActor)
  -> updates NSMenu, stops animation, writes path to NSPasteboard
```

## Prior Art

- [claude-screenshot-uploader](https://github.com/mdrzn/claude-screenshot-uploader) — folder-watcher, xbar, bash; no clipboard support
- [claudecode-remote-server-copypaste-image](https://github.com/ooiyeefei/claudecode-remote-server-copypaste-image) — folder-watcher, rsync + launchd
- Ghostty [discussion #10517](https://github.com/ghostty-org/ghostty/discussions/10517) — proposed terminal-level SSH image paste
- [Trimmy](https://trimmy.app) — clipboard-monitoring menu bar app; informed polling strategy
