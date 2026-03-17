import AppKit

/// Shared pasteboard constants used by both ClipboardWatcher (read) and
/// the clipboard write-back path (write).
///
/// Defined in its own file so both sides can reference the marker type
/// without importing each other.
enum PasteboardConstants {
    /// Custom pasteboard type used as a self-loop marker.
    ///
    /// When SSHot writes a remote path back to the clipboard, it includes
    /// this marker type in the same `NSPasteboardItem`. When the watcher
    /// detects a `changeCount` increment, it checks for this marker first —
    /// if present, the clipboard change originated from SSHot and is skipped.
    ///
    /// The value is a zero-byte `Data` — its mere presence is the signal.
    /// The reverse-DNS string avoids collisions with real pasteboard types.
    static let markerType = NSPasteboard.PasteboardType("com.cogell.sshot.marker")
}
