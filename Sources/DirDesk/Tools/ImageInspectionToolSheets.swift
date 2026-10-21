import AppKit
import DirDeskCore
import SwiftUI

// MARK: - View Photo Location

@MainActor
final class PhotoLocationToolModel: ObservableObject {
    enum Phase {
        case loading
        case found(PhotoLocationMetadata)
        case absent
        case failed(String)
    }

    let source: URL
    @Published private(set) var phase: Phase = .loading
    @Published var copied = false
    private var loaded = false

    init(source: URL) {
        self.source = source
    }

    var location: PhotoLocationMetadata? {
        if case .found(let location) = phase { return location }
        return nil
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        let source = self.source
        switch await ToolWork.run({ try ImageTransformationService().photoLocation(source: source) }) {
        case .success(let location):
            phase = location.map(Phase.found) ?? .absent
        case .failure(let message):
            phase = .failed(message)
        }
    }

    func copyCoordinates() {
        guard let location else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(location.coordinateText, forType: .string)
        copied = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.copied = false
        }
    }

    func openInMaps() {
        guard let location else { return }
        NSWorkspace.shared.open(location.mapsURL)
    }
}

/// Read-only: the stored GPS values in a two-column list, with Copy Coordinates and Open in Maps (the default button).
struct PhotoLocationToolSheet: View {
    @ObservedObject var model: PhotoLocationToolModel
    let onDone: () -> Void

    var body: some View {
        ToolSheetScaffold(tool: .imageViewLocation, subtitle: model.source.lastPathComponent, primaryTitle: L("Open in Maps"),
                          canRun: model.location != nil, secondaryTitle: model.copied ? L("Copied") : L("Copy Coordinates"),
                          canRunSecondary: model.location != nil, onSecondary: { model.copyCoordinates() },
                          onCancel: onDone, onRun: { model.openInMaps() }) {
            details
        }
        .task { await model.load() }
    }

    @ViewBuilder private var details: some View {
        switch model.phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Reading location metadata…")).foregroundStyle(.secondary)
            }
        case .absent:
            Text(L("The image does not contain readable location metadata.")).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .found(let location):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 0, verticalSpacing: 10) {
                row(L("Latitude"), Self.decimal(location.latitude))
                row(L("Longitude"), Self.decimal(location.longitude))
                if let altitude = location.altitude {
                    row(L("Altitude"), LF("%.1f m", altitude))
                }
                if let timestamp = location.timestamp {
                    row(L("GPS Time"), Self.gpsTimeText(timestamp))
                }
                if let error = location.horizontalPositioningError {
                    row(L("Accuracy"), LF("± %.0f m", error))
                }
                if let direction = location.imageDirection {
                    row(L("Image Direction"), ToolText.degrees(direction))
                }
                if let speed = location.speed {
                    row(L("Speed"), LF("%.1f km/h", speed))
                }
            }
            .accessibilityIdentifier("BuiltInTool.Location.Values")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
    }

    /// "30.658600": signed decimal degrees, six places, as stored.
    static func decimal(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// "2026:10:01 08:30:00": the GPS date and time stamps in their EXIF form (UTC).
    static func gpsTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Remove Background

/// Generates the transparent PNG into a private folder for preview; the primary button moves it next to the original.
@MainActor
final class RemoveBackgroundToolModel: ObservableObject {
    enum Phase {
        case working
        case ready(output: URL, preview: ToolBitmap?)
        case failed(String)
    }

    let source: URL
    @Published private(set) var phase: Phase = .working
    @Published private(set) var original: ToolBitmap?
    private var staging: URL?
    private var started = false
    private var discarded = false

    init(source: URL) {
        self.source = source
    }

    func start() async {
        guard !started else { return }
        started = true
        let source = self.source
        if case .success(let bitmap) = await ToolWork.run({ ToolImageLoader.thumbnail(of: source, maximumPixelSize: 900).map(ToolBitmap.init) }) {
            original = bitmap
        }
        let outcome = await ToolWork.run { () -> (staging: URL, output: URL, preview: ToolBitmap?) in
            let staging = try ToolFilePublisher.makeStagingDirectory(near: source.deletingLastPathComponent())
            do {
                let result = try ImageTransformationService().removeBackground(source: source, outputDirectory: staging)
                return (staging, result.output, ToolImageLoader.thumbnail(of: result.output, maximumPixelSize: 900).map(ToolBitmap.init))
            } catch {
                ToolFilePublisher.removeQuietly(staging)
                throw error
            }
        }
        switch outcome {
        case .success(let result):
            if discarded {
                ToolFilePublisher.removeQuietly(result.staging)
                return
            }
            staging = result.staging
            phase = .ready(output: result.output, preview: result.preview)
        case .failure(let message):
            phase = .failed(message)
        }
    }

    /// Deletes the private preview files.
    func discard() {
        discarded = true
        ToolFilePublisher.removeQuietly(staging)
        staging = nil
    }

    /// Moves the generated PNG next to the original (keep-both on conflicts).
    func saveJob() -> ToolJob? {
        guard case .ready(let output, _) = phase else { return nil }
        let destination = source.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent)
        return ToolJob(name: output.lastPathComponent) { _ in
            guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
                throw ImageTransformationError.destinationNotWritable(destination.deletingLastPathComponent().path)
            }
            return ToolJobOutput(outputs: [try ToolFilePublisher.publish(output, as: destination)])
        }
    }
}

/// Reference layout: "Original" and "Transparent result preview" side by side, a one-line note, Create Transparent PNG.
struct RemoveBackgroundToolSheet: View {
    @ObservedObject var model: RemoveBackgroundToolModel
    let onCancel: () -> Void
    let onSave: () -> Void

    private var isReady: Bool {
        if case .ready = model.phase { return true }
        return false
    }

    private var problem: String? {
        if case .failed(let message) = model.phase { return message }
        return nil
    }

    var body: some View {
        ToolSheetScaffold(tool: .imageRemoveBackground, subtitle: model.source.lastPathComponent, problem: problem,
                          primaryTitle: L("Create Transparent PNG"), canRun: isReady, onCancel: onCancel, onRun: onSave) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        ToolSectionTitle(L("Original"))
                        ToolPreviewBox(.native) {
                            ToolImagePreview(image: model.original?.cgImage, isLoading: model.original == nil)
                        }
                        .frame(maxWidth: ToolSheetMetrics.previewWidth, minHeight: 290, maxHeight: 290)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ToolSectionTitle(L("Transparent result preview"))
                        ToolPreviewBox(.result) { resultPreview }
                            .frame(maxWidth: ToolSheetMetrics.previewWidth, minHeight: 290, maxHeight: 290)
                    }
                }
                Label(L("Subject detection runs on this Mac and saves a PNG copy with a transparent background."),
                      systemImage: BuiltInToolSupport.symbol(.imageRemoveBackground))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .task { await model.start() }
    }

    @ViewBuilder private var resultPreview: some View {
        switch model.phase {
        case .working:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Generating preview…")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(_, let preview):
            ToolImagePreview(image: preview?.cgImage, accessibilityLabel: L("Transparent result preview"))
        case .failed(let message):
            ToolImagePreview(image: nil, message: message)
        }
    }
}
