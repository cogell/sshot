import Foundation
import os

/// Uploads clipboard images to a remote server via SCP.
///
/// This type is intentionally NOT `@MainActor` — it runs on the cooperative thread pool
/// via `Task.detached`. All settings values are passed in as parameters (captured
/// `Settings` snapshot) to avoid reading from `Settings.shared` across isolation boundaries.
///
/// Uses `runProcessThrowing` (from ProcessRunner.swift) for the SSH mkdir preflight.
/// For SCP uploads, uses `runCancellableProcess` (below) to enable process termination
/// on timeout or task cancellation — the continuation bridge pattern (OSAllocatedUnfairLock
/// + terminationHandler) matches ProcessRunner exactly but accepts a pre-constructed Process.
enum Uploader {

    // MARK: - Constants

    private static let scpPath = "/usr/bin/scp"
    private static let sshPath = "/usr/bin/ssh"
    private static let timeoutSeconds = 30
    private static let retryDelay: Duration = .seconds(2)
    private static let maxImageBytes = 20 * 1_048_576 // 20 MB

    // MARK: - Public Entry Point

    /// Upload PNG image data to the remote server.
    ///
    /// - Parameters:
    ///   - imageData: Raw PNG data from the pasteboard.
    ///   - settings: A captured `Settings` snapshot (Sendable value type).
    /// - Returns: The full remote path string (e.g., `~/.paste/2026-03-17T103045_a3f2.png`).
    /// - Throws: `SSHotError` on failure (timeout, SCP failure, launch failure, mkdir failure,
    ///   image too large, invalid settings).
    static func upload(imageData: Data, settings: Settings) async throws -> String {
        let logger = Logger(subsystem: "com.cogell.sshot", category: "Uploader")

        // --- Defense-in-depth: validate settings before use ---
        let validationErrors = SettingsValidator.validateAll(settings)
        guard validationErrors.isEmpty else {
            throw SSHotError.invalidSettings(
                errors: validationErrors.map { $0.localizedDescription }
            )
        }

        // --- Image size guard ---
        guard imageData.count <= maxImageBytes else {
            throw SSHotError.imageTooLarge(bytes: imageData.count)
        }

        // --- Generate timestamped filename ---
        let filename = generateFilename()
        let remotePath = normalizeRemotePath(settings.remotePath)
        let fullRemotePath = "\(remotePath)\(filename)"

        // --- Write temp file (outer-scope defer survives retries) ---
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(filename)
        try imageData.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        logger.info("Upload starting: \(filename, privacy: .public) (\(imageData.count) bytes)")

        // --- Remote directory preflight ---
        try await ensureRemoteDirectory(settings: settings, logger: logger)

        // --- Upload with retry ---
        try await uploadWithRetry(
            tempFile: tempFile,
            filename: filename,
            settings: settings,
            logger: logger
        )

        logger.info("Upload succeeded: \(fullRemotePath, privacy: .public)")
        return fullRemotePath
    }

    // MARK: - Filename Generation

    /// Generate a timestamped filename: `YYYYMMDDTHHMMSS_xxxx.png`
    ///
    /// Colons are omitted from the time portion for filesystem compatibility.
    /// The 4-character hex suffix prevents sub-second collisions.
    private static func generateFilename() -> String {
        // Created locally — DateFormatter is not thread-safe, and caching saves
        // negligible time since uploads are infrequent.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        formatter.timeZone = TimeZone.current
        let timestamp = formatter.string(from: Date())

        // 4-char random hex suffix
        let suffix = String(format: "%04x", UInt16.random(in: 0...UInt16.max))

        return "\(timestamp)_\(suffix).png"
    }

    // MARK: - Helpers

    /// Ensure remote path ends with a trailing slash.
    private static func normalizeRemotePath(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    // MARK: - Remote Directory Preflight

    /// Ensure the remote directory exists via `ssh mkdir -p`.
    ///
    /// Runs before every upload. `mkdir -p` is idempotent and takes <50ms over SSH.
    /// Uses the same SSH base arguments as SCP for consistency.
    /// Uses `runProcessThrowing` from ProcessRunner — no cancellation needed for this
    /// short-lived command.
    ///
    /// The remote path is single-quoted to prevent shell expansion of metacharacters.
    private static func ensureRemoteDirectory(
        settings: Settings,
        logger: Logger
    ) async throws {
        var args = SSHBaseArgs.sshBaseArgs(settings: settings)
        // The remote path is NOT shell-quoted because single quotes would prevent
        // tilde expansion (e.g., '~/.paste/' creates a literal '~' directory).
        // This is safe because the validator rejects all shell metacharacters
        // (;`$|&(){}[]<>!'"\#?*) — only safe characters reach this point.
        args += [settings.host, "mkdir -p \(settings.remotePath)"]

        logger.debug("mkdir preflight: ssh \(args.joined(separator: " "), privacy: .public)")

        let result = try await runProcessThrowing(
            executablePath: sshPath,
            arguments: args
        )

        guard result.exitCode == 0 else {
            logger.error("mkdir failed (exit \(result.exitCode)): \(result.stderr, privacy: .public)")
            throw SSHotError.mkdirFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    // MARK: - Retry Logic

    /// Upload with one automatic retry on transient SCP failure.
    ///
    /// Retries on: non-zero SCP exit code (transient network error).
    /// Does NOT retry on: `SSHotError.timeout`, `SSHotError.processLaunchFailed`,
    /// `SSHotError.mkdirFailed`, `SSHotError.imageTooLarge`, `SSHotError.invalidSettings`.
    ///
    /// Worst-case wall-clock: 30s + 2s + 30s = 62s.
    private static func uploadWithRetry(
        tempFile: URL,
        filename: String,
        settings: Settings,
        logger: Logger
    ) async throws {
        do {
            try await uploadOnce(
                tempFile: tempFile,
                filename: filename,
                settings: settings,
                logger: logger
            )
        } catch let error as SSHotError {
            // Only retry on scpFailed (non-zero exit). All other SSHotError cases are
            // non-retryable: timeout (already wasted 30s), processLaunchFailed
            // (permanent — binary missing), mkdirFailed, imageTooLarge, invalidSettings.
            guard case .scpFailed = error else {
                throw error
            }

            logger.warning(
                "SCP failed, retrying in \(Self.retryDelay.components.seconds)s: \(error.localizedDescription, privacy: .public)"
            )

            // 2s delay before retry. Task.sleep responds to cancellation —
            // if the task is cancelled during the delay, CancellationError is thrown.
            try await Task.sleep(for: retryDelay)

            // Retry once. If this also fails, the error propagates to the caller.
            try await uploadOnce(
                tempFile: tempFile,
                filename: filename,
                settings: settings,
                logger: logger
            )
        }
    }

    // MARK: - Single Upload Attempt (Timeout Race)

    /// Execute a single SCP upload with a 30-second timeout.
    ///
    /// Uses `withThrowingTaskGroup` to race the SCP process against `Task.sleep`.
    /// `withTaskCancellationHandler` wraps the SCP call at BOTH scopes:
    /// - **Inner** (inside group child task): handles timeout-triggered cancellation
    ///   via `group.cancelAll()`.
    /// - **Outer** (wrapping the entire group): handles app disable/quit cancellation
    ///   via `task.cancel()` from `ClipboardWatcher`.
    ///
    /// Both handlers call `process.terminate()` to ensure the SCP subprocess is killed
    /// promptly — `Foundation.Process` has zero awareness of Swift structured concurrency.
    private static func uploadOnce(
        tempFile: URL,
        filename: String,
        settings: Settings,
        logger: Logger
    ) async throws {
        // Build SCP arguments
        let localPath = tempFile.path(percentEncoded: false)
        let remotePath = normalizeRemotePath(settings.remotePath)
        let remoteTarget = "\(settings.host):\(remotePath)\(filename)"

        var args = SSHBaseArgs.sshBaseArgs(settings: settings)
        args += [localPath, remoteTarget]

        logger.debug("SCP: \(scpPath) \(args.joined(separator: " "), privacy: .public)")

        // Create the Process up front so cancellation handlers can terminate it.
        // Wrapped in ProcessRef (Sendable) immediately — Process is not Sendable,
        // so we never capture the raw Process in @Sendable closures.
        let processRef: ProcessRef = {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: scpPath)
            process.arguments = args
            return ProcessRef(process)
        }()

        // OUTER withTaskCancellationHandler: handles app disable/quit.
        // When ClipboardWatcher cancels the Task.detached handle, this fires
        // and terminates the SCP process.
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Child 1: SCP process with inner cancellation handler
                group.addTask {
                    // Create a Logger locally — os.Logger is not Sendable as of Xcode 16.x,
                    // so each child task needs its own instance.
                    let childLogger = Logger(subsystem: "com.cogell.sshot", category: "Uploader")

                    // INNER withTaskCancellationHandler: handles timeout cancellation
                    // (group.cancelAll) and also outer task cancellation. Foundation.Process
                    // has no awareness of Swift concurrency — we MUST explicitly terminate it.
                    try await withTaskCancellationHandler {
                        let result = try await runCancellableProcess(processRef)

                        guard result.exitCode == 0 else {
                            let classification = SSHotError.classify(stderr: result.stderr)
                            childLogger.error(
                                "SCP failed (exit \(result.exitCode), \(String(describing: classification))): \(result.stderr, privacy: .public)"
                            )
                            throw SSHotError.scpFailed(
                                exitCode: result.exitCode,
                                stderr: result.stderr,
                                classification: classification
                            )
                        }
                    } onCancel: {
                        processRef.terminate()
                    }
                }

                // Child 2: Timeout timer
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    // If sleep completes without cancellation, timeout has fired.
                    throw SSHotError.timeout
                }

                // Wait for the first child to complete.
                // - SCP success (exit 0): next() returns normally, cancel the timer.
                // - SCP failure (non-zero exit): next() throws scpFailed, propagates
                //   to retry logic.
                // - Timeout: next() throws SSHotError.timeout, cancel SCP child.
                //
                // Note: withThrowingTaskGroup awaits ALL children before returning,
                // even after cancelAll(). The SCP child responds to cancellation via
                // process.terminate() -> terminationHandler -> continuation.resume(),
                // so it won't hang.
                do {
                    try await group.next()
                    // First child finished without error — cancel the loser.
                    group.cancelAll()
                } catch {
                    // Any error (timeout or SCP failure): cancel remaining children,
                    // then rethrow. For timeout, this cancels the SCP child (triggering
                    // onCancel -> process.terminate). For SCP failure, this cancels the
                    // sleep timer (Task.sleep responds to cancellation automatically).
                    group.cancelAll()
                    throw error
                }
            }
        } onCancel: {
            // Outer scope: app disable/quit cancellation.
            processRef.terminate()
        }
    }
}

// MARK: - Cancellable Process Runner

/// Sendable wrapper around a `Process` reference for use in `@Sendable` cancellation
/// handlers. `Process` is marked `@unchecked Sendable` in the Apple SDK (thread safety
/// is asserted by Apple but not compiler-verified). The wrapper provides a convenient
/// `terminate()` method with a safe POSIX kill() guard.
private final class ProcessRef: Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        // Use POSIX kill() directly to avoid TOCTOU race between isRunning check
        // and terminate() call. Process.terminate() throws an ObjC NSInvalidArgumentException
        // if the process already exited between the check and the call.
        // kill() with SIGTERM on an already-exited PID is a safe no-op (returns ESRCH).
        let pid = process.processIdentifier
        if pid > 0 {
            kill(pid, SIGTERM)
        }
    }
}

/// Run a pre-constructed `Process` (via its `ProcessRef` wrapper) using the same
/// continuation bridge pattern as `ProcessRunner.runProcess`. The caller retains
/// the `ProcessRef` for cancellation (via `processRef.terminate()`).
///
/// Accepts `ProcessRef` (Sendable) rather than raw `Process` so this function can
/// be called from `@Sendable` closures (e.g., `group.addTask`).
///
/// - Parameter processRef: A `ProcessRef` wrapping a fully configured `Process`
///   (executableURL, arguments set). The caller must NOT call `run()` — this function does.
/// - Returns: A `ProcessResult` with exit code and captured stderr.
/// - Throws: `SSHotError.processLaunchFailed` if `process.run()` fails.
private func runCancellableProcess(_ processRef: ProcessRef) async throws -> ProcessResult {
    let process = processRef.process
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    process.standardOutput = FileHandle.nullDevice

    do {
        let result: ProcessResult = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)

            process.terminationHandler = { terminatedProcess in
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
                try process.run()
            } catch {
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
    } catch {
        throw SSHotError.processLaunchFailed(underlyingMessage: error.localizedDescription)
    }
}
