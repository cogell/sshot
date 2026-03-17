#!/usr/bin/env bash
set -euo pipefail

# SSHot — Comprehensive Bead Creation Script
# Generates all epics, tasks, and subtasks with dependencies from plan.md
# Run from project root: bash scripts/create-beads.sh

cd "$(dirname "$0")/.."

echo "=== Creating SSHot beads from plan.md ==="
echo ""

# Helper: create issue and capture ID
create() {
  local id
  id=$(bd create "$@" --silent 2>/dev/null)
  echo "$id"
}

# ============================================================================
# EPIC 1: Project Scaffolding & Build Infrastructure
# ============================================================================

echo "--- Epic 1: Project Scaffolding ---"

E1=$(create "Project Scaffolding & Build Infrastructure" \
  -t epic -p 1 \
  -d "$(cat <<'DESC'
Set up the Xcode project skeleton, build configuration, entitlements, and asset catalog so that subsequent work can build and run immediately.

This epic is the foundation for everything else. Nothing can compile until this is done. The project uses XcodeGen (project.yml → xcodegen generate) rather than a committed .xcodeproj, which keeps the project file reproducible and merge-conflict-free.

Key decisions already made:
- Swift 6 with strict concurrency (SWIFT_VERSION=6.0, SWIFT_STRICT_CONCURRENCY=complete)
- Hardened Runtime enabled (required for notarization)
- App Sandbox entitlement OMITTED (not set to false — omission is correct for Developer ID distribution)
- LSUIElement=YES (no Dock icon — menu bar app only)
- Sparkle framework for auto-updates
- macOS 14.0 minimum deployment target
- XcodeGen format: xcodeVersion "1600"
DESC
)" \
  --notes "$(cat <<'NOTES'
The project.yml skeleton is fully specified in plan.md § XcodeGen project.yml Skeleton. Copy it verbatim as the starting point, then adjust as needed during implementation.

xcconfig files split Debug/Release: Debug.xcconfig sets DISABLE_LIBRARY_VALIDATION=YES (needed for Sparkle during development with Apple Development cert). Release.xcconfig sets it to NO. Secrets (DEVELOPMENT_TEAM, SPARKLE_PUBLIC_KEY) go in *.local.xcconfig files which are gitignored.
NOTES
)")
echo "  Epic 1: $E1"

E1_1=$(create "Create project.yml with XcodeGen" \
  -t task -p 1 --parent "$E1" \
  -d "$(cat <<'DESC'
Create the project.yml file that XcodeGen uses to generate SSHot.xcodeproj.

Must include:
- deploymentTarget macOS 14.0
- xcodeVersion "1600"
- configs: Debug (debug) and Release (release)
- configFiles: xcconfig/Debug.xcconfig and xcconfig/Release.xcconfig
- Sparkle package dependency (from: 2.0.0)
- Target SSHot: application, macOS, sources SSHot/
- Info.plist properties: LSUIElement=true, SUPublicEDKey, SUFeedURL, CFBundleShortVersionString, CFBundleVersion, NSHumanReadableCopyright
- Entitlements: disable-library-validation via $(DISABLE_LIBRARY_VALIDATION) build variable — NOT app-sandbox
- Build settings: ENABLE_HARDENED_RUNTIME=YES, SWIFT_VERSION=6.0, SWIFT_STRICT_CONCURRENCY=complete, MARKETING_VERSION=1.0.0, CURRENT_PROJECT_VERSION=1

After creating project.yml, run `xcodegen generate` and verify the project opens in Xcode and builds an empty app.

See plan.md § XcodeGen project.yml Skeleton for the complete YAML.
DESC
)")
echo "  1.1: $E1_1"

E1_2=$(create "Set up xcconfig files (Debug, Release, local template)" \
  -t task -p 1 --parent "$E1" --deps "$E1_1" \
  -d "$(cat <<'DESC'
Create the xcconfig directory structure:

xcconfig/
├── Debug.xcconfig          — committed, defines DISABLE_LIBRARY_VALIDATION=YES
├── Release.xcconfig        — committed, defines DISABLE_LIBRARY_VALIDATION=NO
└── *.local.xcconfig        — gitignored, holds secrets

Debug.xcconfig should include a comment block showing required local keys:
  // Create Debug.local.xcconfig with:
  // DEVELOPMENT_TEAM = YOUR_TEAM_ID
  // SPARKLE_PUBLIC_KEY = YOUR_KEY

Release.xcconfig same pattern.

Both committed xcconfigs should #include? their .local counterpart (the ? makes the include optional so builds don't fail if the file is missing on CI where secrets come from env vars).

This supports the plan's requirement that disable-library-validation is only active during development (Apple Development cert) and disabled for production (Developer ID cert).
DESC
)")
echo "  1.2: $E1_2"

E1_3=$(create "Configure entitlements (Hardened Runtime, no sandbox)" \
  -t task -p 1 --parent "$E1" --deps "$E1_1" \
  -d "$(cat <<'DESC'
Create SSHot/SSHot.entitlements with only the Hardened Runtime exceptions needed:
- com.apple.security.cs.disable-library-validation: $(DISABLE_LIBRARY_VALIDATION)

CRITICAL: Do NOT include com.apple.security.app-sandbox at all — not true, not false. For Developer ID distribution outside the Mac App Store, the sandbox entitlement must be entirely absent. Setting it to false can cause notarization rejection.

The Hardened Runtime itself is enabled via ENABLE_HARDENED_RUNTIME=YES in project.yml build settings, not via entitlements.

The disable-library-validation entitlement is needed by Sparkle's XPC updater services during development. In Release builds, this resolves to NO (from Release.xcconfig), which is correct for production — Developer ID signing makes library validation work without the exception.
DESC
)")
echo "  1.3: $E1_3"

E1_4=$(create "Create .gitignore" \
  -t task -p 2 --parent "$E1" \
  -d "$(cat <<'DESC'
Create .gitignore with the patterns specified in plan.md § .gitignore:

- *.xcodeproj/ (generated by XcodeGen, not committed)
- DerivedData/
- *.xcworkspace/xcuserdata/, *.xcuserstate
- *.p8, *.p12 (signing keys)
- sparkle_private_key* (Sparkle private key)
- xcconfig/*.local.xcconfig (secrets — DEVELOPMENT_TEAM, SPARKLE_PUBLIC_KEY)
- .DS_Store

Note: xcconfig/*.local.xcconfig is gitignored but xcconfig/Debug.xcconfig and xcconfig/Release.xcconfig are NOT — they must be committed for the build to work.
DESC
)")
echo "  1.4: $E1_4"

E1_5=$(create "Set up Assets.xcassets (app icon, menu bar template images)" \
  -t task -p 2 --parent "$E1" --deps "$E1_1" \
  -d "$(cat <<'DESC'
Create SSHot/Assets.xcassets with:

1. AppIcon — placeholder app icon (can be refined later)
2. Menu bar icon frames (3-4 frames for upload animation):
   - StatusBarIcon (static, camera-style icon)
   - StatusBarIcon-1, StatusBarIcon-2, StatusBarIcon-3 (animation frames)

ALL menu bar icons MUST be configured as "Template Image" in the asset catalog (Render As: Template Image). This is critical for macOS dark/light mode — template images are automatically tinted by the system. Without this, the icon will look wrong in dark mode.

Icons should be provided at 1x and 2x (18x18pt / 36x36px for menu bar). Keep them simple — the menu bar icon space is small.

The greyed-out disabled state is achieved by setting the NSStatusItem button's alphaValue, not a separate icon.
DESC
)")
echo "  1.5: $E1_5"

# ============================================================================
# EPIC 2: Settings & Configuration
# ============================================================================

echo "--- Epic 2: Settings & Configuration ---"

E2=$(create "Settings & Configuration" \
  -t epic -p 1 --deps "$E1" \
  -d "$(cat <<'DESC'
Implement the Settings infrastructure: a Sendable config store backed by UserDefaults, input validation, and the SwiftUI settings panel.

Settings is a cross-cutting concern — the Uploader needs host/path/identityFile, the ClipboardWatcher needs enabled state, the StatusBarController needs last-upload info. The Settings type must be carefully designed for Swift 6 strict concurrency: it must be Sendable and nonisolated so it can be safely accessed from both @MainActor (ClipboardWatcher, StatusBarController) and nonisolated (Uploader) contexts.

The SwiftUI settings panel cannot use Apple's Settings scene because it can't be opened programmatically from an NSMenu action. Instead, use a plain NSWindow + NSHostingView.
DESC
)")
echo "  Epic 2: $E2"

E2_1=$(create "Settings.swift — Sendable config store" \
  -t task -p 1 --parent "$E2" \
  -d "$(cat <<'DESC'
Create Settings.swift: a Sendable, nonisolated type backed by UserDefaults (suite: com.cogell.sshot).

Properties:
- host: String (default: "home")
- remotePath: String (default: "~/.paste/")
- identityFile: String? (default: nil)
- isEnabled: Bool (default: true)

Swift 6 concurrency design:
- The type must be Sendable because it's accessed from both @MainActor (ClipboardWatcher reads isEnabled) and nonisolated (Uploader reads host/remotePath/identityFile).
- Option A: Make it a struct that snapshots values from UserDefaults — callers capture the struct before crossing isolation boundaries.
- Option B: Make it a final class with nonisolated(unsafe) properties (UserDefaults is thread-safe for reads).
- Option C: Use an actor, but this forces await on every access which is noisy.

Recommend Option A (value-type snapshot) for simplicity. The Uploader captures settings at upload start; the ClipboardWatcher reads isEnabled on @MainActor.

The SCP hardening code in plan.md references Settings.shared.identityFile from the Uploader — this must be resolved by capturing settings values before dispatching the Task.detached upload.
DESC
)" \
  --design "$(cat <<'DESIGN'
// Suggested shape:
struct Settings: Sendable {
    let host: String
    let remotePath: String
    let identityFile: String?
    let isEnabled: Bool

    static func current() -> Settings {
        let defaults = UserDefaults(suiteName: "com.cogell.sshot")!
        return Settings(
            host: defaults.string(forKey: "host") ?? "home",
            remotePath: defaults.string(forKey: "remotePath") ?? "~/.paste/",
            identityFile: defaults.string(forKey: "identityFile"),
            isEnabled: defaults.bool(forKey: "isEnabled")
        )
    }
}
DESIGN
)")
echo "  2.1: $E2_1"

E2_2=$(create "Input validation for host, remotePath, identityFile" \
  -t task -p 1 --parent "$E2" --deps "$E2_1" \
  -d "$(cat <<'DESC'
Implement validation logic for settings fields. This is a security boundary — these values end up as arguments to /usr/bin/scp and /usr/bin/ssh via Foundation.Process. While Process passes arguments as an array (no shell interpolation), scp itself interprets some special characters.

Validation rules:
- SSH Host: reject whitespace, semicolons, backticks, $, and other shell metacharacters. Must not be empty.
- Remote Path: reject spaces, shell metacharacters (;`$|&). Must not be empty. Tilde (~) is allowed (remote shell expands it).
- Identity File: if provided, must exist on disk, must not be a directory, must not end in .pub (common mistake — user selects public key instead of private key).

Validation should happen in the SettingsView (show inline errors) AND as a guard in the Uploader (defense in depth — never pass unvalidated strings to Process).

Since Process doesn't use a shell, the risk is lower than command injection, but malformed hostnames and paths cause confusing scp errors that are hard to debug. Validation provides clear user-facing error messages.
DESC
)" \
  --acceptance "$(cat <<'AC'
1. Setting host to "my server" (with space) shows validation error, cannot save
2. Setting host to "host;rm -rf /" shows validation error
3. Setting remotePath to "/path with spaces/" shows validation error
4. Setting identityFile to a .pub file shows validation error
5. Setting identityFile to a directory shows validation error
6. Setting identityFile to a nonexistent path shows validation error
7. Valid values (host="home", remotePath="~/.paste/", identityFile=nil) pass validation
AC
)")
echo "  2.2: $E2_2"

E2_3=$(create "SettingsView.swift — SwiftUI panel in NSWindow+NSHostingView" \
  -t task -p 2 --parent "$E2" --deps "$E2_1,$E2_2" \
  -d "$(cat <<'DESC'
Create SettingsView.swift: a SwiftUI view with two tabs (General, About) hosted in a plain NSWindow via NSHostingView.

Why not Apple's Settings scene: the Settings scene cannot be opened programmatically from an NSMenu action. There's no Environment(\.openSettings) available outside a SwiftUI view hierarchy. SettingsLink only works inside SwiftUI views. For a menu bar app where the "Open Settings…" action comes from an AppKit NSMenu, we must use NSWindow + NSHostingView.

General tab:
- SSH Host text field (default: "home", with validation)
- Remote Path text field (default: "~/.paste/", with validation)
- Identity File path picker (optional, with validation)
- Launch at Login toggle (backed by SMAppService)

About tab:
- App version (from CFBundleShortVersionString)
- GitHub link
- Sparkle "Check for Updates" button

Window activation for LSUIElement apps:
For LSUIElement apps, NSApp.activate() under macOS 14+ cooperative activation may not reliably foreground the window. Workaround: temporarily set NSApp.setActivationPolicy(.regular), activate, order window front, then restore .accessory. This is a known pattern for menu bar apps.
DESC
)")
echo "  2.3: $E2_3"

# ============================================================================
# EPIC 3: Clipboard Monitoring Engine
# ============================================================================

echo "--- Epic 3: Clipboard Monitoring Engine ---"

E3=$(create "Clipboard Monitoring Engine" \
  -t epic -p 1 --deps "$E2" \
  -d "$(cat <<'DESC'
Implement ClipboardWatcher.swift — the @MainActor component that polls NSPasteboard.general for image data and dispatches uploads.

This is the heart of the app's detection mechanism. The clipboard-first approach (vs. folder-watching) is SSHot's key differentiator from prior art like claude-screenshot-uploader and claudecode-remote-server-copypaste-image.

Design constraints:
- NSPasteboard MUST be accessed on the main thread (@MainActor)
- Polling at 150ms interval — fast enough for responsive UX, cheap because changeCount is just an integer read
- Must prevent App Nap and timer coalescing via ProcessInfo.beginActivity
- Must handle CleanShot X's promised/lazy pasteboard data (80ms grace delay)
- Must prevent self-loops (we write to the clipboard after upload — don't re-process our own write)
- Must prevent overlapping uploads (isProcessing guard)
- TIFF-to-PNG conversion must happen on @MainActor before dispatching to upload
DESC
)")
echo "  Epic 3: $E3"

E3_1=$(create "ClipboardWatcher core — polling with beginActivity" \
  -t task -p 1 --parent "$E3" \
  -d "$(cat <<'DESC'
Create ClipboardWatcher.swift as an @MainActor class with a 150ms Timer that polls NSPasteboard.general.changeCount.

Core structure:
- @MainActor class ClipboardWatcher
- Private var lastChangeCount: Int
- Private var timer: Timer?
- Private var activity: NSObjectProtocol? (for beginActivity token)
- Private var isProcessing: Bool = false
- Private var currentUploadTask: Task<Void, Never>?
- os.Logger instance (created locally — Logger is not Sendable as of Xcode 16.x)

On enable:
- Start ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Clipboard monitoring") — prevents App Nap AND timer coalescing without blocking idle system sleep
- Start Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true)
- Capture initial changeCount

On disable:
- Invalidate timer
- End activity (ProcessInfo.processInfo.endActivity)
- Cancel currentUploadTask

Timer callback:
- Compare NSPasteboard.general.changeCount to lastChangeCount
- If changed and !isProcessing: begin grace delay sequence
- If changed and isProcessing: log "Skipped: upload in progress", update lastChangeCount

On app quit: cancel currentUploadTask, end activity.
DESC
)" \
  --acceptance "$(cat <<'AC'
1. Timer fires approximately every 150ms (verify with os_signpost or Console.app)
2. beginActivity is active while monitoring is enabled (verify with `pmset -g assertions`)
3. beginActivity is ended when monitoring is disabled
4. No timer fires after disable is called
5. Clipboard changes are detected within ~200ms of occurrence
AC
)")
echo "  3.1: $E3_1"

E3_2=$(create "Grace delay with restart cap (maxGraceDelays=4)" \
  -t task -p 1 --parent "$E3" --deps "$E3_1" \
  -d "$(cat <<'DESC'
Implement the 80ms grace delay after detecting a changeCount change, with a restart cap.

Why: CleanShot X (and some other screenshot tools) use promised/lazy pasteboard data. The changeCount increments when data is promised, but the actual image data may not be available for a few tens of milliseconds. Reading too early returns nil or incomplete data. The 80ms delay handles this.

Why restart: Some tools update the clipboard multiple times in quick succession (e.g., write a URL first, then replace with image data). If changeCount changes again during the delay, we restart the timer to ensure we read the final state.

Why cap: Without a cap, a chatty clipboard manager rapidly cycling content could restart the delay indefinitely. maxGraceDelays=4 means 4 total delays (initial + 3 restarts) = max 320ms before we read regardless.

Implementation:
1. Capture changeCount as expectedCount
2. Set isProcessing = true (prevents concurrent grace-delay sequences)
3. await Task.sleep(for: .milliseconds(80))
4. Re-read changeCount — if different from expectedCount AND restartCount < 3:
   - restartCount += 1, update expectedCount, goto step 3
5. If changeCount == expectedCount OR restartCount >= 3:
   - Read pasteboard data and proceed to image extraction

isProcessing is set TRUE at the start of grace delay (not at upload start) to prevent a second timer callback from starting a parallel grace-delay sequence while the first one is sleeping.
DESC
)" \
  --acceptance "$(cat <<'AC'
1. A single clipboard change triggers exactly one grace delay (80ms) before read
2. Rapid clipboard changes (2-3 within 80ms) restart the delay correctly
3. After 4 total delays (320ms), the watcher reads regardless of further changes
4. No concurrent grace-delay sequences can run (isProcessing blocks them)
5. Log output shows restart count when restarts occur
AC
)")
echo "  3.2: $E3_2"

E3_3=$(create "Self-loop prevention (com.cogell.sshot.marker)" \
  -t task -p 1 --parent "$E3" --deps "$E3_1" \
  -d "$(cat <<'DESC'
Implement self-loop prevention using a custom pasteboard type.

Problem: After uploading, SSHot writes the remote path back to the clipboard. This triggers a changeCount increment, which the watcher detects. Without a guard, SSHot would try to process its own clipboard write as a new image (it's not an image, so it would be a no-op, but it wastes a grace-delay cycle and logs noise).

Solution: When SSHot writes the path to the clipboard, it also writes a marker of type "com.cogell.sshot.marker" in the same NSPasteboardItem. When the watcher detects a changeCount change, it checks for this marker FIRST — if present, it updates lastChangeCount and skips processing entirely.

The marker is a zero-byte Data value — its presence alone is the signal. The type string is a reverse-DNS UTI so it won't collide with any real pasteboard type.

This is written atomically with the path string via NSPasteboardItem.writeObjects (see Epic 6 / clipboard write-back task).
DESC
)")
echo "  3.3: $E3_3"

E3_4=$(create "Pasteboard type priority (PNG first, TIFF→PNG on @MainActor)" \
  -t task -p 1 --parent "$E3" --deps "$E3_2" \
  -d "$(cat <<'DESC'
Implement image extraction from the pasteboard with type priority.

Priority order:
1. public.png — read directly, no conversion needed. This is the fast path for most screenshot tools.
2. public.tiff — convert to PNG via NSBitmapImageRep.representation(using: .png, properties: [:])

If neither type is present, skip (not an image clipboard — could be text, file, etc.).

TIFF conversion notes:
- TIFF data from the pasteboard may contain multiple representations (high-DPI + low-DPI). NSBitmapImageRep(data:) returns only the first representation. This is acceptable for MVP — full fidelity would require NSBitmapImageRep.imageReps(with:) (plural).
- NSBitmapImageRep is an AppKit class. Both the pasteboard read AND the TIFF-to-PNG conversion must happen on @MainActor, before dispatching the resulting PNG Data to the upload task via Task.detached. Do NOT offload the conversion to a background thread.
- representation(using:properties:) can return nil for malformed TIFF data. Treat nil as "no image, skip".

The resulting PNG Data is what gets passed to Uploader.upload(imageData:).
DESC
)" \
  --acceptance "$(cat <<'AC'
1. Copying a PNG image to clipboard → detected and extracted as PNG Data
2. Copying a TIFF image (e.g., from Preview) → converted to PNG Data
3. Copying text to clipboard → no image detected, no processing
4. Copying a file to clipboard → no image detected, no processing
5. All pasteboard reads and conversions happen on the main thread (verify with MainActor assertion or Thread.isMainThread)
AC
)")
echo "  3.4: $E3_4"

E3_5=$(create "Image size guard (>20MB skip)" \
  -t task -p 2 --parent "$E3" --deps "$E3_4" \
  -d "$(cat <<'DESC'
After extracting PNG data, check if the data size exceeds 20MB. If so, skip the upload and notify the user.

Why: A 50MB clipboard image on a slow SSH connection would hit the 30s SCP timeout, waste bandwidth, and confuse the user. Better to fail fast with a clear message.

Implementation: Check imageData.count > 20_000_000 after PNG extraction. If exceeded, log a warning and post a notification: "Image too large (X MB). Maximum is 20 MB." Do not set isProcessing = false until notification is posted (keeps the flow consistent).

The 20MB threshold is hardcoded for MVP. Post-MVP: make it configurable in Settings.
DESC
)")
echo "  3.5: $E3_5"

# ============================================================================
# EPIC 4: SCP Upload Engine
# ============================================================================

echo "--- Epic 4: SCP Upload Engine ---"

E4=$(create "SCP Upload Engine" \
  -t epic -p 0 --deps "$E2" \
  -d "$(cat <<'DESC'
Implement Uploader.swift — the core upload engine that runs /usr/bin/scp as a subprocess with proper Swift 6 concurrency, timeout, retry, cancellation, and error handling.

This is the most complex and concurrency-sensitive component. It bridges Foundation.Process (synchronous, callback-based) with Swift structured concurrency (async/await, Task groups). Every pattern choice here has been validated through 5 rounds of plan review.

The Uploader is NOT @MainActor — it runs on the cooperative thread pool via Task.detached. It must never block the main thread.

Key patterns:
- terminationHandler + withCheckedThrowingContinuation (NOT waitUntilExit)
- OSAllocatedUnfairLock<Bool> for double-resume prevention (Sendable)
- withThrowingTaskGroup for timeout race
- withTaskCancellationHandler at BOTH scopes (child task + outer task)
- try process.run() (NOT launch()) with do/catch → continuation.resume(throwing:)
- Outer-scope defer for temp file cleanup (survives retries)
DESC
)")
echo "  Epic 4: $E4"

E4_1=$(create "Uploader.swift — core async structure" \
  -t task -p 0 --parent "$E4" \
  -d "$(cat <<'DESC'
Create the Uploader class/struct skeleton: a nonisolated type with an async upload(imageData:settings:) method.

Structure:
- NOT @MainActor (the whole point is to run off-main)
- os.Logger instance created locally (Logger is not Sendable as of Xcode 16.x — each isolation domain needs its own)
- Main entry point: func upload(imageData: Data, settings: Settings) async throws
  - Generates timestamped filename: YYYY-MM-DDTHHMMSS_<xxxx>.png (colons omitted for filesystem compatibility, 4-char random hex suffix)
  - Writes imageData to FileManager.default.temporaryDirectory/filename
  - defer { try? FileManager.default.removeItem(at: tempFile) } — OUTER scope, survives retries
  - Calls mkdir preflight
  - Calls SCP with retry wrapper
  - Returns the remote path string on success

The settings parameter is a captured Settings snapshot (Sendable value type) — NOT Settings.shared accessed live from the Uploader. The ClipboardWatcher captures Settings.current() on @MainActor before dispatching Task.detached.
DESC
)")
echo "  4.1: $E4_1"

E4_2=$(create "Process + terminationHandler + continuation pattern" \
  -t task -p 0 --parent "$E4" --deps "$E4_1" \
  -d "$(cat <<'DESC'
Implement the core pattern for running /usr/bin/scp as an async operation using Foundation.Process + withCheckedThrowingContinuation.

This is the most concurrency-critical code in the entire app. The pattern:

```
func runSCP(_ args: [String]) async throws {
    try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = args

        let resumed = OSAllocatedUnfairLock(initialState: false)

        process.terminationHandler = { _ in
            if resumed.withLock({ let old = $0; $0 = true; return !old }) {
                // Check exit status here and resume with error if non-zero
                continuation.resume()
            }
        }

        do {
            try process.run()
        } catch {
            if resumed.withLock({ let old = $0; $0 = true; return !old }) {
                continuation.resume(throwing: error)
            }
        }
    }
}
```

CRITICAL RULES:
1. NEVER call Process.waitUntilExit() — it blocks the cooperative thread pool thread
2. Use try process.run(), NOT process.launch() — launch() is deprecated since macOS 10.13 and doesn't throw
3. If run() throws (e.g., /usr/bin/scp doesn't exist), terminationHandler NEVER fires — you MUST resume the continuation in the catch block or the calling task hangs forever
4. The OSAllocatedUnfairLock<Bool> guard prevents double-resume (which is a fatal crash). It must be Sendable because terminationHandler is @Sendable
5. Use hardcoded /usr/bin/scp path — GUI apps don't have the user's shell PATH

Also capture stderr via process.standardError = Pipe() for error-specific messages (host key mismatch, auth failure, etc.).
DESC
)" \
  --acceptance "$(cat <<'AC'
1. Successful SCP upload completes and continuation resumes normally
2. SCP failure (bad host) resumes continuation with error containing exit code
3. Missing /usr/bin/scp (simulate by pointing to nonexistent path) resumes with thrown error, does NOT hang
4. Two rapid uploads cannot cause double-resume crash (continuation resumed exactly once per invocation)
5. No calls to waitUntilExit() anywhere in the codebase (grep check)
6. No calls to process.launch() anywhere (grep check — only process.run())
7. stderr output is captured and available for error classification
8. Build succeeds with Swift 6 strict concurrency — no Sendable violations on the terminationHandler closure
AC
)")
echo "  4.2: $E4_2"

E4_3=$(create "Timeout race with withThrowingTaskGroup" \
  -t task -p 0 --parent "$E4" --deps "$E4_2" \
  -d "$(cat <<'DESC'
Implement the 30-second timeout using withThrowingTaskGroup to race the SCP process against a sleep timer.

Pattern:
```
try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
        try await withTaskCancellationHandler {
            try await self.runSCP(process)
        } onCancel: {
            process.terminate()  // MUST be inside the child task
        }
    }
    group.addTask {
        try await Task.sleep(for: .seconds(30))
        throw TimeoutError()
    }
    do {
        _ = try await group.next()
        group.cancelAll()
    } catch is TimeoutError {
        group.cancelAll()
        throw TimeoutError()
    }
}
```

CRITICAL DETAILS:
1. withTaskCancellationHandler { process.terminate() } MUST wrap runSCP INSIDE the group child task — Foundation.Process has zero awareness of Swift structured concurrency. group.cancelAll() cancels the Swift Task, but the scp subprocess keeps running unless you explicitly terminate it.

2. withTaskGroup implicitly awaits ALL children before returning, even after cancelAll(). If process.terminate() doesn't fire (wrong scope), the group hangs until scp naturally exits. This is the #1 trap for implementers.

3. Task.sleep responds to cancellation automatically (throws CancellationError). So when SCP finishes first (success case), cancelAll() cleanly cancels the sleep task — it won't linger for 30s.

4. SCP errors (non-zero exit) are NOT TimeoutError. They fall through the do/catch and propagate to the caller's retry logic. This is intentional.

5. The group is ThrowingTaskGroup<Void, Error> — both children return Void. group.next() returns Void?.
DESC
)" \
  --acceptance "$(cat <<'AC'
1. Successful upload completes in <30s — timeout task is cancelled, no lingering sleep
2. Timeout after 30s — scp process is terminated, TimeoutError is thrown
3. SCP failure (non-zero exit) — error propagates to caller (not swallowed by timeout logic)
4. After timeout, no orphaned scp process remains (check with `ps aux | grep scp`)
5. Verify group doesn't hang: add a 1s timeout in test, confirm it completes promptly after process.terminate()
6. Timeout does NOT trigger retry (only non-zero exit does — per retry logic spec)
AC
)")
echo "  4.3: $E4_3"

E4_4=$(create "Retry logic (1x, 2s delay, 62s max budget)" \
  -t task -p 1 --parent "$E4" --deps "$E4_3" \
  -d "$(cat <<'DESC'
Implement one automatic retry with 2-second delay on transient SCP failure.

Rules:
- Retry on: non-zero SCP exit code (transient network error, connection refused, etc.)
- Do NOT retry on: TimeoutError (if scp timed out once, retrying likely times out again — already 30s wasted)
- Do NOT retry on: process.run() failure (scp binary missing — permanent error)
- Delay: 2 seconds between first failure and retry (Task.sleep(for: .seconds(2)))
- Surface error to user only after retry also fails

Worst-case wall-clock budget: 30s (first attempt timeout) + 2s (delay) + 30s (retry timeout) = 62 seconds. This is intentional and documented in the plan. The alternative (shorter overall cap) would prevent legitimate large uploads on slow links from completing.

The temp file must persist across the retry — the outer-scope defer handles cleanup after all attempts complete.
DESC
)")
echo "  4.4: $E4_4"

E4_5=$(create "Temp file lifecycle (outer-scope defer)" \
  -t task -p 1 --parent "$E4" --deps "$E4_1" \
  -d "$(cat <<'DESC'
Implement temp file creation and cleanup for SCP uploads.

SCP needs a local file path — NSPasteboard gives us Data. Bridge:
1. Generate filename: same as remote filename (YYYY-MM-DDTHHMMSS_xxxx.png)
2. Write to FileManager.default.temporaryDirectory / filename
3. Pass file URL to SCP
4. Delete in defer block at the OUTER scope of the upload function

CRITICAL: The defer must be at the outer scope (after retry logic completes), NOT per-attempt. If you defer inside the single-attempt function, the temp file gets deleted after the first failure and the retry has no file to upload.

```
func upload(imageData: Data, settings: Settings) async throws -> String {
    let tempFile = ...
    try imageData.write(to: tempFile)
    defer { try? FileManager.default.removeItem(at: tempFile) }  // ← HERE

    // attempt 1 (may throw)
    // retry logic (uses same tempFile)
    // ...
}
```
DESC
)" \
  --acceptance "$(cat <<'AC'
1. Temp file is created in temporaryDirectory before SCP starts
2. Temp file is deleted after successful upload
3. Temp file is deleted after failed upload (including after retry failure)
4. Temp file persists between first attempt and retry attempt
5. No temp files accumulate in temporaryDirectory across multiple uploads (defer always runs)
AC
)")
echo "  4.5: $E4_5"

E4_6=$(create "Remote directory preflight (/usr/bin/ssh mkdir -p)" \
  -t task -p 1 --parent "$E4" --deps "$E4_2" \
  -d "$(cat <<'DESC'
Before each SCP upload, run /usr/bin/ssh <host> 'mkdir -p <remotePath>' to ensure the remote directory exists.

Why before every upload (not cached): mkdir -p is idempotent and takes <50ms over SSH. Caching with a UserDefaults flag is fragile — if the user deletes the remote directory, SSHot wouldn't recreate it. Simplicity wins.

Use the same Process + continuation pattern as SCP. Use /usr/bin/ssh (hardcoded absolute path, same reasoning as /usr/bin/scp). Apply the same SSH options: BatchMode=yes, ConnectTimeout=10, and IdentitiesOnly=yes if identity file is set.

If mkdir fails, propagate the error — the upload should not proceed if we can't ensure the target directory exists. The error will be surfaced to the user via notification.
DESC
)")
echo "  4.6: $E4_6"

E4_7=$(create "SCP argument hardening & IdentitiesOnly" \
  -t task -p 1 --parent "$E4" --deps "$E4_1" \
  -d "$(cat <<'DESC'
Implement the SCP argument construction with all security hardening options.

Arguments (from plan.md § scp Hardening):
- -o BatchMode=yes — fail immediately if auth is required (no password prompt hang)
- -o StrictHostKeyChecking=accept-new — auto-accept new host keys, reject changed keys
- -o ConnectTimeout=10 — fail fast on unreachable host
- If identityFile is set: -i <identityFile> -o IdentitiesOnly=yes
  (IdentitiesOnly prevents SSH agent from trying all loaded keys, avoiding "too many auth failures" on servers with MaxAuthTries)
- localFile.path(percentEncoded: false) — URL.path property is deprecated
- <host>:<remotePath>/<filename> — host and remotePath are pre-validated in Settings

All paths are pre-validated by the Settings validation layer (no whitespace, semicolons, backticks, $). This function trusts that validation but should assert/precondition on it as defense in depth.
DESC
)")
echo "  4.7: $E4_7"

E4_8=$(create "Task cancellation (withTaskCancellationHandler at both scopes)" \
  -t task -p 0 --parent "$E4" --deps "$E4_3" \
  -d "$(cat <<'DESC'
Implement cancellation support so that toggling the app to Disabled or quitting during an upload cleanly terminates the SCP process.

Two cancellation scopes are needed:

1. INNER scope (inside withThrowingTaskGroup child task):
   withTaskCancellationHandler { process.terminate() } wrapping runSCP().
   This handles timeout-triggered cancellation (group.cancelAll()).

2. OUTER scope (on the Task.detached):
   The ClipboardWatcher stores the Task handle. On disable/quit, it calls task.cancel().
   The outer upload function should also use withTaskCancellationHandler to terminate the process.

Without proper cancellation:
- Quitting the app mid-upload leaves an orphaned scp process (it's a child process, so it may or may not be cleaned up by the OS)
- The continuation may resume after the Uploader is deallocated → crash
- The Task.detached runs to completion even though no one cares about the result

After cancellation, isProcessing must be reset to false (on @MainActor) so the watcher can process new clipboard events.
DESC
)" \
  --acceptance "$(cat <<'AC'
1. Start an upload to a slow/unreachable host. Toggle to Disabled. Verify scp process is terminated within 1s.
2. Start an upload. Quit the app. Verify no orphaned scp process (ps aux | grep scp).
3. After cancellation, isProcessing is false and new clipboard events are processed.
4. Cancellation during retry delay (Task.sleep 2s) also works — doesn't wait for retry.
5. No crashes or continuation leaks after rapid enable/disable/enable toggling during upload.
AC
)")
echo "  4.8: $E4_8"

E4_9=$(create "SCP stderr parsing for error-specific messages" \
  -t task -p 2 --parent "$E4" --deps "$E4_2" \
  -d "$(cat <<'DESC'
Parse SCP/SSH stderr output to classify errors and surface specific, actionable messages to the user.

Error classification:
- Host key mismatch: stderr contains "REMOTE HOST IDENTIFICATION HAS CHANGED" or "Host key verification failed"
  → Surface: "SSH host key changed for <host>. Run: ssh-keygen -R <host>"
- Auth failure (passphrase-protected key, no agent): stderr contains "Permission denied" with exit code 255
  → Surface: "SSH key requires passphrase — ensure ssh-agent is running"
- Connection refused: stderr contains "Connection refused"
  → Surface: "Connection refused by <host>. Check that SSH is running."
- Timeout: handled separately by TimeoutError
  → Surface: "Upload timed out after 30s"
- Unknown error: exit code + raw stderr
  → Surface: "Upload failed (exit code X). Check Console.app for details."

Implementation: Capture stderr via Pipe() on process.standardError. Read the pipe's fileHandleForReading.readDataToEndOfFile() after process terminates. Parse the output string for known patterns. Attach the classification to the thrown error so the notification layer can display the right message.
DESC
)")
echo "  4.9: $E4_9"

# ============================================================================
# EPIC 5: Menu Bar UI
# ============================================================================

echo "--- Epic 5: Menu Bar UI ---"

E5=$(create "Menu Bar UI" \
  -t epic -p 1 --deps "$E2" \
  -d "$(cat <<'DESC'
Implement StatusBarController.swift — the @MainActor component managing the NSStatusItem, NSMenu, and upload animation in the macOS menu bar.

This is the user-facing control surface of the app. It must be responsive (never blocked by uploads), visually clear (template images for dark/light mode), and provide essential controls without a settings panel.
DESC
)")
echo "  Epic 5: $E5"

E5_1=$(create "StatusBarController — NSStatusItem + NSMenu" \
  -t task -p 1 --parent "$E5" \
  -d "$(cat <<'DESC'
Create StatusBarController.swift as an @MainActor class.

Components:
- NSStatusItem with button (camera template image)
- NSMenu with items: Toggle, separator, Last Upload, Test Connection, separator, Open Settings, Quit
- Method: uploadDidStart() — triggers animation, updates menu
- Method: uploadDidFinish(result:) — stops animation, updates Last Upload item, writes clipboard
- Greyed-out state when disabled (button.alphaValue = 0.5)

The status item must use a "Template Image" from Assets.xcassets so macOS correctly tints it for dark/light mode. Do NOT use a colored image.
DESC
)")
echo "  5.1: $E5_1"

E5_2=$(create "Toggle enabled/disabled" \
  -t task -p 1 --parent "$E5" --deps "$E5_1" \
  -d "$(cat <<'DESC'
Implement the enable/disable toggle in the menu bar dropdown.

When toggled OFF:
- ClipboardWatcher stops polling (timer invalidated, beginActivity ended)
- Status icon greys out (alphaValue = 0.5)
- Menu item shows "Enable" (checkmark removed)
- If upload is in progress: cancel the Task, terminate scp process

When toggled ON:
- ClipboardWatcher starts polling (timer started, beginActivity begun)
- Status icon returns to full opacity
- Menu item shows "Disable" (checkmark added)

State persists via Settings.isEnabled in UserDefaults — on next app launch, restore the last state.
DESC
)")
echo "  5.2: $E5_2"

E5_3=$(create "Last upload display (click to re-copy)" \
  -t task -p 2 --parent "$E5" --deps "$E5_1" \
  -d "$(cat <<'DESC'
Show the last uploaded file's remote path and timestamp in the menu. Clicking it re-copies the path to the clipboard (with the self-loop marker).

Display: "~/.paste/2026-03-17T103045_a3f2.png — 10:30 AM"
When no upload has occurred: "No uploads yet" (greyed out, non-clickable)

Re-copy must use the same NSPasteboardItem pattern as the post-upload write (path + marker in single writeObjects call) to prevent self-loop triggering.

Store last upload path + timestamp in memory (not UserDefaults — ephemeral, resets on app restart). Post-MVP: persist upload history.
DESC
)")
echo "  5.3: $E5_3"

E5_4=$(create "Upload animation (template image frame swap)" \
  -t task -p 2 --parent "$E5" --deps "$E5_1,$E1_5" \
  -d "$(cat <<'DESC'
Implement animated menu bar icon during upload using frame swapping.

Setup:
- 3-4 template PNG frames in Assets.xcassets (StatusBarIcon-1 through StatusBarIcon-3/4)
- All frames MUST be "Template Image" for dark/light mode tinting
- Frames should suggest activity (e.g., rotating arrows, pulsing dot, upload arrow sequence)

Animation:
- On uploadDidStart(): start a Timer at 150-200ms interval that cycles through frames
- On uploadDidFinish(): stop timer, restore static StatusBarIcon
- On disable during upload: stop timer, restore static icon (greyed)

Use Timer.scheduledTimer — this is a UI timer on the main run loop, which is correct for @MainActor.
DESC
)")
echo "  5.4: $E5_4"

E5_5=$(create "Test Connection command" \
  -t task -p 2 --parent "$E5" --deps "$E5_1,$E4_2" \
  -d "$(cat <<'DESC'
Implement "Test Connection" menu item that runs /usr/bin/ssh -q -o BatchMode=yes -o ConnectTimeout=5 <host> exit and reports pass/fail.

Uses the same Process + continuation pattern as the Uploader (reuse the helper). Use hardcoded /usr/bin/ssh path.

Results shown inline in the menu item:
- Testing: "Testing…" (animated dots or spinner)
- Success: "✓ Connected" (for 3 seconds, then revert to "Test Connection")
- Failure: "✗ Connection failed" or specific error (host key mismatch → show ssh-keygen -R guidance)

Must not block the menu — run async and update the menu item text on completion.
DESC
)")
echo "  5.5: $E5_5"

# ============================================================================
# EPIC 6: Clipboard Write-back
# ============================================================================

echo "--- Epic 6: Clipboard Write-back ---"

E6=$(create "Clipboard Write-back" \
  -t epic -p 1 --deps "$E4,$E3" \
  -d "$(cat <<'DESC'
After a successful upload, replace the local clipboard with the remote file path string so the user can Cmd+V it into their terminal.

This must be done atomically with the self-loop marker to prevent the ClipboardWatcher from re-processing our own clipboard write.
DESC
)")
echo "  Epic 6: $E6"

E6_1=$(create "Write path + marker atomically via NSPasteboardItem" \
  -t task -p 1 --parent "$E6" \
  -d "$(cat <<'DESC'
After successful upload, write the remote path to NSPasteboard.general with the self-loop marker in a single operation.

Pattern:
```
let item = NSPasteboardItem()
item.setString(remotePath, forType: .string)
item.setData(Data(), forType: NSPasteboard.PasteboardType("com.cogell.sshot.marker"))
NSPasteboard.general.clearContents()
NSPasteboard.general.writeObjects([item])
```

Why NSPasteboardItem: Using separate setString() and setData() calls on the pasteboard directly makes 3 IPC calls. Between clearContents() and the last setData(), another process reading the clipboard could see an intermediate state (string present, marker absent). By constructing an NSPasteboardItem first and writing via a single writeObjects() call, we minimize this race window.

No trailing newline in the path string — Cmd+V in a terminal would add an extra blank line.

This runs on @MainActor (StatusBarController.uploadDidFinish calls this). NSPasteboard must be accessed on the main thread.
DESC
)" \
  --acceptance "$(cat <<'AC'
1. After upload, Cmd+V in terminal pastes the exact remote path with no trailing newline
2. The self-loop marker is present on the pasteboard (verify with a pasteboard inspection tool or programmatic check)
3. ClipboardWatcher does NOT trigger processing when the path is written (self-loop guard works)
4. The path string is the correct format: ~/.paste/YYYY-MM-DDTHHMMSS_xxxx.png
AC
)")
echo "  6.1: $E6_1"

# ============================================================================
# EPIC 7: Notifications
# ============================================================================

echo "--- Epic 7: Notifications ---"

E7=$(create "Notifications" \
  -t epic -p 2 --deps "$E4" \
  -d "$(cat <<'DESC'
Implement macOS notification support for upload success/failure feedback.

Uses UNUserNotificationCenter. Authorization is requested at first launch. If the user denies notification permission, fall back to displaying status in the menu bar item text ("Last: Failed — connection refused").
DESC
)")
echo "  Epic 7: $E7"

E7_1=$(create "UNUserNotificationCenter setup + success/failure dispatch" \
  -t task -p 2 --parent "$E7" \
  -d "$(cat <<'DESC'
Request UNUserNotificationCenter authorization at first app launch. Implement notification dispatch for upload results.

Authorization:
- Request .alert and .sound on first launch
- If denied, set a flag and fall back to menu item text updates

Success notification:
- Title: "Screenshot uploaded"
- Body: "~/.paste/2026-03-17T103045_a3f2.png"

Failure notifications (using error classification from SCP stderr parsing):
- Host key mismatch: "SSH host key changed — Run: ssh-keygen -R <host>"
- Auth failure: "SSH key requires passphrase — ensure ssh-agent is running"
- Connection refused: "Connection refused by <host>"
- Timeout: "Upload timed out after 30s"
- Image too large: "Image too large (X MB). Maximum is 20 MB."
- Unknown: "Upload failed (exit code X)"

If notification auth denied, show abbreviated versions in the menu item text: "Last: ✓ uploaded" or "Last: ✗ connection refused"
DESC
)")
echo "  7.1: $E7_1"

# ============================================================================
# EPIC 8: App Lifecycle & Wiring
# ============================================================================

echo "--- Epic 8: App Lifecycle & Wiring ---"

E8=$(create "App Lifecycle & Wiring" \
  -t epic -p 1 --deps "$E3,$E4,$E5,$E6,$E7" \
  -d "$(cat <<'DESC'
Wire all components together: SSHotApp entry point, AppDelegate coordination, Launch at Login, and os.Logger setup.

This epic depends on all component epics because AppDelegate is the integration point that wires ClipboardWatcher → Uploader → StatusBarController.
DESC
)")
echo "  Epic 8: $E8"

E8_1=$(create "SSHotApp.swift — @main entry point" \
  -t task -p 1 --parent "$E8" \
  -d "$(cat <<'DESC'
Create SSHotApp.swift as the @main entry point.

For a menu bar app with no main window:
- Use NSApplication with an AppDelegate
- LSUIElement=YES is set in Info.plist (no Dock icon)
- No main window or WindowGroup

Request UNUserNotificationCenter authorization here at launch.

The app should NOT use SwiftUI's @main App protocol with a WindowGroup — that creates a main window. Use NSApplicationMain or a manual NSApplication.shared.run() approach with the AppDelegate.
DESC
)")
echo "  8.1: $E8_1"

E8_2=$(create "AppDelegate.swift — wire all components" \
  -t task -p 1 --parent "$E8" --deps "$E8_1" \
  -d "$(cat <<'DESC'
Create AppDelegate.swift that instantiates and wires all components:

- StatusBarController (creates menu bar UI)
- ClipboardWatcher (polls clipboard)
- Uploader (handles SCP uploads)

Wiring flow:
1. ClipboardWatcher detects image → dispatches Task.detached with Uploader.upload()
2. Uploader completes → calls StatusBarController.uploadDidFinish() on @MainActor
3. StatusBarController writes clipboard (path + marker), updates menu, posts notification

AppDelegate owns all three objects and passes references as needed. Since ClipboardWatcher and StatusBarController are both @MainActor, and the Uploader is nonisolated, the handoff points are:
- @MainActor → nonisolated: Task.detached { [data, settings] in ... }
- nonisolated → @MainActor: await MainActor.run { ... }
DESC
)")
echo "  8.2: $E8_2"

E8_3=$(create "Launch at Login via SMAppService" \
  -t task -p 2 --parent "$E8" \
  -d "$(cat <<'DESC'
Implement Launch at Login toggle using SMAppService (macOS 13+ API).

SMAppService.mainApp provides a simple .register() / .unregister() API for login items. This is the modern replacement for the deprecated SMLoginItemSetEnabled and the ancient LaunchAgents approach.

The toggle in SettingsView should reflect the current registration state and allow the user to enable/disable it. Handle errors gracefully (e.g., if the user has too many login items).
DESC
)")
echo "  8.3: $E8_3"

E8_4=$(create "os.Logger instances (per isolation domain)" \
  -t task -p 2 --parent "$E8" \
  -d "$(cat <<'DESC'
Set up os.Logger instances in each component.

As of Xcode 16.x, os.Logger is still not marked Sendable on any macOS version. Under Swift 6 strict concurrency, sharing a Logger across isolation boundaries produces a compiler error.

Solution: create separate Logger instances in each type:
- ClipboardWatcher: Logger(subsystem: "com.cogell.sshot", category: "clipboard")
- Uploader: Logger(subsystem: "com.cogell.sshot", category: "upload")
- StatusBarController: Logger(subsystem: "com.cogell.sshot", category: "ui")

Alternative: mark a shared logger as nonisolated(unsafe) — simpler but less principled.

Log events:
- Clipboard change detected, grace delay start/restart, image extracted, size guard triggered
- Upload start, mkdir preflight, SCP start, SCP exit code, retry, timeout, success/failure
- Toggle enabled/disabled, settings changed, notification posted
DESC
)")
echo "  8.4: $E8_4"

# ============================================================================
# EPIC 9: Sparkle Auto-updates
# ============================================================================

echo "--- Epic 9: Sparkle Auto-updates ---"

E9=$(create "Sparkle Auto-updates" \
  -t epic -p 2 --deps "$E1" \
  -d "$(cat <<'DESC'
Integrate the Sparkle framework for automatic update checking.

Sparkle is the de facto standard for macOS app auto-updates outside the App Store. It checks an appcast.xml feed for new versions and handles download/install.

The SUPublicEDKey and SUFeedURL are set in Info.plist. The About tab in Settings provides a manual "Check for Updates" button.
DESC
)")
echo "  Epic 9: $E9"

E9_1=$(create "Sparkle framework integration" \
  -t task -p 2 --parent "$E9" \
  -d "$(cat <<'DESC'
Initialize Sparkle's SPUStandardUpdaterController in AppDelegate and wire the "Check for Updates" button in the About tab.

Sparkle setup:
1. SPUStandardUpdaterController is created in AppDelegate
2. The About tab's "Check for Updates" button calls updaterController.checkForUpdates(nil)
3. Sparkle reads SUFeedURL from Info.plist to find the appcast
4. Sparkle reads SUPublicEDKey to verify update signatures

For first release, the Sparkle keys need to be generated (see plan.md § First-Run Setup Checklist item 1). The appcast.xml is generated and updated by CI.
DESC
)")
echo "  9.1: $E9_1"

# ============================================================================
# EPIC 10: Distribution & CI
# ============================================================================

echo "--- Epic 10: Distribution & CI ---"

E10=$(create "Distribution & CI" \
  -t epic -p 2 --deps "$E1,$E8,$E9" \
  -d "$(cat <<'DESC'
Set up the release pipeline: GitHub Actions CI, notarization, DMG creation, appcast.xml, and Homebrew cask.

This is the final epic — it packages and distributes the app. Depends on everything being implemented and working.
DESC
)")
echo "  Epic 10: $E10"

E10_1=$(create "GitHub Actions CI workflow" \
  -t task -p 2 --parent "$E10" \
  -d "$(cat <<'DESC'
Create .github/workflows/release.yml that triggers on tag push and:

1. xcodegen generate (generates .xcodeproj from project.yml)
2. xcodebuild archive (Release config, Hardened Runtime on)
3. Notarize with xcrun notarytool submit (uses APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID secrets)
4. Staple the notarization ticket: xcrun stapler staple
5. Create .dmg (use create-dmg or hdiutil)
6. Attach .dmg to GitHub Release
7. Update appcast.xml with new version info (Sparkle's generate_appcast tool)

Required GitHub Actions secrets:
- DEVELOPER_ID_P12, DEVELOPER_ID_P12_PASSWORD (code signing)
- APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID (notarization)
- SPARKLE_PRIVATE_KEY (signing the update)
DESC
)")
echo "  10.1: $E10_1"

E10_2=$(create "appcast.xml setup (GitHub Pages)" \
  -t task -p 2 --parent "$E10" \
  -d "$(cat <<'DESC'
Set up appcast.xml hosting for Sparkle update checking.

Options (from plan.md):
- GitHub Pages from /docs folder or gh-pages branch (cogell.github.io/sshot/appcast.xml)
- Raw GitHub URL as fallback

The CI workflow (10.1) generates/updates appcast.xml on each release using Sparkle's generate_appcast tool. The file should be committed to the serving location automatically.

SUFeedURL in Info.plist points to: https://cogell.github.io/sshot/appcast.xml
DESC
)")
echo "  10.2: $E10_2"

E10_3=$(create "Homebrew cask formula" \
  -t task -p 3 --parent "$E10" --deps "$E10_1" \
  -d "$(cat <<'DESC'
Create a Homebrew cask formula for easy installation: `brew install --cask sshot`

The cask should point to the .dmg from GitHub Releases. Can be submitted to homebrew-cask or hosted in a personal tap (cogell/homebrew-tap).
DESC
)")
echo "  10.3: $E10_3"

echo ""
echo "=== All beads created ==="
echo ""
echo "Epics: $E1, $E2, $E3, $E4, $E5, $E6, $E7, $E8, $E9, $E10"
echo ""
echo "Run 'bd list' to see all issues"
echo "Run 'bd children <epic-id>' to see task hierarchy"
