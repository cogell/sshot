import AppKit
import os

/// Manages the NSStatusItem, its menu, upload animation, and clipboard write-back.
///
/// All public API is @MainActor — NSStatusItem, NSMenu, and NSPasteboard must be
/// accessed on the main thread.
@MainActor
final class StatusBarController {

    // MARK: - Public callbacks (wired by AppDelegate)

    /// Called when the user toggles enable/disable. The Bool is the new enabled state.
    var onToggle: ((Bool) -> Void)?

    /// Called when the user clicks "Open Settings…".
    var onOpenSettings: (() -> Void)?

    /// Called when the user clicks "Quit".
    var onQuit: (() -> Void)?

    // MARK: - Private state

    private let statusItem: NSStatusItem
    private let menu: NSMenu

    private let toggleItem: NSMenuItem
    private let lastUploadItem: NSMenuItem
    private let testConnectionItem: NSMenuItem

    private var isEnabled: Bool
    private var lastUploadPath: String?
    private var lastUploadTimestamp: Date?

    private var animationTimer: Timer?
    private var animationFrameIndex: Int = 0
    private let animationFrameNames = ["StatusBarIcon-1", "StatusBarIcon-2", "StatusBarIcon-3"]
    private static let animationInterval: TimeInterval = 0.15 // 150ms

    /// Handle to the current test connection task, stored for cancellation
    /// so overlapping "Test Connection" clicks don't race.
    private var testConnectionTask: Task<Void, Never>?

    /// Cached DateFormatter for last-upload timestamp display.
    private static let lastUploadFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    /// Logger for this component.
    /// `os.Logger` is not marked `Sendable` as of Xcode 16.x. We use `nonisolated(unsafe)`
    /// per the plan's guidance. All access is from @MainActor.
    private let logger = Logger(subsystem: "com.cogell.sshot", category: "StatusBar")

    // MARK: - Init

    init() {
        let settings = Settings.current()
        self.isEnabled = settings.isEnabled

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()

        // Toggle item
        toggleItem = NSMenuItem(
            title: isEnabled ? "Disable" : "Enable",
            action: nil,
            keyEquivalent: ""
        )

        // Last Upload item
        lastUploadItem = NSMenuItem(
            title: "No uploads yet",
            action: nil,
            keyEquivalent: ""
        )
        lastUploadItem.isEnabled = false

        // Test Connection item
        testConnectionItem = NSMenuItem(
            title: "Test Connection",
            action: nil,
            keyEquivalent: ""
        )

        // Build menu
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(lastUploadItem)
        menu.addItem(testConnectionItem)
        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "Open Settings…",
            action: nil,
            keyEquivalent: ","
        )
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: "Quit SSHot",
            action: nil,
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        // Configure status item — isTemplate is already set via Assets.xcassets
        // Contents.json ("template-rendering-intent": "template"), no need to set in code.
        if let button = statusItem.button {
            button.image = NSImage(named: "StatusBarIcon")
            if !isEnabled {
                button.alphaValue = 0.5
            }
        }
        statusItem.menu = menu

        // Wire menu actions via target-action
        let handler = MenuActionHandler(controller: self)
        self.actionHandler = handler

        toggleItem.target = handler
        toggleItem.action = #selector(MenuActionHandler.toggleClicked)

        lastUploadItem.target = handler
        lastUploadItem.action = #selector(MenuActionHandler.lastUploadClicked)

        testConnectionItem.target = handler
        testConnectionItem.action = #selector(MenuActionHandler.testConnectionClicked)

        settingsItem.target = handler
        settingsItem.action = #selector(MenuActionHandler.openSettingsClicked)

        quitItem.target = handler
        quitItem.action = #selector(MenuActionHandler.quitClicked)
    }

    /// Strong reference to keep the target-action handler alive.
    private var actionHandler: MenuActionHandler?

    // MARK: - Public API

    /// Called by the upload pipeline when an upload begins.
    func uploadDidStart() {
        logger.info("Upload started — beginning animation")
        startAnimation()
    }

    /// Called by the upload pipeline when an upload finishes.
    ///
    /// - Parameter result: `.success` with the remote path, or `.failure` with an error.
    func uploadDidFinish(result: Result<String, Error>) {
        stopAnimation()

        switch result {
        case let .success(remotePath):
            logger.info("Upload finished successfully: \(remotePath, privacy: .public)")
            lastUploadPath = remotePath
            lastUploadTimestamp = Date()
            updateLastUploadItem()
            writePathToClipboard(remotePath)

        case let .failure(error):
            logger.error("Upload failed: \(error.localizedDescription, privacy: .public)")
            lastUploadItem.title = "Last: \u{2717} \(abbreviatedError(error))"
            lastUploadItem.isEnabled = false
        }
    }

    /// Update the enabled/disabled visual state. Called after the toggle callback fires.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        Settings.set(enabled, forKey: "isEnabled")
        toggleItem.title = enabled ? "Disable" : "Enable"

        if let button = statusItem.button {
            button.alphaValue = enabled ? 1.0 : 0.5
        }

        if !enabled {
            stopAnimation()
        }
    }

    // MARK: - Clipboard

    /// Write the remote path to the clipboard with the self-loop marker, atomically
    /// using NSPasteboardItem. No trailing newline.
    private func writePathToClipboard(_ path: String) {
        let item = NSPasteboardItem()
        item.setString(path, forType: .string)
        item.setData(Data(), forType: PasteboardConstants.markerType)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        logger.debug("Wrote path to clipboard (with marker): \(path, privacy: .public)")
    }

    // MARK: - Animation

    private func startAnimation() {
        stopAnimation() // safety — no double timer
        animationFrameIndex = 0
        updateAnimationFrame()

        animationTimer = Timer.scheduledTimer(
            withTimeInterval: Self.animationInterval,
            repeats: true
        ) { [weak self] _ in
            // Timer fires on the main run loop, so this is safe for @MainActor.
            // However, the closure is not @MainActor-isolated by default.
            // Use MainActor.assumeIsolated since we know we're on main.
            MainActor.assumeIsolated {
                self?.advanceAnimationFrame()
            }
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationFrameIndex = 0

        // Restore static icon
        if let button = statusItem.button {
            button.image = NSImage(named: "StatusBarIcon")
        }
    }

    private func advanceAnimationFrame() {
        animationFrameIndex = (animationFrameIndex + 1) % animationFrameNames.count
        updateAnimationFrame()
    }

    private func updateAnimationFrame() {
        let frameName = animationFrameNames[animationFrameIndex]
        if let button = statusItem.button {
            button.image = NSImage(named: frameName)
        }
    }

    // MARK: - Last Upload

    private func updateLastUploadItem() {
        guard let path = lastUploadPath, let timestamp = lastUploadTimestamp else {
            lastUploadItem.title = "No uploads yet"
            lastUploadItem.isEnabled = false
            return
        }

        let timeString = Self.lastUploadFormatter.string(from: timestamp)

        lastUploadItem.title = "\(path) — \(timeString)"
        lastUploadItem.isEnabled = true
    }

    // MARK: - Test Connection

    private func runTestConnection() {
        // Cancel any previous test connection task to prevent overlapping tests
        testConnectionTask?.cancel()

        let settings = Settings.current()
        let host = settings.host

        testConnectionItem.title = "Testing\u{2026}"
        testConnectionItem.isEnabled = false

        testConnectionTask = Task {
            do {
                // Use SSHBaseArgs for consistency with actual upload path
                // (same StrictHostKeyChecking, IdentitiesOnly, etc.)
                var args = SSHBaseArgs.sshBaseArgs(settings: settings)
                args += ["-q", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1"]
                args += [host, "exit"]

                let result = try await runProcessThrowing(
                    executablePath: "/usr/bin/ssh",
                    arguments: args
                )

                if result.exitCode == 0 {
                    testConnectionItem.title = "\u{2713} Connected"
                    logger.info("Test connection to \(host, privacy: .public) succeeded")
                } else {
                    let classification = SSHotError.classify(stderr: result.stderr)
                    switch classification {
                    case .hostKeyMismatch:
                        testConnectionItem.title = "\u{2717} Host key changed — ssh-keygen -R \(host)"
                    case .authFailure:
                        testConnectionItem.title = "\u{2717} Auth failed — check ssh-agent"
                    case .connectionRefused:
                        testConnectionItem.title = "\u{2717} Connection refused"
                    case .unknown:
                        testConnectionItem.title = "\u{2717} Connection failed (exit \(result.exitCode))"
                    }
                    logger.warning(
                        "Test connection to \(host, privacy: .public) failed: exit \(result.exitCode)"
                    )
                }
            } catch is CancellationError {
                // Task was cancelled — another test was started or app is quitting.
                // Don't update UI since a new test may be in progress.
                return
            } catch {
                testConnectionItem.title = "\u{2717} \(error.localizedDescription)"
                logger.error("Test connection error: \(error.localizedDescription, privacy: .public)")
            }

            testConnectionItem.isEnabled = true

            // Pop the menu open so the user sees the result
            // without needing to manually re-click.
            statusItem.button?.performClick(nil)

            // Revert to "Test Connection" after 3 seconds.
            // Use do/catch (not try?) so cancellation prevents the title reset —
            // otherwise a cancelled old task would overwrite a new test's result.
            do {
                try await Task.sleep(for: .seconds(3))
                testConnectionItem.title = "Test Connection"
            } catch {
                // Cancelled — don't reset title, a new test may be showing its result
            }
        }
    }

    // MARK: - Error formatting

    private func abbreviatedError(_ error: Error) -> String {
        if let sshotError = error as? SSHotError {
            switch sshotError {
            case .timeout:
                return "timed out"
            case let .scpFailed(_, _, classification):
                switch classification {
                case .hostKeyMismatch: return "host key changed"
                case .authFailure: return "auth failed"
                case .connectionRefused: return "connection refused"
                case .unknown: return "upload failed"
                }
            case .processLaunchFailed:
                return "launch error"
            case .imageTooLarge:
                return "image too large"
            case .mkdirFailed:
                return "mkdir failed"
            case .invalidSettings:
                return "invalid settings"
            }
        }
        return "failed"
    }

    // MARK: - Menu action handling

    fileprivate func handleToggle() {
        let newState = !isEnabled
        setEnabled(newState)
        onToggle?(newState)
    }

    fileprivate func handleLastUploadClick() {
        guard let path = lastUploadPath else { return }
        writePathToClipboard(path)
        logger.info("Re-copied last upload path to clipboard: \(path, privacy: .public)")
    }

    fileprivate func handleTestConnection() {
        runTestConnection()
    }

    fileprivate func handleOpenSettings() {
        onOpenSettings?()
    }

    fileprivate func handleQuit() {
        onQuit?()
    }
}

// MARK: - MenuActionHandler

/// NSObject subclass to serve as target-action handler for NSMenuItems.
///
/// NSMenuItem's target/action pattern requires an NSObject with @objc methods.
/// This keeps StatusBarController free of NSObject inheritance while providing
/// the required Objective-C selectors.
@MainActor
private final class MenuActionHandler: NSObject {
    weak var controller: StatusBarController?

    init(controller: StatusBarController) {
        self.controller = controller
        super.init()
    }

    @objc func toggleClicked() {
        controller?.handleToggle()
    }

    @objc func lastUploadClicked() {
        controller?.handleLastUploadClick()
    }

    @objc func testConnectionClicked() {
        controller?.handleTestConnection()
    }

    @objc func openSettingsClicked() {
        controller?.handleOpenSettings()
    }

    @objc func quitClicked() {
        controller?.handleQuit()
    }
}
