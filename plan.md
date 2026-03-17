# SSHot — Implementation Plan

## What It Is

A macOS menu bar app that monitors the clipboard for images and automatically uploads them to a remote server via SSH, replacing the clipboard with the remote file path.

**Target user**: Developers who SSH/mosh into remote machines and want to share screenshots with tools like Claude Code running on the remote.

## User Story

1. Take screenshot with CleanShot X → Cmd+C (image now in clipboard)
2. SSHot (running in menu bar, toggled ON) detects image in clipboard
3. Uploads to remote: `~/.paste/2026-03-17T103045_a3f2.png` via `scp`
4. Replaces local clipboard with the remote path string
5. Switch to tmux → Cmd+V → path is ready to paste into Claude Code

**Key distinction from existing tools**: clipboard-first (not folder-watcher-based). Works with any screenshot tool that copies to clipboard (CleanShot X, Cmd+Ctrl+Shift+4, etc.).

## Distribution Scope

- **GitHub Releases** (.dmg) + **Homebrew cask** only
- **Mac App Store: permanently out of scope** — the app launches `scp` as a subprocess via `Foundation.Process`, which is incompatible with App Sandbox. App Sandbox must be explicitly disabled.

## Tech Stack

- **Language**: Swift 6 (strict concurrency)
- **UI**: AppKit + SwiftUI hybrid — `NSStatusItem` for menu bar, SwiftUI for settings panel
- **No Dock icon**: `LSUIElement = YES` in `Info.plist`
- **Clipboard monitoring**: Poll `NSPasteboard.changeCount` every 150ms on `@MainActor`
- **Upload**: `/usr/bin/scp` via `Foundation.Process` (hardcoded path, not `PATH`-dependent)
- **Config persistence**: `UserDefaults` under `com.cogell.sshot`
- **Launch at login**: `SMAppService` (macOS 13+ API)
- **Auto-updates**: Sparkle framework tied to GitHub Releases
- **Minimum macOS**: 14.0
- **Project scaffolding**: XcodeGen (`project.yml` → `xcodegen generate`)

## Features

### MVP
- [ ] Clipboard image detection — poll `NSPasteboard.changeCount` at 150ms on main thread
- [ ] Pasteboard type priority: check `public.png` first (no conversion), fall back to `public.tiff` → convert via `NSBitmapImageRep.representation(using: .png, properties: [:])`. Nil result = no image, skip.
- [ ] 80ms grace delay after `changeCount` change before reading (handles promised/lazy pasteboard data from CleanShot X). Capture `changeCount` before delay, re-compare after — if changed again, restart delay.
- [ ] `isProcessing: Bool` flag on `ClipboardWatcher` to prevent overlapping uploads during slow network
- [ ] Self-loop prevention via custom pasteboard marker type `com.cogell.sshot.marker` — skip processing if marker is present on current pasteboard
- [ ] Extract image as PNG data
- [ ] Remote directory preflight: `ssh <host> 'mkdir -p <remotePath>'` before first upload (gate with `UserDefaults` bool `remoteDirectoryCreated`, reset when host/path settings change)
- [ ] SCP upload: `/usr/bin/scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10`
- [ ] Process timeout: terminate `scp` after 30s, surface error
- [ ] Timestamped remote filename with 4-char random suffix to avoid sub-second collisions: `~/.paste/YYYY-MM-DDTHHMMSS_<xxxx>.png`
- [ ] Remote path passed verbatim to `scp` as `host:remotepath/filename.png` — relies on remote shell for `~` expansion. Validate in Settings: reject paths with spaces or shell metacharacters.
- [ ] Replace local clipboard with remote path string after upload
- [ ] Animated menu bar icon during upload: 3–4 template PNG frames swapped on 150–200ms `Timer`; images must be "Template Image" in Assets.xcassets for dark/light mode tinting
- [ ] macOS notification on success/failure — request `UNUserNotificationCenter` authorization at first launch; if denied, fall back to "Last: Failed" in menu item text

### Menu Bar UI
- [ ] Status icon (camera template image, greyed when disabled)
- [ ] Toggle: Enabled / Disabled
- [ ] Last upload: path + timestamp (click to re-copy path to clipboard)
- [ ] "Test Connection" — runs `ssh -q -o BatchMode=yes -o ConnectTimeout=5 <host> exit` and reports pass/fail inline
- [ ] Open Settings…
- [ ] Quit

### Settings Panel (SwiftUI, tabbed)
- [ ] **General tab**: SSH Host (default: `home`), Remote path (default: `~/.paste/`), optional Identity File path (`-i`), Launch at Login toggle
- [ ] **About tab**: version, links to GitHub, Sparkle update check button

### Post-MVP
- [ ] Upload history list in menu (last N uploads, click to re-copy path)
- [ ] Multiple SSH host profiles
- [ ] `rsync` as alternative transport
- [ ] CLI companion (`sshot` binary)

## Architecture

```
SSHot/
├── SSHotApp.swift              # @main, NSApplication, requests notification auth at first launch
├── AppDelegate.swift           # wires ClipboardWatcher → Uploader → StatusBarController
├── StatusBarController.swift   # @MainActor, NSStatusItem, NSMenu, frame-swap animation
├── ClipboardWatcher.swift      # @MainActor, 150ms Timer, isProcessing guard, self-loop guard
├── Uploader.swift              # not @MainActor, async via withCheckedThrowingContinuation
├── Settings.swift              # UserDefaults-backed (host, remotePath, identityFile, remoteDirectoryCreated)
├── SettingsView.swift          # SwiftUI tabbed settings, NSApp.activate() on open
└── Assets.xcassets/            # app icon, menu bar icon frames (all Template Images)
```

## Concurrency Model (Swift 6)

`NSPasteboard` must be accessed on the main thread. The upload must NOT block the main thread. Bridge:

```
ClipboardWatcher (@MainActor)
  Timer fires on main run loop
  → reads NSPasteboard (main thread ✓)
  → sets isProcessing = true
  → Task { await uploader.upload(imageData: data) }  // leaves main actor

Uploader (not @MainActor)
  → runs /usr/bin/scp via Process
  → Process.waitUntilExit() inside withCheckedThrowingContinuation
     (runs on cooperative thread pool, does not block main)
  → on completion: await MainActor.run { statusBarController.uploadDidFinish(...) }

StatusBarController (@MainActor)
  → updates NSMenu, stops animation, writes path to NSPasteboard
```

`Process.waitUntilExit()` is synchronous — wrap with `withCheckedThrowingContinuation` + `process.terminationHandler` to avoid blocking the cooperative thread pool thread. Use a `DispatchQueue` to run `waitUntilExit` off the cooperative pool if needed.

## XcodeGen `project.yml` Skeleton

```yaml
name: SSHot
options:
  deploymentTarget:
    macOS: "14.0"
  xcodeVersion: "16"
  swiftVersion: "6.0"

packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: 2.0.0

targets:
  SSHot:
    type: application
    platform: macOS
    sources: SSHot/
    info:
      path: SSHot/Info.plist
      properties:
        LSUIElement: true                        # no Dock icon
        SUPublicEDKey: "$(SPARKLE_PUBLIC_KEY)"   # set via xcconfig or build setting
        NSHumanReadableCopyright: "© 2026 cogell"
    entitlements:
      path: SSHot/SSHot.entitlements
      properties:
        com.apple.security.app-sandbox: false    # required for scp subprocess
    dependencies:
      - package: Sparkle
        product: Sparkle
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.cogell.sshot
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: "$(DEVELOPMENT_TEAM)"  # set in xcconfig
```

## scp Hardening (Uploader.swift)

```swift
// Always use absolute path — GUI app $PATH is not the shell $PATH
let scp = URL(fileURLWithPath: "/usr/bin/scp")

var args = [
    "-o", "BatchMode=yes",              // fail immediately if auth required, no password hang
    "-o", "StrictHostKeyChecking=accept-new",  // auto-accept new host keys, reject changed keys
    "-o", "ConnectTimeout=10",          // fail fast on unreachable host
]
if let identityFile = Settings.shared.identityFile {
    args += ["-i", identityFile]
}
args += [localFile.path, "\(host):\(remotePath)/\(filename)"]
```

## First-Run / Setup Checklist (for maintainers)

Before cutting the first release:

1. **Sparkle keys**: run `generate_keys` from Sparkle tools → store private key in password manager (never commit) → paste public key into `SPARKLE_PUBLIC_KEY` build setting
2. **appcast.xml**: host at GitHub Pages (`cogell.github.io/sshot/appcast.xml`) — Sparkle checks this URL for updates
3. **Developer ID cert**: export from Keychain as `.p12`, store in GitHub Actions secret `DEVELOPER_ID_P12` + `DEVELOPER_ID_P12_PASSWORD`
4. **Notarization**: store `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` as GitHub Actions secrets
5. **GitHub Actions CI**: on tag push → `xcodebuild archive` → notarize with `xcrun notarytool` → staple → create `.dmg` → attach to GitHub Release → update `appcast.xml`

## `.gitignore` (required for open source)

```
# Xcode
*.xcodeproj/
DerivedData/
*.xcworkspace/xcuserdata/
*.xcuserstate

# Secrets — never commit
*.p8
*.p12
sparkle_private_key*
xcconfig/*.local.xcconfig

# macOS
.DS_Store
```

## Prior Art

- [claude-screenshot-uploader](https://github.com/mdrzn/claude-screenshot-uploader) — folder-watcher, xbar, bash; no clipboard support
- [claudecode-remote-server-copypaste-image](https://github.com/ooiyeefei/claudecode-remote-server-copypaste-image) — folder-watcher, rsync + launchd
- Ghostty [discussion #10517](https://github.com/ghostty-org/ghostty/discussions/10517) — proposed terminal-level SSH image paste (not merged as of Feb 2026)
- [Trimmy](https://trimmy.app) — clipboard-monitoring menu bar app; informed polling strategy (150ms, 80ms grace delay, self-loop marker, `LSUIElement`, `SMAppService`, Sparkle, animated icon)

SSHot differentiates by being clipboard-first and having a proper native Swift menu bar UI.
