import AppKit
import DirDeskCore
import SwiftUI

/// Removable-device arrival (ask / open Device Workspace / show in Locations only) and safe ejection.
@MainActor
final class DeviceCoordinator {
    static let shared = DeviceCoordinator()
    weak var appDelegate: AppDelegate?
    private var observer: NSObjectProtocol?
    private var prompt: NSPanel?

    func install(delegate: AppDelegate) {
        appDelegate = delegate
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { DeviceCoordinator.shared.deviceMounted(url) }
        }
    }

    private func deviceMounted(_ url: URL) {
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeNameKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsLocal != false,
              values.volumeIsRemovable == true || values.volumeIsEjectable == true || values.volumeIsInternal == false else { return }
        let name = values.volumeName ?? url.lastPathComponent
        switch AppModel.shared.preferences.removableDeviceBehavior {
        case .showInLocationsOnly: break
        case .openDeviceWorkspace: openDeviceWorkspace(url)
        case .ask: showPrompt(name: name, url: url)
        }
    }

    /// Two panes: the device on the left, the active local folder on the right.
    func openDeviceWorkspace(_ device: URL) {
        guard let delegate = appDelegate else { return }
        let controller = delegate.activeController ?? delegate.newWindow(directory: nil)
        let local = controller.model.activePane.currentDirectory ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        guard let tab = controller.model.newTab(directory: device) else { return }
        tab.setLayout(.twoColumns, configuration: controller.model.activePane.viewConfiguration)
        if tab.panes.count > 1 { tab.panes[1].open(local) }
        controller.model.allPanes.forEach(controller.model.attach)
        controller.window?.makeKeyAndOrderFront(nil)
        activateApp()
    }

    private func showPrompt(name: String, url: URL) {
        prompt?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 130), styleMask: [.titled, .closable, .utilityWindow, .hudWindow],
                            backing: .buffered, defer: false)
        panel.title = L("Device connected")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: DeviceConnectionCard(name: name, open: { [weak self, weak panel] in
            self?.openDeviceWorkspace(url)
            panel?.close()
        }, dismiss: { [weak panel] in panel?.close() }))
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 360, y: screen.visibleFrame.maxY - 150))
        }
        panel.orderFrontRegardless()
        prompt = panel
    }

    /// Ejects a volume, first asking when DirDesk operations still use it.
    func eject(_ volume: VolumeMonitor.Volume, presentingIn window: NSWindow?) {
        guard let operations = appDelegate?.operations else { return }
        let prefix = volume.url.standardizedFileURL.path
        let busy = operations.tasks.filter { task in
            !task.finished && (task.plan.destinationDirectory.path.hasPrefix(prefix) || task.plan.sources.contains { $0.path.hasPrefix(prefix) })
        }
        guard !busy.isEmpty else {
            performEject(volume)
            return
        }
        let alert = NSAlert()
        alert.messageText = L("The device is in use")
        alert.informativeText = LF("The device is still in use by %lld operation(s).", Int64(busy.count)) + "\n"
            + L("Wait for current work to finish, or cancel only the operations using this device before ejecting it.")
        alert.addButton(withTitle: L("Wait and Eject"))
        alert.addButton(withTitle: L("Cancel Operations and Eject"))
        alert.addButton(withTitle: L("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            waitThenEject(volume, ids: Set(busy.map(\.id)))
        case .alertSecondButtonReturn:
            busy.forEach { operations.cancel($0.id) }
            waitThenEject(volume, ids: Set(busy.map(\.id)))
        default:
            break
        }
    }

    private func waitThenEject(_ volume: VolumeMonitor.Volume, ids: Set<UUID>) {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let operations = self?.appDelegate?.operations else { timer.invalidate(); return }
                if !operations.tasks.contains(where: { ids.contains($0.id) && !$0.finished }) {
                    timer.invalidate()
                    self?.performEject(volume)
                }
            }
        }
    }

    private func performEject(_ volume: VolumeMonitor.Volume) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
        } catch {
            NSAlert.show(L("This volume cannot be ejected.") + "\n" + error.localizedDescription)
        }
    }
}

private struct DeviceConnectionCard: View {
    let name: String
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill").font(.system(size: 26)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    Text(L("Open a two-pane Device Workspace to move files between your Mac and this device.")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button(L("Show in Locations only"), action: dismiss)
                Button(L("Open Device Workspace"), action: open).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }
}
