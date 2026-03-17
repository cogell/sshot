import AppKit

/// The @main entry point for SSHot.
///
/// This is a menu bar app with LSUIElement=YES — no Dock icon, no main window.
/// We use a manual NSApplication.shared.run() approach with AppDelegate rather
/// than SwiftUI's @main App protocol (which expects a WindowGroup).
@main
enum SSHotApp {
    static func main() {
        let app = NSApplication.shared
        // NSApplication.delegate is weak, but `delegate` stays in scope because
        // app.run() blocks until app termination — keeping this local alive.
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
