import AppKit
import Combine
import DirDeskCore

/// Transparent windows on a screen edge that open Floating Files on hover (after the hover delay)
/// or immediately when files are dragged into them.
@MainActor
final class HotZoneController {
    static let shared = HotZoneController()
    private var windows: [HotZoneWindow] = []
    private var cancellables: Set<AnyCancellable> = []
    private var observer: NSObjectProtocol?

    func install() {
        rebuild()
        AppModel.shared.$configuration.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuild() }
        }.store(in: &cancellables)
        FileFloatingStore.shared.$configuration.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuild() }
        }.store(in: &cancellables)
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        let preferences = AppModel.shared.preferences
        guard preferences.enablesFileTransitIsland else { return }
        let edge = preferences.fileTransitDockEdge
        let floating = FileFloatingStore.shared.configuration
        for screen in NSScreen.screens {
            let zone = floating.hotZone(for: screen, edge: edge)
            guard zone.enabled else { continue }
            let frame = Self.frame(for: screen, edge: edge, zone: zone, automatic: preferences.fileTransitDockUsesAutomaticPlacement && !zone.custom)
            let window = HotZoneWindow(frame: frame, hoverDelay: floating.hoverDelay, hoverEnabled: zone.hoverEnabled)
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    /// "Preview Hot Zone": briefly outlines every active trigger zone.
    func previewZones() {
        for window in windows {
            let marker = NSWindow(contentRect: window.frame.insetBy(dx: 0, dy: -2), styleMask: .borderless, backing: .buffered, defer: false)
            marker.isOpaque = false
            marker.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.55)
            marker.level = .statusBar
            marker.ignoresMouseEvents = true
            marker.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { marker.orderOut(nil) }
        }
    }

    /// Zone rectangle in screen coordinates. Automatic top placement uses the notch when present.
    static func frame(for screen: NSScreen, edge: FileTransitDockEdge, zone: FileFloatingConfiguration.HotZone, automatic: Bool) -> NSRect {
        let full = screen.frame
        let depth = max(zone.depth, 2)
        switch edge {
        case .top:
            if automatic, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, right.minX > left.maxX {
                // The original covers the whole notch (about 179 × 32 pt on a MacBook Air), not a thin strip.
                let height = max(screen.safeAreaInsets.top, depth)
                return NSRect(x: left.maxX, y: full.maxY - height, width: right.minX - left.maxX, height: height)
            }
            let length = automatic ? 240 : zone.length
            let center = full.minX + full.width * zone.center
            return NSRect(x: center - length / 2, y: full.maxY - depth, width: length, height: depth)
        case .left:
            let length = automatic ? 240 : zone.length
            let center = full.minY + full.height * zone.center
            return NSRect(x: full.minX, y: center - length / 2, width: depth, height: length)
        case .right:
            let length = automatic ? 240 : zone.length
            let center = full.minY + full.height * zone.center
            return NSRect(x: full.maxX - depth, y: center - length / 2, width: depth, height: length)
        }
    }
}

final class HotZoneWindow: NSPanel {
    init(frame: NSRect, hoverDelay: Double, hoverEnabled: Bool) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = HotZoneView(frame: NSRect(origin: .zero, size: frame.size))
        view.hoverDelay = hoverDelay
        view.hoverEnabled = hoverEnabled
        contentView = view
    }

    override var canBecomeKey: Bool { false }
}

final class HotZoneView: NSView {
    var hoverDelay: Double = 0.15
    var hoverEnabled = true
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard hoverEnabled else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: hoverDelay, repeats: false) { _ in
            MainActor.assumeIsolated { FloatingFilesController.shared.show() }
        }
    }

    override func mouseExited(with event: NSEvent) {
        timer?.invalidate()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { FloatingFilesController.shared.show() }
        return .copy
    }
}
