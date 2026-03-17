import SwiftUI
import ServiceManagement

/// SwiftUI settings panel with General and About tabs.
///
/// Hosted in a plain NSWindow via NSHostingView (see SettingsWindowController).
/// Apple's Settings scene cannot be opened programmatically from an NSMenu action,
/// so we use this approach instead.
struct SettingsView: View {

    /// Callback to notify the app that settings have changed.
    /// Wired by SettingsWindowController / AppDelegate.
    var onSettingsChanged: (() -> Void)?

    /// Callback to trigger a Sparkle update check.
    /// Wired by SettingsWindowController from AppDelegate's SPUStandardUpdaterController.
    var onCheckForUpdates: (() -> Void)?

    @State private var host: String
    @State private var remotePath: String
    @State private var identityFile: String
    @State private var launchAtLogin: Bool

    @State private var hostError: String?
    @State private var remotePathError: String?
    @State private var identityFileError: String?

    init(
        onSettingsChanged: (() -> Void)? = nil,
        onCheckForUpdates: (() -> Void)? = nil
    ) {
        self.onSettingsChanged = onSettingsChanged
        self.onCheckForUpdates = onCheckForUpdates

        let settings = Settings.current()
        _host = State(initialValue: settings.host)
        _remotePath = State(initialValue: settings.remotePath)
        _identityFile = State(initialValue: settings.identityFile ?? "")
        _launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 450, height: 300)
        .padding()
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section {
                TextField("SSH Host:", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: host) { _, newValue in
                        validateAndSaveHost(newValue)
                    }
                if let hostError {
                    Text(hostError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                TextField("Remote Path:", text: $remotePath)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: remotePath) { _, newValue in
                        validateAndSaveRemotePath(newValue)
                    }
                if let remotePathError {
                    Text(remotePathError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                HStack {
                    TextField("Identity File:", text: $identityFile)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse\u{2026}") {
                        browseForIdentityFile()
                    }
                }
                .onChange(of: identityFile) { _, _ in
                    // Clear error while user is typing; save and validation are debounced below
                    identityFileError = nil
                }
                .task(id: identityFile) {
                    // Debounce filesystem validation — FileManager.fileExists is called
                    // per-keystroke otherwise, showing transient errors while typing paths.
                    // Save is also debounced to avoid persisting incomplete paths.
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    let trimmed = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
                    do {
                        try SettingsValidator.validateIdentityFile(trimmed.isEmpty ? nil : trimmed)
                        identityFileError = nil
                        Settings.set(trimmed.isEmpty ? nil : trimmed, forKey: "identityFile")
                        onSettingsChanged?()
                    } catch {
                        identityFileError = error.localizedDescription
                    }
                }
                if let identityFileError {
                    Text(identityFileError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Optional. Leave empty to use the default SSH key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("SSHot")
                .font(.title)
                .fontWeight(.bold)

            Text("Version \(appVersion)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Clipboard-to-SSH screenshot uploader for macOS")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let url = URL(string: "https://github.com/cogell/sshot") {
                Link("View on GitHub", destination: url)
                    .font(.body)
            }

            Button("Check for Updates\u{2026}") {
                onCheckForUpdates?()
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Validation & Persistence

    private func validateAndSaveHost(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try SettingsValidator.validateHost(trimmed)
            hostError = nil
            Settings.set(trimmed, forKey: "host")
            onSettingsChanged?()
        } catch {
            hostError = error.localizedDescription
        }
    }

    private func validateAndSaveRemotePath(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try SettingsValidator.validateRemotePath(trimmed)
            remotePathError = nil
            Settings.set(trimmed, forKey: "remotePath")
            onSettingsChanged?()
        } catch {
            remotePathError = error.localizedDescription
        }
    }

    private func browseForIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.message = "Select your SSH private key"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            identityFile = url.path(percentEncoded: false)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert toggle on failure
            launchAtLogin = !enabled
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }
}
