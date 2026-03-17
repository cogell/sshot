import Foundation

/// Shared SSH argument construction used by both the SCP upload and SSH mkdir preflight.
///
/// Centralizes BatchMode, ConnectTimeout, StrictHostKeyChecking, and IdentitiesOnly
/// so that SCP and SSH commands stay consistent. Changes to SSH options only need to
/// happen in one place.
enum SSHBaseArgs {

    /// Build the common SSH option arguments for a given settings snapshot.
    ///
    /// Returns an array like:
    /// ```
    /// ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
    ///  "-o", "ConnectTimeout=10", "-i", "/path/to/key", "-o", "IdentitiesOnly=yes"]
    /// ```
    ///
    /// - Parameter settings: A captured `Settings` snapshot (Sendable).
    /// - Returns: An array of SSH option arguments.
    static func sshBaseArgs(settings: Settings) -> [String] {
        var args: [String] = [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
        ]
        if let identityFile = settings.identityFile, !identityFile.isEmpty {
            args += ["-i", identityFile, "-o", "IdentitiesOnly=yes"]
        }
        return args
    }
}
