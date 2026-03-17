import Foundation
import UserNotifications
import os

/// Manages user notification authorization and dispatching upload result notifications.
///
/// Requests UNUserNotificationCenter authorization on first launch. Dispatches
/// success/failure notifications with error-specific guidance. Falls back to
/// returning abbreviated text for menu item display if notification auth is denied.
@MainActor
final class NotificationManager {

    /// Whether the user has granted notification authorization.
    /// If false, callers should fall back to menu item text.
    private(set) var isAuthorized: Bool = false

    private let center = UNUserNotificationCenter.current()

    /// Logger for this component.
    /// `os.Logger` is not marked `Sendable` as of Xcode 16.x. Since this logger
    /// is only accessed from @MainActor methods, we use `nonisolated(unsafe)` per
    /// the plan's guidance.
    private let logger = Logger(subsystem: "com.cogell.sshot", category: "Notifications")

    // MARK: - Authorization

    /// Request notification authorization. Call once at app launch.
    ///
    /// Sets `isAuthorized` based on the user's response. If already determined
    /// (e.g., on subsequent launches), reads the current authorization status.
    func requestAuthorization() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            isAuthorized = granted
            if granted {
                logger.info("Notification authorization granted")
            } else {
                logger.info("Notification authorization denied — will use menu item fallback")
            }
        } catch {
            isAuthorized = false
            logger.error(
                "Notification authorization request failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Dispatch

    /// Post a notification for a successful upload.
    ///
    /// - Parameter remotePath: The remote file path that was uploaded.
    /// - Returns: A fallback menu item string if notifications are not authorized.
    @discardableResult
    func notifySuccess(remotePath: String) -> String {
        let fallbackText = "Last: \u{2713} uploaded"

        guard isAuthorized else {
            logger.debug("Notifications not authorized — returning fallback text")
            return fallbackText
        }

        let content = UNMutableNotificationContent()
        content.title = "Screenshot uploaded"
        content.body = remotePath
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "sshot-upload-success-\(UUID().uuidString)",
            content: content,
            trigger: nil // deliver immediately
        )

        // Use Task to dispatch notification — avoids capturing Logger across
        // isolation boundaries (Logger is not Sendable as of Xcode 16.x).
        Task {
            do {
                try await center.add(request)
            } catch {
                logger.error(
                    "Failed to deliver success notification: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        return fallbackText
    }

    /// Post a notification for a failed upload with error-specific guidance.
    ///
    /// - Parameters:
    ///   - error: The error from the upload pipeline.
    ///   - host: The SSH host (used in error guidance messages).
    /// - Returns: A fallback menu item string if notifications are not authorized.
    @discardableResult
    func notifyFailure(error: Error, host: String) -> String {
        let (title, body, fallback) = formatError(error, host: host)

        guard isAuthorized else {
            logger.debug("Notifications not authorized — returning fallback text")
            return fallback
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "sshot-upload-failure-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        Task {
            do {
                try await center.add(request)
            } catch {
                logger.error(
                    "Failed to deliver failure notification: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        return fallback
    }

    // MARK: - Error formatting

    /// Format an error into notification title, body, and fallback menu text.
    private func formatError(_ error: Error, host: String) -> (title: String, body: String, fallback: String) {
        guard let sshotError = error as? SSHotError else {
            return (
                title: "Upload failed",
                body: error.localizedDescription,
                fallback: "Last: \u{2717} failed"
            )
        }

        switch sshotError {
        case .timeout:
            return (
                title: "Upload timed out",
                body: "Upload timed out after 30 seconds. Check your network connection.",
                fallback: "Last: \u{2717} timed out"
            )

        case let .scpFailed(exitCode, _, classification):
            switch classification {
            case .hostKeyMismatch:
                return (
                    title: "SSH host key changed",
                    body: "Run: ssh-keygen -R \(host)",
                    fallback: "Last: \u{2717} host key changed"
                )
            case .authFailure:
                return (
                    title: "SSH authentication failed",
                    body: "SSH key requires passphrase \u{2014} ensure ssh-agent is running",
                    fallback: "Last: \u{2717} auth failed"
                )
            case .connectionRefused:
                return (
                    title: "Connection refused",
                    body: "Connection refused by \(host)",
                    fallback: "Last: \u{2717} connection refused"
                )
            case .unknown:
                return (
                    title: "Upload failed",
                    body: "SCP failed with exit code \(exitCode)",
                    fallback: "Last: \u{2717} upload failed"
                )
            }

        case let .processLaunchFailed(message):
            return (
                title: "Launch error",
                body: "Failed to launch process: \(message)",
                fallback: "Last: \u{2717} launch error"
            )

        case let .imageTooLarge(bytes):
            let mb = Double(bytes) / 1_048_576.0
            let mbString = String(format: "%.1f", mb)
            return (
                title: "Image too large",
                body: "Image too large (\(mbString) MB). Maximum is 20 MB.",
                fallback: "Last: \u{2717} image too large"
            )

        case let .mkdirFailed(exitCode, stderr):
            return (
                title: "Remote directory error",
                body: "Failed to create remote directory (exit \(exitCode)): \(stderr)",
                fallback: "Last: \u{2717} mkdir failed"
            )

        case let .invalidSettings(errors):
            return (
                title: "Invalid settings",
                body: errors.joined(separator: "\n"),
                fallback: "Last: \u{2717} invalid settings"
            )
        }
    }
}
