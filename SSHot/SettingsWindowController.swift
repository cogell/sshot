import AppKit
import SwiftUI

/// Wraps the SwiftUI SettingsView in an NSWindow for programmatic display.
///
/// Apple's Settings scene cannot be opened programmatically from an NSMenu action
/// (no `Environment(\.openSettings)` outside a SwiftUI view hierarchy). This class
/// provides a plain NSWindow + NSHostingView approach instead.
///
/// For LSUIElement apps, `NSApp.activate()` under cooperative activation (macOS 14+)
/// may not reliably foreground the window. The workaround is to temporarily set the
/// activation policy to `.regular`, activate, order front, then restore `.accessory`.
@MainActor
final class SettingsWindowController {

    /// Callback forwarded from SettingsView when settings change.
    var onSettingsChanged: (() -> Void)?

    /// Callback forwarded to SettingsView for Sparkle "Check for Updates" button.
    var onCheckForUpdates: (() -> Void)?

    private var window: NSWindow?

    /// Show the settings window, creating it if needed.
    func showWindow() {
        if let existingWindow = window, existingWindow.isVisible {
            bringToFront(existingWindow)
            return
        }

        // Close old window before creating a new one (isReleasedWhenClosed is false,
        // so without explicit close the old window would leak until ARC collects it).
        window?.close()

        let settingsView = SettingsView(
            onSettingsChanged: { [weak self] in
                self?.onSettingsChanged?()
            },
            onCheckForUpdates: { [weak self] in
                self?.onCheckForUpdates?()
            }
        )

        let hostingView = NSHostingView(rootView: settingsView)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "SSHot Settings"
        newWindow.contentView = hostingView
        newWindow.center()
        newWindow.isReleasedWhenClosed = false

        // Set the window level to floating so it appears above other windows
        // even when the app is an accessory (LSUIElement).
        newWindow.level = .floating

        self.window = newWindow

        bringToFront(newWindow)
    }

    /// Bring the settings window to the front using the LSUIElement workaround.
    ///
    /// LSUIElement apps run with `.accessory` activation policy, which means
    /// `NSApp.activate()` alone may not reliably foreground windows under
    /// macOS 14+ cooperative activation. The workaround:
    /// 1. Temporarily set activation policy to `.regular`
    /// 2. Activate the app
    /// 3. Order the window front
    /// 4. Restore `.accessory` policy
    private func bringToFront(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

        // Restore .accessory after a brief delay to allow the window to come forward.
        // The delay is needed because restoring .accessory immediately can cause the
        // window to lose focus before it finishes the activation animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
