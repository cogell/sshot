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
- **Project scaffolding**: XcodeGen (`project.yml` → `xcodegen generate`)

## Features

### MVP
- [ ] Clipboard image detection — poll `NSPasteboard.general.changeCount` at 150ms on main thread. Use `ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Clipboard monitoring")` while enabled to prevent App Nap and timer coalescing without blocking idle system sleep (lid close). End the activity when toggled off.
- [ ] Pasteboard type priority: check `public.png` first (no conversion), fall back to `public.tiff` → convert via `NSBitmapImageRep.representation(using: .png, properties: [:])`. Nil result = no image, skip. TIFF data may contain multiple representations (high-DPI + low-DPI); using `NSBitmapImageRep(data:)` returns only the first representation — acceptable for MVP. Both the pasteboard read and TIFF-to-PNG conversion must happen on `@MainActor` (same as pasteboard access) before dispatching the resulting PNG `Data` to the upload task.
- [ ] 80ms grace delay after `changeCount` change before reading (handles promised/lazy pasteboard data from CleanShot X). Capture `changeCount` before delay, re-compare after — if changed again, restart delay. Cap at `maxGraceDelays = 4` total (initial + 3 restarts = max 320ms) to prevent infinite loops from chatty clipboard managers.
- [ ] `isProcessing: Bool` flag on `ClipboardWatcher` — set `true` at start of grace delay (not just upload start) to prevent concurrent grace-delay sequences. If a clipboard change occurs while `isProcessing` is true, silently drop it and log "Skipped: upload in progress". The user must re-copy after the current upload completes.
- [ ] Upload task cancellation: store the `Task` handle from the upload dispatch. On toggle to Disabled or app quit, cancel the task and terminate the SCP process via `withTaskCancellationHandler`. Prevents orphaned `scp` subprocesses and dangling continuations.
- [ ] Self-loop prevention via custom pasteboard marker type `com.cogell.sshot.marker` — skip processing if marker is present on current pasteboard
- [ ] Extract image as PNG data
- [ ] Remote directory preflight: run `/usr/bin/ssh <host> 'mkdir -p <remotePath>'` before every upload. `mkdir -p` is idempotent and takes <50ms over SSH — no caching flag needed, avoids stale-cache bugs if the remote directory is deleted.
- [ ] SCP upload: `/usr/bin/scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10`
- [ ] Process timeout: race `scp` against `Task.sleep(for: .seconds(30))` — if sleep wins, call `process.terminate()`, surface timeout error via notification
- [ ] Timestamped remote filename with 4-char random suffix to avoid sub-second collisions: `~/.paste/YYYY-MM-DDTHHMMSS_<xxxx>.png` (colons omitted from time portion for filesystem compatibility — do not "fix" to ISO 8601 `HH:MM:SS`)
- [ ] Remote path passed verbatim to `scp` as `host:remotepath/filename.png` — relies on remote shell for `~` expansion. Validate in Settings: reject paths with spaces or shell metacharacters. Also validate SSH host field: reject whitespace, semicolons, backticks, `$`, and other shell metacharacters.
- [ ] Replace local clipboard with remote path string after upload (no trailing newline — Cmd+V in terminal would add an extra blank line). Write the `com.cogell.sshot.marker` alongside the path string using `NSPasteboardItem`: construct an item, call `setString(_:forType:)` and `setData(_:forType:)` on the item, then `pasteboard.clearContents(); pasteboard.writeObjects([item])`. This is a single `writeObjects` call after clear, minimizing the race window vs. multiple separate `setString`/`setData` calls.
- [ ] Animated menu bar icon during upload: 3–4 template PNG frames swapped on 150–200ms `Timer`; images must be "Template Image" in Assets.xcassets for dark/light mode tinting
- [ ] macOS notification on success/failure — request `UNUserNotificationCenter` authorization at first launch; if denied, fall back to "Last: Failed" in menu item text. On SSH host key mismatch, surface specific error with guidance to run `ssh-keygen -R <host>`. On auth failure (passphrase-protected key without ssh-agent), surface specific guidance ("SSH key requires passphrase — ensure ssh-agent is running") instead of generic "upload failed". Parse SCP stderr and exit code to distinguish failure modes.
- [ ] Temp file lifecycle: write PNG `Data` to `FileManager.default.temporaryDirectory` with upload filename. Delete in `defer` block at the **outer scope** (after retry logic completes, not per-attempt) so the file persists across retries.
- [ ] One automatic retry with 2s delay on transient SCP failure (non-zero exit, not timeout). Surface error only after retry fails. Worst-case wall-clock budget: 30s timeout + 2s delay + 30s retry = 62s. This is intentional — the alternative (shorter overall cap) would prevent legitimate large uploads on slow links from completing on retry.
- [ ] Image size guard: skip images >20MB, surface notification explaining the skip. (Threshold configurable in Settings post-MVP.)

### Menu Bar UI
- [ ] Status icon (camera template image, greyed when disabled)
- [ ] Toggle: Enabled / Disabled
- [ ] Last upload: path + timestamp (click to re-copy path to clipboard)
- [ ] "Test Connection" — runs `/usr/bin/ssh -q -o BatchMode=yes -o ConnectTimeout=5 <host> exit` and reports pass/fail inline. On host key mismatch, show specific error with `ssh-keygen -R` guidance.
- [ ] Open Settings…
- [ ] Quit

### Settings Panel (SwiftUI, tabbed)
- [ ] **General tab**: SSH Host (default: `home`, validated: no whitespace/metacharacters), Remote path (default: `~/.paste/`, validated: no spaces/metacharacters), optional Identity File path (`-i`, validated: file exists on disk, is not a directory, does not end in `.pub`), Launch at Login toggle
- [ ] **About tab**: version, links to GitHub, Sparkle update check button
- [ ] **Implementation note**: Apple's `Settings` scene cannot be opened programmatically from an `NSMenu` action (no `Environment(\.openSettings)` available outside a SwiftUI view hierarchy). Use a plain `NSWindow` + `NSHostingView` wrapping the SwiftUI settings content instead. This avoids the `SettingsLink`-only limitation entirely. To bring the window forward: for `LSUIElement` apps, `NSApp.activate()` (macOS 14+) under cooperative activation may not reliably foreground the window. Workaround: temporarily set `NSApp.setActivationPolicy(.regular)`, activate, order window front, then restore `.accessory`.

### Post-MVP
- [ ] Upload history list in menu (last N uploads, click to re-copy path)
- [ ] Multiple SSH host profiles
- [ ] `sftp` or `rsync` as alternative transport (higher priority if Apple deprecates `/usr/bin/scp`)
- [ ] CLI companion (`sshot` binary)

## Architecture

```
SSHot/
├── SSHotApp.swift              # @main, NSApplication, requests notification auth at first launch
├── AppDelegate.swift           # wires ClipboardWatcher → Uploader → StatusBarController
├── StatusBarController.swift   # @MainActor, NSStatusItem, NSMenu, frame-swap animation
├── ClipboardWatcher.swift      # @MainActor, 150ms Timer, isProcessing guard, self-loop guard
├── Uploader.swift              # not @MainActor, async via terminationHandler + withCheckedThrowingContinuation
├── Settings.swift              # Sendable, nonisolated — reads UserDefaults at init, values captured before crossing isolation boundaries
├── SettingsView.swift          # SwiftUI settings content hosted in NSWindow + NSHostingView (not Settings scene)
└── Assets.xcassets/            # app icon, menu bar icon frames (all Template Images)
```

## Concurrency Model (Swift 6)

`NSPasteboard` must be accessed on the main thread. The upload must NOT block the main thread. Bridge:

```
ClipboardWatcher (@MainActor)
  Timer fires on main run loop
  → reads NSPasteboard (main thread ✓)
  → sets isProcessing = true
  → stores Task handle from Task.detached { [data] in await uploader.upload(imageData: data) }
    // Task.detached — NOT Task {} — because Task {} inherits @MainActor isolation from
    // ClipboardWatcher (SE-0420). With plain Task {}, code before the first await runs on main.
    // Task.detached ensures the entire upload runs off-main from the start.
  → on disable/quit: cancel stored Task handle

Uploader (not @MainActor)
  → writes Data to temp file
  → defer { delete temp file }  ← outer scope, survives retries
  → runs /usr/bin/scp via Process:
       withCheckedThrowingContinuation { continuation in
         let resumed = OSAllocatedUnfairLock(initialState: false)  // Sendable guard
         process.terminationHandler = { _ in
           if resumed.withLock({ let old = $0; $0 = true; return !old }) {
             continuation.resume()  // only if not already resumed by timeout
           }
         }
         do {
           try process.run()  // not launch() — launch() is deprecated since macOS 10.13
         } catch {
           // If run() throws (e.g. /usr/bin/scp missing), terminationHandler never fires.
           // We MUST resume the continuation here or the calling task hangs forever.
           if resumed.withLock({ let old = $0; $0 = true; return !old }) {
             continuation.resume(throwing: error)
           }
         }
       }
  → races upload against timeout using withThrowingTaskGroup:
       group.addTask {
         try await withTaskCancellationHandler {
           try await self.runSCP(process)  // wraps the continuation-based Process call
         } onCancel: {
           process.terminate()  // MUST be inside the child task, not the outer Task —
                                // Foundation.Process has no awareness of Swift cancellation
         }
       }
       group.addTask { try await Task.sleep(for: .seconds(30)); throw TimeoutError() }
       // Note: withTaskGroup implicitly awaits ALL children before returning, even after
       // cancelAll(). So the SCP child must respond to cancellation (via process.terminate()
       // triggering the terminationHandler → continuation.resume) or the group hangs.
       // Group is ThrowingTaskGroup<Void, Error> — both children return Void.
       // group.next() returns Void? and rethrows child errors.
       do {
         _ = try await group.next()            // first to finish wins (Void result)
         group.cancelAll()                     // cancels the loser
       } catch is TimeoutError {
         group.cancelAll()  // cancels SCP child → onCancel fires → process.terminate()
         throw TimeoutError()
       }
       // SCP errors (non-zero exit) propagate naturally — they are NOT TimeoutError,
       // so they fall through the do/catch and rethrow to the caller. This is intentional:
       // the caller's retry logic catches these for the one-retry-on-transient-failure path.
  → on transient failure (non-zero exit, not timeout): retry once after 2s delay
  → on completion: await MainActor.run { statusBarController.uploadDidFinish(...) }
  → withTaskCancellationHandler on outer Task.detached also calls process.terminate() for disable/quit cancellation

StatusBarController (@MainActor)
  → updates NSMenu, stops animation, writes path to NSPasteboard (no trailing newline)
```

**Critical concurrency notes**:
- Do NOT use `Process.waitUntilExit()` anywhere — it blocks the calling thread.
- The `terminationHandler` + continuation pattern has a **double-resume trap**: if a timeout fires and terminates the process, the `terminationHandler` still runs. Use `OSAllocatedUnfairLock<Bool>` (which is `Sendable`) to ensure the continuation is resumed exactly once. A non-`Sendable` guard will be rejected by Swift 6's strict concurrency checker since `terminationHandler` is `@Sendable`.
- Use `try process.run()` (not `launch()`) — `run()` throws on failure (e.g., `/usr/bin/scp` missing) and is the non-deprecated API. If `run()` throws, `terminationHandler` never fires — the `do/catch` inside the continuation must call `continuation.resume(throwing:)` to avoid hanging the task.
- Use `withThrowingTaskGroup` for the timeout race. `withTaskCancellationHandler { process.terminate() }` must wrap the SCP call **inside the group child task** — `Foundation.Process` has no awareness of Swift structured concurrency, so `group.cancelAll()` alone won't stop the process. Note that `withTaskGroup` implicitly awaits all children before returning, even after `cancelAll()`, so the SCP child must respond to cancellation promptly or the group hangs.

## XcodeGen `project.yml` Skeleton

```yaml
name: SSHot
options:
  deploymentTarget:
    macOS: "14.0"
  xcodeVersion: "1600"  # XcodeGen format: "0910", "1600", etc.

configs:
  Debug: debug
  Release: release

configFiles:
  Debug: xcconfig/Debug.xcconfig
  Release: xcconfig/Release.xcconfig

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
        SUFeedURL: "https://cogell.github.io/sshot/appcast.xml"
        CFBundleShortVersionString: "$(MARKETING_VERSION)"  # e.g. "1.0.0"
        CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"       # build number — Sparkle uses this for update comparison
        NSHumanReadableCopyright: "© 2026 cogell"
    entitlements:
      path: SSHot/SSHot.entitlements
      properties:
        # Sandbox entitlement is OMITTED, not set to false — omission is correct for
        # Developer ID distribution. Setting it to false can cause notarization rejection.
        com.apple.security.cs.disable-library-validation: $(DISABLE_LIBRARY_VALIDATION)
        # disable-library-validation is only needed during development (Apple Development cert).
        # For production (Developer ID cert), library validation works correctly.
        # Set DISABLE_LIBRARY_VALIDATION=YES in Debug xcconfig, NO in Release.
    dependencies:
      - package: Sparkle
        product: Sparkle
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.cogell.sshot
        ENABLE_HARDENED_RUNTIME: YES              # required for notarization
        SWIFT_VERSION: "6.0"                     # swiftVersion is not a valid XcodeGen option — set here instead
        SWIFT_STRICT_CONCURRENCY: complete       # explicit — Swift 6 implies it, but be clear
        CODE_SIGN_STYLE: Automatic
        MARKETING_VERSION: "1.0.0"
        CURRENT_PROJECT_VERSION: "1"             # bump on each build — Sparkle uses this for update comparison
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
    args += ["-i", identityFile, "-o", "IdentitiesOnly=yes"]  // IdentitiesOnly prevents SSH agent from trying other keys (avoids "too many auth failures" on servers with MaxAuthTries)
}
// host and remotePath are pre-validated in Settings (no whitespace, semicolons, backticks, $, etc.)
// Note: URL.path is deprecated — use localFile.path(percentEncoded: false) on macOS 13+
args += [localFile.path(percentEncoded: false), "\(host):\(remotePath)/\(filename)"]
```

## First-Run / Setup Checklist (for maintainers)

Before cutting the first release:

1. **Sparkle keys**: run `generate_keys` from Sparkle tools → store private key in password manager (never commit) → paste public key into `SPARKLE_PUBLIC_KEY` build setting
2. **appcast.xml**: commit to repo root, serve via GitHub Pages from `/docs` folder or `gh-pages` branch (`cogell.github.io/sshot/appcast.xml`). CI workflow updates this file on each release. Alternatively, point Sparkle at the raw GitHub URL.
3. **Developer ID cert**: export from Keychain as `.p12`, store in GitHub Actions secret `DEVELOPER_ID_P12` + `DEVELOPER_ID_P12_PASSWORD`
4. **Notarization**: store `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` as GitHub Actions secrets
5. **Hardened Runtime**: enabled in `project.yml` (`ENABLE_HARDENED_RUNTIME: YES`). Required for notarization. Sandbox entitlement is omitted entirely.
6. **xcconfig files**: commit `xcconfig/Debug.xcconfig` and `xcconfig/Release.xcconfig` to the repo (not gitignored). These define `DISABLE_LIBRARY_VALIDATION` (YES for Debug, NO for Release). Secrets (`DEVELOPMENT_TEAM`, `SPARKLE_PUBLIC_KEY`) go in `xcconfig/*.local.xcconfig` files which ARE gitignored. Add placeholder comments in the committed xcconfigs showing required keys.
7. **GitHub Actions CI**: on tag push → `xcodebuild archive` (Hardened Runtime on) → notarize with `xcrun notarytool` → staple → create `.dmg` → attach to GitHub Release → update `appcast.xml`

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
