import AppKit
import os
import Sparkle

/// Wires all components together: ClipboardWatcher, Uploader, StatusBarController,
/// NotificationManager, and SettingsWindowController.
///
/// Owns all component instances and sets up the callback graph:
/// - ClipboardWatcher.onImageDetected -> Uploader.upload -> StatusBarController + NotificationManager
/// - StatusBarController.onToggle -> ClipboardWatcher.enable/disable
/// - StatusBarController.onOpenSettings -> SettingsWindowController.showWindow
/// - StatusBarController.onQuit -> NSApp.terminate
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Components

    private var statusBarController: StatusBarController!
    private var clipboardWatcher: ClipboardWatcher!
    private var notificationManager: NotificationManager!
    private var settingsWindowController: SettingsWindowController!

    // MARK: - Sparkle

    /// Sparkle's standard updater controller, initialized at launch.
    /// `SPUStandardUpdaterController` manages the update lifecycle (check, download, install).
    /// It reads SUFeedURL and SUPublicEDKey from Info.plist.
    private var updaterController: SPUStandardUpdaterController!

    // MARK: - Logger

    private let logger = Logger(subsystem: "com.cogell.sshot", category: "AppDelegate")

    // MARK: - NSApplicationDelegate

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            self.setUp()
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            self.clipboardWatcher?.cancelCurrentUpload()
            self.clipboardWatcher?.disable()
        }
    }

    // MARK: - Setup

    private func setUp() {
        logger.info("SSHot launching")

        // --- Sparkle ---
        // SPUStandardUpdaterController must be created early (before the first run loop
        // iteration for automatic update checks). The startingUpdater parameter controls
        // whether Sparkle starts automatically; we set it to true for standard behavior.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Don't auto-check until Sparkle keys and appcast are configured.
        // The "Check for Updates" button in Settings still works manually.

        // --- Notification Manager ---
        notificationManager = NotificationManager()

        // --- Settings Window Controller ---
        settingsWindowController = SettingsWindowController()
        settingsWindowController.onSettingsChanged = { [weak self] in
            self?.logger.info("Settings changed")
        }

        // Wire Sparkle "Check for Updates" from Settings About tab
        settingsWindowController.onCheckForUpdates = { [weak self] in
            self?.updaterController.checkForUpdates(nil)
        }

        // --- Status Bar Controller ---
        statusBarController = StatusBarController()

        // --- Clipboard Watcher ---
        clipboardWatcher = ClipboardWatcher()

        // --- Wire callbacks ---

        // ClipboardWatcher.onImageDetected -> Uploader.upload
        // The callback is @Sendable and runs in Task.detached (off @MainActor).
        // Results are dispatched back to @MainActor for UI updates.
        //
        // We capture [weak self] and call @MainActor methods on AppDelegate
        // to avoid sending @MainActor-isolated references across isolation
        // boundaries (which Swift 6 strict concurrency rejects).
        clipboardWatcher.onImageDetected = { [weak self] imageData, settings in
            // Signal upload start on @MainActor
            await self?.handleUploadDidStart()

            do {
                let remotePath = try await Uploader.upload(imageData: imageData, settings: settings)

                // On success: update UI and post notification
                await self?.handleUploadSuccess(remotePath: remotePath)

                return remotePath
            } catch {
                // On failure: update UI and post notification
                await self?.handleUploadFailure(error: error, host: settings.host)

                throw error
            }
        }

        // StatusBarController.onToggle -> ClipboardWatcher.enable/disable
        let watcher = clipboardWatcher!
        statusBarController.onToggle = { [weak watcher] enabled in
            if enabled {
                watcher?.enable()
            } else {
                watcher?.disable()
            }
        }

        // StatusBarController.onOpenSettings -> SettingsWindowController.showWindow
        let settingsWC = settingsWindowController!
        statusBarController.onOpenSettings = { [weak settingsWC] in
            settingsWC?.showWindow()
        }

        // StatusBarController.onQuit -> NSApp.terminate
        statusBarController.onQuit = {
            NSApp.terminate(nil)
        }

        // --- Request notification authorization, then start clipboard monitoring ---
        // Authorization is awaited first so that isAuthorized is set before the first
        // upload could trigger a notification. On subsequent launches (when the user has
        // already granted/denied), requestAuthorization returns almost immediately.
        Task {
            await notificationManager.requestAuthorization()

            let settings = Settings.current()
            if settings.isEnabled {
                clipboardWatcher.enable()
                logger.info("Clipboard monitoring enabled at launch")
            } else {
                logger.info("Clipboard monitoring disabled at launch (per saved settings)")
            }
        }

        logger.info("SSHot setup complete")
    }

    // MARK: - Upload lifecycle helpers (called from @Sendable callback)

    /// Notify UI that an upload has started. Called from the detached upload task.
    private func handleUploadDidStart() {
        statusBarController?.uploadDidStart()
    }

    /// Notify UI and post notification on upload success.
    private func handleUploadSuccess(remotePath: String) {
        statusBarController?.uploadDidFinish(result: .success(remotePath))
        notificationManager?.notifySuccess(remotePath: remotePath)
    }

    /// Notify UI and post notification on upload failure.
    private func handleUploadFailure(error: Error, host: String) {
        statusBarController?.uploadDidFinish(result: .failure(error))
        notificationManager?.notifyFailure(error: error, host: host)
    }
}
