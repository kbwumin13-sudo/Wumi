import AppKit
import DirDeskCore
import SwiftUI

/// "Connect to Server" sheet laid out like the original: protocol icon and title ("SMB Location"), connection
/// type, server address with the protocol tag, per-protocol help and example, optional display name, the note that
/// macOS handles sign-in, then Cancel / Add and Connect.
struct ConnectToServerSheet: View {
    let cancel: () -> Void
    let onMounted: (URL) -> Void
    @State private var protocolKind: NetworkLocationStore.ProtocolKind

    init(protocolKind: NetworkLocationStore.ProtocolKind = .smb, cancel: @escaping () -> Void, onMounted: @escaping (URL) -> Void) {
        self.cancel = cancel
        self.onMounted = onMounted
        _protocolKind = State(initialValue: protocolKind)
    }

    /// Menu order of the original (connection type pop-up and the sidebar's Locations ＋ menu).
    static let protocolOrder: [NetworkLocationStore.ProtocolKind] = [.smb, .afp, .nfs, .https, .http, .ftp]

    static func menuTitle(_ kind: NetworkLocationStore.ProtocolKind) -> String {
        switch kind {
        case .smb: "SMB"
        case .afp: "AFP"
        case .nfs: "NFS"
        case .https: "WebDAV HTTPS"
        case .http: "WebDAV HTTP"
        case .ftp: L("FTP (Read Only)")
        }
    }
    @State private var address = ""
    @State private var name = ""
    @State private var error: String?
    @State private var connecting = false

    // Metrics follow the original's 520 × 467 pt sheet (runtime capture `connect-to-server-sheet`): 28 pt margins,
    // a 60 pt outlined tile beside a 21 pt title, 12 pt help text and large buttons.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16.5) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.09))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1))
                    .frame(width: 60, height: 60)
                    .overlay(Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 25)).foregroundStyle(Color.accentColor))
                VStack(alignment: .leading, spacing: 6) {
                    Text(LF("%@ Location", protocolTitle)).font(.system(size: 21, weight: .bold))
                    Text(L("Your servers, a click away.")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 9) {
                Text(L("Connection Type")).font(.system(size: 13, weight: .semibold))
                Picker(L("Connection Type"), selection: $protocolKind) {
                    ForEach(Self.protocolOrder, id: \.self) { kind in
                        Text(Self.menuTitle(kind)).tag(kind)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("Network.ConnectionType")
            }
            .padding(.top, 24)
            HStack {
                Text(L("Server Address")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(protocolTag).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.top, 17)
            TextField(L("Server Address"), text: $address, prompt: Text(example))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .accessibilityIdentifier("Network.ServerAddress")
                .padding(.top, 8)
            Text(help).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            Text(example).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 8)
            Text(L("Display Name (Optional)")).font(.system(size: 12, weight: .semibold)).padding(.top, 17.5)
            TextField(L("Display Name (Optional)"), text: $name, prompt: Text(L("Office NAS")))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("Network.DisplayName")
                .padding(.top, 7)
            Label(L("macOS handles sign-in. Passwords are never saved by Wumi."), systemImage: "lock.shield")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 24)
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).padding(.top, 8)
            }
            Divider().padding(.top, 24).padding(.bottom, 24)
            HStack {
                Spacer()
                Button(L("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(connecting ? L("Connecting…") : L("Add and Connect")) { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(connecting || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 28.5)
        .frame(width: 520)
    }

    private var protocolTitle: String {
        switch protocolKind {
        case .smb: "SMB"
        case .afp: "AFP"
        case .nfs: "NFS"
        case .ftp: "FTP"
        case .https, .http: "WebDAV"
        }
    }

    private var protocolTag: String {
        switch protocolKind {
        case .https: "HTTPS"
        case .http: "HTTP"
        default: protocolTitle
        }
    }

    private var example: String {
        switch protocolKind {
        case .smb: "smb://192.168.1.10/share"
        case .afp: "afp://192.168.1.10/share"
        case .nfs: "nfs://192.168.1.10/exports/data"
        case .ftp: "ftp://ftp.example.com"
        case .https: "https://dav.example.com/folder"
        case .http: "http://192.168.1.10/dav"
        }
    }

    private var help: String {
        switch protocolKind {
        case .smb, .afp:
            LF("A server name or IP address is enough: macOS then offers its shares. Append /share to open one share directly. %@ sharing must be on at the server.", protocolTitle)
        case .nfs: L("Give the full exported folder path after the server address. The server has to allow this Mac.")
        case .ftp: L("macOS mounts FTP servers read-only: you can browse and copy files, not upload or change them.")
        case .https, .http: L("Enter the WebDAV address. Prefer HTTPS so the connection is encrypted; some providers need an app-specific password.")
        }
    }

    private func connect() {
        var text = address.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = protocolKind.rawValue + "://" + text }
        guard text.lowercased().hasPrefix(protocolKind.rawValue + "://") else {
            error = L("The address must use the selected protocol.")
            return
        }
        connecting = true
        error = nil
        NetworkConnector.connect(address: text) { result in
            connecting = false
            switch result {
            case .success(let mountPoint):
                let display = name.isEmpty ? (URL(string: text)?.host ?? text) : name
                NetworkLocationStore.shared.add(.init(id: UUID(), name: display, address: text, protocolKind: protocolKind))
                onMounted(mountPoint)
            case .failure(let failure):
                error = failure.message
            }
        }
    }
}

extension WorkspaceController {
    /// File › Connect to Server… (⌘K) and the sidebar's Add Network Location: a sheet on this window.
    func presentConnectToServer(protocolKind: NetworkLocationStore.ProtocolKind = .smb) {
        guard let window else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 467), styleMask: [.titled], backing: .buffered, defer: false)
        let close: () -> Void = { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        }
        sheet.contentViewController = NSHostingController(rootView: ConnectToServerSheet(protocolKind: protocolKind, cancel: close) { [weak self] mountPoint in
            close()
            self?.navigateActivePane(to: mountPoint)
        })
        window.beginSheet(sheet)
    }
}
