import Foundation

/// Read-only snapshot of user settings, backed by UserDefaults.
///
/// This is a value type (struct) that captures settings at a point in time.
/// Callers should snapshot settings before crossing isolation boundaries
/// (e.g., capture before dispatching `Task.detached` for upload).
///
/// Conforms to `Sendable` because all stored properties are `Sendable` value types.
struct Settings: Sendable {
    let host: String
    let remotePath: String
    let identityFile: String?
    let isEnabled: Bool

    /// Snapshot the current settings from UserDefaults.
    ///
    /// Uses `UserDefaults.standard` — no suite name needed since SSHot has no
    /// app extensions or widgets that share preferences.
    static func current() -> Settings {
        let defaults = UserDefaults.standard
        return Settings(
            host: defaults.string(forKey: "host") ?? "home",
            remotePath: defaults.string(forKey: "remotePath") ?? "~/.paste/",
            identityFile: defaults.string(forKey: "identityFile"),
            isEnabled: defaults.object(forKey: "isEnabled") == nil
                ? true
                : defaults.bool(forKey: "isEnabled")
        )
    }

    /// Persist a value to UserDefaults.
    ///
    /// Settings is a read-only snapshot; writes go directly through UserDefaults.
    /// The next call to `Settings.current()` will reflect the change.
    static func set(_ value: Any?, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

// MARK: - Validation

/// Validation errors for settings fields.
enum SettingsValidationError: Error, Sendable, LocalizedError {
    case hostEmpty
    case hostContainsInvalidCharacters(String)
    case remotePathEmpty
    case remotePathContainsInvalidCharacters(String)
    case identityFileNotFound(String)
    case identityFileIsDirectory(String)
    case identityFileIsPublicKey(String)

    var errorDescription: String? {
        switch self {
        case .hostEmpty:
            return "SSH host cannot be empty."
        case let .hostContainsInvalidCharacters(detail):
            return "SSH host contains invalid characters: \(detail)"
        case .remotePathEmpty:
            return "Remote path cannot be empty."
        case let .remotePathContainsInvalidCharacters(detail):
            return "Remote path contains invalid characters: \(detail)"
        case let .identityFileNotFound(path):
            return "Identity file not found: \(path)"
        case let .identityFileIsDirectory(path):
            return "Identity file path is a directory: \(path)"
        case let .identityFileIsPublicKey(path):
            return "Identity file appears to be a public key (.pub). Use the private key instead: \(path)"
        }
    }
}

/// Validation functions for settings fields.
///
/// These are used both in the SettingsView (inline errors) and as a guard
/// in the Uploader (defense in depth). They are free functions to avoid
/// isolation constraints — callable from any context.
enum SettingsValidator {

    /// Characters forbidden in SSH host field.
    /// These could cause issues even though Foundation.Process doesn't use a shell,
    /// because scp/ssh may interpret some of them.
    private static let hostForbiddenCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ";`$|&(){}[]<>!'\"\\#?*"))

    /// Characters forbidden in remote path field.
    /// Spaces are explicitly forbidden. Tilde (~) is allowed for remote shell expansion.
    private static let remotePathForbiddenCharacters = CharacterSet.whitespaces
        .union(CharacterSet.newlines)
        .union(CharacterSet(charactersIn: ";`$|&(){}[]<>!'\"\\#?*"))

    /// Validate the SSH host field.
    /// - Throws: `SettingsValidationError` if invalid.
    static func validateHost(_ host: String) throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SettingsValidationError.hostEmpty
        }
        if let range = trimmed.rangeOfCharacter(from: hostForbiddenCharacters) {
            let invalid = String(trimmed[range])
            throw SettingsValidationError.hostContainsInvalidCharacters(
                "found '\(invalid)'"
            )
        }
    }

    /// Validate the remote path field.
    /// - Throws: `SettingsValidationError` if invalid.
    static func validateRemotePath(_ path: String) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SettingsValidationError.remotePathEmpty
        }
        if let range = trimmed.rangeOfCharacter(from: remotePathForbiddenCharacters) {
            let invalid = String(trimmed[range])
            throw SettingsValidationError.remotePathContainsInvalidCharacters(
                "found '\(invalid)'"
            )
        }
    }

    /// Validate the identity file path, if provided.
    /// - Throws: `SettingsValidationError` if the path is invalid.
    static func validateIdentityFile(_ path: String?) throws {
        guard let path, !path.isEmpty else {
            return // nil or empty is valid — identity file is optional
        }

        let expandedPath = NSString(string: path).expandingTildeInPath
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
            throw SettingsValidationError.identityFileNotFound(path)
        }
        guard !isDirectory.boolValue else {
            throw SettingsValidationError.identityFileIsDirectory(path)
        }
        guard !path.hasSuffix(".pub") else {
            throw SettingsValidationError.identityFileIsPublicKey(path)
        }
    }

    /// Validate all settings fields.
    /// - Returns: An array of validation errors (empty if all valid).
    static func validateAll(_ settings: Settings) -> [any Error] {
        var errors: [any Error] = []
        do { try validateHost(settings.host) } catch { errors.append(error) }
        do { try validateRemotePath(settings.remotePath) } catch { errors.append(error) }
        do { try validateIdentityFile(settings.identityFile) } catch { errors.append(error) }
        return errors
    }
}
