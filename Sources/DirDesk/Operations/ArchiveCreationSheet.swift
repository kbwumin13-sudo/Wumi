import AppKit
import DirDeskCore
import SwiftUI

/// "Create Archive…" form: format, speed/size priority, optional ZIP password and split volumes.
struct ArchiveCreationSheet: View {
    let sources: [URL]
    let onCreate: (URL, ArchiveCreationOptions) -> Void
    let onCancel: () -> Void
    @State private var name: String
    @State private var format: ArchiveFormat = .zip
    @State private var priority: ArchiveCompressionPriority = .faster
    @State private var password = ""
    @State private var split = false
    @State private var volumeMB = 100.0
    @State private var error: String?

    init(sources: [URL], onCreate: @escaping (URL, ArchiveCreationOptions) -> Void, onCancel: @escaping () -> Void) {
        self.sources = sources
        self.onCreate = onCreate
        self.onCancel = onCancel
        // Same naming as quick compression (and Finder): "a.txt" → "a.txt.zip", several items → "Archive.zip".
        let base = sources.count == 1 ? sources[0].lastPathComponent : L("Archive.zip").replacingOccurrences(of: ".zip", with: "")
        _name = State(initialValue: base)
    }

    @State private var showsAdvanced = false

    /// Layout of the original's 560 × 371 pt sheet (runtime capture `compress-sheet`): a 91 pt header (40 pt tinted
    /// archive tile, 20 pt bold title, 13 pt note, item count), Compression, Password, a collapsed "Advanced Options"
    /// (here: name, format and split volumes), then Cancel / Create Archive.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 9) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: "archivebox.fill").font(.system(size: 18)).foregroundStyle(Color.accentColor))
                    .accessibilityLabel(L("Archive"))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Create Archive")).font(.system(size: 20, weight: .bold))
                    Text(L("Pick the balance between speed, file size and compatibility.")).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text(LF("%lld items", Int64(sources.count))).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .frame(height: 91)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(L("Compression")).font(.system(size: 13, weight: .semibold))
                Picker(L("Compression"), selection: $priority) {
                    Text(L("Faster")).tag(ArchiveCompressionPriority.faster)
                    Text(L("Smaller File")).tag(ArchiveCompressionPriority.smaller)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.top, 8)
                Text(priority == .faster ? L("Compresses quickly with light CPU use.") : L("Compresses harder and takes more time."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.top, 6)
                // The password label and field sit 5 pt further in than the other sections, as in the original.
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Password")).font(.system(size: 12, weight: .semibold)).padding(.leading, 5)
                    SecureField(L("Password (Optional)"), text: $password)
                        .textFieldStyle(.roundedBorder)
                        .disabled(format != .zip)
                        .accessibilityIdentifier("Archive.Password")
                    if format != .zip {
                        Text(L("Only ZIP archives can be password-protected.")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.top, 18)
                DisclosureGroup(isExpanded: $showsAdvanced) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("Name")).frame(width: 90, alignment: .leading)
                            TextField(L("Name"), text: $name).textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text(L("Format")).frame(width: 90, alignment: .leading)
                            Picker(L("Format"), selection: $format) {
                                Text("ZIP").tag(ArchiveFormat.zip)
                                Text("7Z").tag(ArchiveFormat.sevenZip)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                        Toggle(L("Split into volumes"), isOn: $split)
                            .accessibilityIdentifier("Archive.SplitVolumes")
                        if split {
                            HStack {
                                Text(L("Volume Size")).frame(width: 90, alignment: .leading)
                                TextField(L("Volume Size"), value: $volumeMB, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                                Text("MB")
                            }
                            Text(L("Volumes are numbered .001, .002, … so 7-Zip compatible tools can join them.")).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text(L("Advanced Options")).font(.system(size: 13))
                }
                .accessibilityIdentifier("Archive.AdvancedOptions")
                .padding(.leading, 2.5)
                .padding(.top, 18)
                if let error { Text(error).foregroundStyle(.red).font(.system(size: 11)).padding(.top, 8) }
            }
            .padding(.horizontal, 24)
            .padding(.top, 23)
            .padding(.bottom, 20)
            Divider()
            HStack {
                Button(L("Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Create Archive")) { create() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("Archive.Create")
            }
            .padding(.horizontal, 19)
            .padding(.vertical, 18)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            error = L("A file name cannot be empty or contain a slash.")
            return
        }
        if split && volumeMB < 1 {
            error = L("Volume size must be at least 1 MB.")
            return
        }
        let ext = format == .zip ? "zip" : "7z"
        let directory = sources[0].deletingLastPathComponent()
        let options = ArchiveCreationOptions(format: format, priority: priority, password: format == .zip && !password.isEmpty ? password : nil,
                                             volumeSize: split ? Int64(volumeMB * 1_000_000) : nil)
        onCreate(directory.appendingPathComponent(trimmed + "." + ext), options)
    }
}

extension WorkspaceController {
    func showArchiveCreation(_ items: [FileItem]) {
        guard let window, !items.isEmpty else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 370), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentViewController = NSHostingController(rootView: ArchiveCreationSheet(sources: items.map(\.url), onCreate: { [weak self, weak sheet] destination, options in
            if let sheet { window.endSheet(sheet) }
            self?.createArchive(items.map(\.url), destination: destination, options: options)
        }, onCancel: { [weak sheet] in
            if let sheet { window.endSheet(sheet) }
        }))
        window.beginSheet(sheet)
    }

    func createArchive(_ sources: [URL], destination: URL, options: ArchiveCreationOptions) {
        activePane.operationMessage = L("Compressing…")
        let activity = appDelegate?.operations.beginActivity(.compress, items: sources, destination: destination.deletingLastPathComponent())
        let cancel = activity?.cancel
        Task.detached(priority: .userInitiated) {
            let result = Result { try ArchiveService.create(from: sources, to: destination, options: options, isCancelled: { cancel?.isCancelled ?? false }) }
            await MainActor.run {
                if let id = activity?.id { self.appDelegate?.operations.endActivity(id) }
                switch result {
                case .failure(ArchiveError.cancelled):
                    self.activePane.operationMessage = nil
                case .success(let created):
                    self.activePane.operationMessage = L("Archive Created")
                    self.refreshPanes(showing: [destination.deletingLastPathComponent()])
                    self.activePane.select(urls: created)
                    self.registerTrashUndo(created, name: L("Compress"))
                case .failure(let error):
                    self.activePane.operationMessage = nil
                    self.presentError(Self.archiveMessage(error))
                }
                self.clearOperationMessage(after: 3)
            }
        }
    }
}
