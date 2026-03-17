import AppKit
import os

/// Monitors `NSPasteboard.general` for image content and dispatches uploads.
///
/// All pasteboard access and TIFF-to-PNG conversion happen on `@MainActor`.
/// Upload work is dispatched via `Task.detached` to avoid blocking the main thread.
@MainActor
final class ClipboardWatcher {

    // MARK: - Upload callback

    /// Called when an image is detected and ready for upload.
    ///
    /// The closure receives the PNG `Data` and a snapshot of `Settings` captured
    /// at detection time. Returns the remote path string on success.
    /// This is a closure property because `Uploader` is defined in a separate file
    /// and may not exist yet during development.
    ///
    /// Marked `@Sendable` so it can be captured safely by `Task.detached`.
    var onImageDetected: (@Sendable (Data, Settings) async throws -> String)?

    // MARK: - Private state

    /// The last observed `changeCount` from `NSPasteboard.general`.
    private var lastChangeCount: Int = 0

    /// Timer that polls the pasteboard every 150ms.
    private var timer: Timer?

    /// Token returned by `ProcessInfo.beginActivity` — held while monitoring is
    /// active to prevent App Nap and timer coalescing.
    private var activity: NSObjectProtocol?

    /// Guards against concurrent grace-delay sequences. Set `true` at the start
    /// of grace delay (not upload start) so a second timer callback cannot start
    /// a parallel sequence while the first one is sleeping.
    private var isProcessing: Bool = false

    /// Handle to the current upload `Task`, stored for cancellation on
    /// disable / app quit.
    private var currentUploadTask: Task<Void, Never>?

    /// Maximum number of grace-delay cycles.
    /// The loop runs up to this many iterations, and the restart counter also caps at this value.
    /// Total max delay = maxGraceDelays x graceDelayDuration = 4 x 80ms = 320ms.
    private let maxGraceDelays: Int = 4

    /// Grace delay duration per cycle.
    private let graceDelayDuration: Duration = .milliseconds(80)

    /// Logger — stored as property since ClipboardWatcher is @MainActor (no Sendable issue).
    private let logger = Logger(subsystem: "com.cogell.sshot", category: "ClipboardWatcher")

    /// Maximum image size in bytes (20 MiB = 20 * 1,048,576).
    /// Must match Uploader.maxImageBytes.
    private let maxImageBytes: Int = 20 * 1_048_576

    // MARK: - Lifecycle

    /// Begin monitoring the clipboard.
    ///
    /// Starts a `beginActivity` to prevent App Nap, captures the current
    /// `changeCount`, and schedules the 150ms polling timer.
    func enable() {
        logger.info("Enabling clipboard monitoring")

        // Prevent App Nap and timer coalescing while monitoring.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Clipboard monitoring"
        )

        lastChangeCount = NSPasteboard.general.changeCount

        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop, so we are already on @MainActor.
            // However, the closure is non-isolated from the compiler's perspective.
            // Use MainActor.assumeIsolated to re-enter the actor context synchronously.
            MainActor.assumeIsolated {
                self?.timerFired()
            }
        }
    }

    /// Stop monitoring the clipboard.
    ///
    /// Invalidates the timer, ends the `beginActivity`, and cancels any
    /// in-flight upload task.
    func disable() {
        logger.info("Disabling clipboard monitoring")

        timer?.invalidate()
        timer = nil

        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }

        cancelCurrentUpload()
    }

    /// Cancel any in-flight upload task. Called on disable and app quit.
    func cancelCurrentUpload() {
        currentUploadTask?.cancel()
        currentUploadTask = nil
        isProcessing = false
    }

    // MARK: - Timer callback

    /// Called every ~150ms by the polling timer.
    private func timerFired() {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        guard currentCount != lastChangeCount else {
            return // No change — nothing to do.
        }

        // Update lastChangeCount immediately so we don't re-detect the same change.
        lastChangeCount = currentCount


        if isProcessing {
            logger.info("Skipped: upload in progress")
            return
        }

        // Self-loop check: if our own marker is present, skip entirely.
        // This happens BEFORE grace delay to avoid wasting 80ms on self-loop detection.
        if pasteboard.data(forType: PasteboardConstants.markerType) != nil {
            logger.debug("Skipped: self-loop marker detected")
            return
        }

        // Begin the grace-delay → extract → upload sequence.
        isProcessing = true

        // Single Task for the entire sequence: grace delay + extraction on @MainActor,
        // then upload via Task.detached. We do NOT reassign currentUploadTask mid-flight —
        // this Task owns the full lifecycle. Cancelling it cancels the grace delay OR the
        // upload (whichever is active) because the detached upload is awaited inline.
        currentUploadTask = Task { [weak self] in
            guard let self else { return }
            await self.handleClipboardChange()
        }
    }

    // MARK: - Grace delay + extraction + dispatch

    /// Runs the full grace-delay → extract → dispatch sequence.
    /// Must run on `@MainActor` because pasteboard access and TIFF conversion
    /// require the main thread.
    private func handleClipboardChange() async {

        // --- Grace delay with restart cap ---

        let pasteboard = NSPasteboard.general
        var expectedCount = pasteboard.changeCount
        var restartCount = 0

        for _ in 0..<maxGraceDelays {
            do {
                try await Task.sleep(for: graceDelayDuration)
            } catch {
                // Task was cancelled (disable/quit).
                logger.info("Grace delay cancelled")
                isProcessing = false
                return
            }

            let currentCount = pasteboard.changeCount
            if currentCount != expectedCount {
                restartCount += 1
                logger.debug("Grace delay restart \(restartCount) — changeCount changed during delay")
                expectedCount = currentCount
                lastChangeCount = currentCount

                // Re-check self-loop marker after restart — the new clipboard content
                // might be our own write-back.
                if pasteboard.data(forType: PasteboardConstants.markerType) != nil {
                    logger.debug("Skipped after grace restart: self-loop marker detected")
                    isProcessing = false
                    return
                }

                if restartCount >= maxGraceDelays {
                    // We've hit the restart cap. Total delays = initial loop iterations
                    // that completed + this restart = maxGraceDelays total.
                    logger.debug("Grace delay restart cap reached (\(restartCount) restarts), reading now")
                    break
                }
                // Otherwise continue the loop for another delay cycle.
                continue
            }

            // changeCount is stable — proceed to read.
            break
        }

        // --- Image extraction (on @MainActor) ---

        guard let imageData = extractImageData(from: pasteboard, logger: logger) else {
            logger.debug("No image data found in clipboard after grace delay")
            isProcessing = false
            return
        }

        // Image size guard is in Uploader — errors surface through the normal
        // onImageDetected callback error path, which triggers notifications via AppDelegate.

        // --- Snapshot settings and dispatch upload ---

        guard let onImageDetected else {
            logger.warning("No onImageDetected callback configured — skipping upload")
            isProcessing = false
            return
        }

        let settings = Settings.current()
        let callback = onImageDetected

        logger.info("Image detected (\(imageData.count) bytes), dispatching upload")

        // Task.detached — NOT Task {} — because Task {} inherits @MainActor isolation
        // from ClipboardWatcher (SE-0420). With plain Task {}, code before the first
        // await runs on main. Task.detached ensures the entire upload runs off-main.
        //
        // We await the detached task inline so that cancelling currentUploadTask
        // (the outer @MainActor Task) propagates to the upload. No task handle
        // reassignment — avoids the race where cancelCurrentUpload() fires between
        // task creation and reassignment.
        do {
            let remotePath = try await Task.detached {
                try await callback(imageData, settings)
            }.value
            logger.info("Upload succeeded: \(remotePath)")
        } catch is CancellationError {
            logger.info("Upload cancelled")
        } catch {
            logger.error("Upload failed: \(error.localizedDescription)")
        }

        uploadDidFinish()
    }

    /// Called from the detached upload task when the upload completes or fails.
    /// Clears `isProcessing` so the next clipboard change can be processed.
    private func uploadDidFinish() {
        isProcessing = false
    }

    // MARK: - Image extraction

    /// Extract PNG data from the pasteboard, with type priority:
    /// 1. `public.png` — read directly, no conversion.
    /// 2. `public.tiff` — convert via `NSBitmapImageRep` → PNG representation.
    ///
    /// Returns `nil` if neither type is present or conversion fails.
    /// Must be called on `@MainActor`.
    private func extractImageData(
        from pasteboard: NSPasteboard,
        logger: Logger
    ) -> Data? {
        // Priority 1: PNG (fast path — no conversion needed).
        if let pngData = pasteboard.data(forType: .png) {
            logger.debug("Found PNG data in clipboard")
            return pngData
        }

        // Priority 2: TIFF → PNG conversion.
        if let tiffData = pasteboard.data(forType: .tiff) {
            logger.debug("Found TIFF data in clipboard, converting to PNG")

            // NSBitmapImageRep(data:) returns only the first representation
            // from multi-representation TIFF (e.g., high-DPI + low-DPI).
            // Acceptable for MVP.
            guard let bitmapRep = NSBitmapImageRep(data: tiffData) else {
                logger.warning("Failed to create NSBitmapImageRep from TIFF data")
                return nil
            }

            guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                logger.warning("Failed to convert TIFF to PNG via NSBitmapImageRep")
                return nil
            }

            logger.debug("TIFF → PNG conversion succeeded (\(pngData.count) bytes)")
            return pngData
        }

        // Neither PNG nor TIFF found.
        return nil
    }
}
