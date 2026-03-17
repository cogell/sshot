import Foundation

/// Classification of SCP/SSH errors based on stderr parsing.
/// Used by the notification layer to format user-facing messages
/// and by retry logic to distinguish retryable vs non-retryable errors.
enum ErrorClassification: Sendable {
    /// stderr contains "REMOTE HOST IDENTIFICATION HAS CHANGED"
    case hostKeyMismatch
    /// stderr contains "Permission denied" (passphrase-protected key, no agent)
    case authFailure
    /// stderr contains "Connection refused"
    case connectionRefused
    /// Unrecognized error
    case unknown
}

/// Shared error type used across the upload engine, notifications, and UI.
enum SSHotError: Error, Sendable {
    /// SCP exceeded 30s timeout.
    case timeout
    /// Non-zero SCP exit with parsed classification.
    case scpFailed(exitCode: Int32, stderr: String, classification: ErrorClassification)
    /// /usr/bin/scp or /usr/bin/ssh not found or not executable.
    case processLaunchFailed(underlyingMessage: String)
    /// Clipboard image exceeds 20 MB threshold.
    case imageTooLarge(bytes: Int)
    /// Remote directory creation failed (`ssh mkdir -p`).
    case mkdirFailed(exitCode: Int32, stderr: String)
    /// Settings failed validation (defense-in-depth guard in Uploader).
    case invalidSettings(errors: [String])

    /// Classify an SCP/SSH stderr string into a known error category.
    static func classify(stderr: String) -> ErrorClassification {
        if stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return .hostKeyMismatch
        } else if stderr.contains("Permission denied") {
            return .authFailure
        } else if stderr.contains("Connection refused") {
            return .connectionRefused
        } else {
            return .unknown
        }
    }
}

extension SSHotError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Upload timed out after 30 seconds."
        case let .scpFailed(exitCode, _, classification):
            switch classification {
            case .hostKeyMismatch:
                return "SSH host key mismatch — run `ssh-keygen -R <host>` to remove the old key. (exit \(exitCode))"
            case .authFailure:
                return "SSH authentication failed — ensure ssh-agent is running if your key requires a passphrase. (exit \(exitCode))"
            case .connectionRefused:
                return "Connection refused by remote host. (exit \(exitCode))"
            case .unknown:
                return "SCP failed with exit code \(exitCode)."
            }
        case let .processLaunchFailed(message):
            return "Failed to launch process: \(message)"
        case let .imageTooLarge(bytes):
            let mb = Double(bytes) / 1_048_576.0
            return String(format: "Image too large (%.1f MB). Maximum is 20 MB.", mb)
        case let .mkdirFailed(exitCode, stderr):
            return "Failed to create remote directory (exit \(exitCode)): \(stderr)"
        case let .invalidSettings(errors):
            return "Invalid settings: \(errors.joined(separator: "; "))"
        }
    }
}
