# Architecture

SSHot is a single-process macOS menu bar app built with Swift 6 strict concurrency. It uses AppKit for the menu bar and SwiftUI for the settings panel.

## Component Overview

```
┌─────────────────────────────────────────────────────┐
│                    SSHotApp                          │
│                   (@main entry)                      │
└──────────────────────┬──────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────┐
│                  AppDelegate                         │
│        Wires all components together                 │
│     Initializes Sparkle updater                      │
└───┬──────────┬──────────┬──────────┬────────────────┘
    │          │          │          │
    ▼          ▼          ▼          ▼
┌────────┐ ┌────────┐ ┌────────┐ ┌──────────────────┐
│Clipboard│ │Uploader│ │Status  │ │Notification      │
│Watcher  │ │        │ │Bar     │ │Manager           │
│         │ │        │ │Control.│ │                  │
└────┬───┘ └────────┘ └────────┘ └──────────────────┘
     │          ▲          ▲
     │          │          │
     └──────────┴──────────┘
      image data    result callbacks
```

## Data Flow

1. **ClipboardWatcher** polls `NSPasteboard.general.changeCount` every 150ms
2. On change: waits 80ms grace period, extracts PNG data from clipboard
3. Dispatches upload via `Task.detached` to **Uploader** (off main thread)
4. **Uploader** writes PNG to temp file, runs `ssh mkdir -p`, then `scp` with timeout race
5. On success: calls back to **StatusBarController** on `@MainActor`
6. **StatusBarController** writes the remote path to clipboard (with self-loop marker) and updates the menu
7. **NotificationManager** posts a macOS notification for success or failure

## Isolation Domains

| Component | Isolation | Why |
|-----------|-----------|-----|
| SSHotApp | @MainActor | App entry point |
| AppDelegate | @MainActor | NSApplicationDelegate requirement |
| ClipboardWatcher | @MainActor | NSPasteboard must be accessed on main thread |
| StatusBarController | @MainActor | NSStatusItem and NSMenu are main-thread-only |
| NotificationManager | @MainActor | UI feedback coordination |
| SettingsWindowController | @MainActor | NSWindow management |
| Uploader | nonisolated | SCP must not block main thread |
| Settings | Sendable struct | Captured as value type before crossing isolation boundaries |
| ProcessRunner | nonisolated | Subprocess execution |

## Process Management

SSHot shells out to `/usr/bin/scp` and `/usr/bin/ssh` (hardcoded paths, not PATH-dependent). Subprocesses are managed through `Foundation.Process` with a continuation bridge pattern:

- `Process.terminationHandler` resumes a `CheckedThrowingContinuation`
- `OSAllocatedUnfairLock<Bool>` prevents double-resume when timeout and termination race
- `withThrowingTaskGroup` races SCP against a 30-second timeout
- `withTaskCancellationHandler` calls `process.terminate()` for structured cancellation

## Key Patterns

**Self-loop prevention**: When SSHot writes a path back to the clipboard, it includes a custom marker type (`com.cogell.sshot.marker`). ClipboardWatcher checks for this marker and skips processing if present.

**Grace delay**: CleanShot X and other tools use lazy/promised pasteboard data. SSHot waits 80ms after a clipboard change before reading, with up to 3 restarts (max 320ms) if the change count keeps incrementing.

**Settings snapshot**: `Settings` is a `Sendable` struct that captures UserDefaults values at construction time. This allows safe crossing of isolation boundaries — the Uploader receives an immutable snapshot, not a reference to shared mutable state.

## Dependencies

| Dependency | Purpose | Integration |
|------------|---------|-------------|
| Sparkle | Auto-updates via GitHub Releases | SPM package, `SPUStandardUpdaterController` |
| XcodeGen | Project file generation from `project.yml` | Build tooling only |
