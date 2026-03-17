import Foundation
import os

/// Result of a subprocess execution.
struct ProcessResult: Sendable {
    let exitCode: Int32
    let stderr: String
}

/// Shared async subprocess helper for running /usr/bin/scp, /usr/bin/ssh, etc.
///
/// Uses the `terminationHandler` + `withCheckedThrowingContinuation` bridge pattern.
/// An `OSAllocatedUnfairLock<Bool>` guards against double-resume (e.g., when a timeout
/// terminates the process and the `terminationHandler` also fires).
///
/// This is a free function — no actor or class isolation — so callers from any
/// isolation domain can use it without unnecessary await overhead.
///
/// - Parameters:
///   - executablePath: Absolute path to the executable (e.g., "/usr/bin/scp").
///   - arguments: Arguments to pass to the process.
/// - Returns: A `ProcessResult` containing the exit code and captured stderr.
/// - Throws: If the process cannot be launched (e.g., executable not found).
func runProcess(
    executablePath: String,
    arguments: [String]
) async throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments

    // Capture stderr via Pipe
    let stderrPipe = Pipe()
    process.standardError = stderrPipe

    // Discard stdout — we don't need it for SCP/SSH
    process.standardOutput = FileHandle.nullDevice

    let result: ProcessResult = try await withCheckedThrowingContinuation { continuation in
        // Sendable guard: ensures the continuation is resumed exactly once.
        // OSAllocatedUnfairLock is Sendable, unlike a bare Bool, so it satisfies
        // Swift 6 strict concurrency for the @Sendable terminationHandler closure.
        let resumed = OSAllocatedUnfairLock(initialState: false)

        process.terminationHandler = { terminatedProcess in
            // Read stderr after termination to ensure all data has been written.
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

            let shouldResume = resumed.withLock { alreadyResumed -> Bool in
                if alreadyResumed { return false }
                alreadyResumed = true
                return true
            }
            if shouldResume {
                continuation.resume(returning: ProcessResult(
                    exitCode: terminatedProcess.terminationStatus,
                    stderr: stderrString
                ))
            }
        }

        do {
            // Use run() — not launch() which is deprecated since macOS 10.13.
            // run() throws on failure (e.g., executable not found).
            try process.run()
        } catch {
            // If run() throws, terminationHandler never fires.
            // We MUST resume the continuation here or the calling task hangs forever.
            let shouldResume = resumed.withLock { alreadyResumed -> Bool in
                if alreadyResumed { return false }
                alreadyResumed = true
                return true
            }
            if shouldResume {
                continuation.resume(throwing: error)
            }
        }
    }

    return result
}

/// Convenience wrapper that runs a process and throws `SSHotError.processLaunchFailed`
/// if the process cannot be started.
///
/// - Parameters:
///   - executablePath: Absolute path to the executable.
///   - arguments: Arguments to pass to the process.
/// - Returns: A `ProcessResult` containing the exit code and captured stderr.
/// - Throws: `SSHotError.processLaunchFailed` if the executable cannot be launched.
func runProcessThrowing(
    executablePath: String,
    arguments: [String]
) async throws -> ProcessResult {
    do {
        return try await runProcess(executablePath: executablePath, arguments: arguments)
    } catch {
        throw SSHotError.processLaunchFailed(underlyingMessage: error.localizedDescription)
    }
}
