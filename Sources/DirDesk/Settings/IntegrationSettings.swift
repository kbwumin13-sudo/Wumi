import AppKit
import ServiceManagement
import SwiftUI

/// Desktop and login switches belong to the app rather than an individual workspace.
struct IntegrationSettings: View {
    @ObservedObject private var desktop = DesktopCoordinator.shared
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        SettingsCard(L("Desktop Management")) {
            RowStack {
                CheckRow(L("Manage Desktop Files with Wumi"),
                         detail: L("Browse, preview and organize desktop files. Show the system desktop at any time from the menu bar."),
                         isOn: Binding(get: { desktop.isEnabled }, set: { desktop.setEnabled($0) }))
                    .accessibilityIdentifier("Settings.Desktop.Enabled")
                Text(L("The managed desktop uses a static background. System widgets, dynamic wallpaper and Finder Stacks are available on the system desktop."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                CheckRow(L("Start Wumi at login"),
                         detail: L("Keep desktop management and global search available after signing in."),
                         isOn: Binding(get: { loginEnabled }, set: changeLogin))
                    .accessibilityIdentifier("Settings.LoginItem")
                if SMAppService.mainApp.status == .requiresApproval {
                    Button(L("Open Login Items Settings")) { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginError { Text(loginError).font(.system(size: 11)).foregroundStyle(.red) }
            }
        }
    }

    private func changeLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginError = nil
        } catch { loginError = error.localizedDescription }
    }
}

struct GlobalSearchShortcutSettings: View {
    @ObservedObject private var search = GlobalSearchController.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(L("Open Miji Search with a global shortcut"), isOn: $search.configuration.enabled)
                .accessibilityIdentifier("Settings.GlobalSearch.Enabled")
            HStack(spacing: 12) {
                Text(search.configuration.label).font(.system(size: 13, weight: .medium))
                Button(recording ? L("Press a Shortcut…") : L("Record Shortcut")) {
                    recording ? stopRecording() : startRecording()
                }
                .accessibilityIdentifier("Settings.GlobalSearch.Shortcut")
            }
            if let error = search.shortcutError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
            }
            Text(L("Name, pinyin, document text and OCR share one local index across Wumi, the desktop and Floating Files."))
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
            guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
            var configuration = search.configuration
            configuration.keyCode = UInt32(event.keyCode)
            configuration.modifiers = KeyCodeNames.carbonModifiers(flags)
            search.configuration = configuration
            stopRecording()
            return nil
        }
    }
    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = false
    }
}
