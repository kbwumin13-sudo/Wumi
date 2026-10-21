import AppKit
import DirDeskCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Diagnostics: the session error log and a 60-second performance collection.
struct DiagnosticsSettings: View {
    var body: some View {
        // 23 pt between the two cards, as in the original.
        VStack(spacing: 20) {
            ErrorLogCard()
            PerformanceCard()
        }
    }
}

private enum ErrorLogRange: String, CaseIterable, Identifiable {
    case session, lastHour, today
    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: L("This Session")
        case .lastHour: L("Last Hour")
        case .today: L("Today")
        }
    }

    var since: Date? {
        switch self {
        case .session: nil
        case .lastHour: Date().addingTimeInterval(-3600)
        case .today: Calendar.current.startOfDay(for: Date())
        }
    }
}

private struct ErrorLogCard: View {
    @State private var range: ErrorLogRange = .session
    @State private var entries: [ApplicationErrorLog.Entry] = []
    @State private var overwritten = false
    @State private var status: String?
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        // Laid out like the original's card: a 12 pt note, the range picker with its label right-aligned in a
        // column, Refresh and Export, and a centered empty state.
        SettingsCard(L("Recent Error Logs")) {
            Text(L("Holds up to 512 errors from this session in memory only; quitting Wumi discards them. Names and paths are masked before an error is logged."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 7.5)
                .padding(.top, 14)
            HStack(spacing: 9.5) {
                Text(L("Time Range")).font(.system(size: 13)).frame(width: 94.5, alignment: .trailing)
                Picker(L("Time Range"), selection: $range) {
                    ForEach(ErrorLogRange.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button(L("Refresh"), action: reload)
                Button(L("Export Error Logs…")) { export() }.disabled(entries.isEmpty)
            }
            .padding(.leading, 9.5)
            .padding(.trailing, 7.5)
            .padding(.top, 4.5)
            if entries.isEmpty {
                Text(L("No errors recorded in this time range.")).foregroundStyle(.secondary).font(.system(size: 13))
                    .frame(maxWidth: .infinity, minHeight: 96)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(formatter.string(from: entry.date)).monospacedDigit()
                                    Text(Self.sourceTitle(entry.source)).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(LF("Error reference: %@", entry.reference)).foregroundStyle(.tertiary).textSelection(.enabled)
                                }
                                .font(.system(size: 10))
                                Text(entry.summary).font(.system(size: 12)).textSelection(.enabled)
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 260)
            }
            if overwritten {
                Text(L("Older entries were dropped after the log reached 512 errors.")).font(.system(size: 10)).foregroundStyle(.orange)
            }
            if let status { Text(status).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .onAppear(perform: reload)
        .onChange(of: range) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: ApplicationErrorLog.didChangeNotification).receive(on: RunLoop.main)) { _ in reload() }
    }

    private func reload() {
        entries = ApplicationErrorLog.shared.entries(since: range.since)
        overwritten = ApplicationErrorLog.shared.overwritten
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Wumi-Error-Logs.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let info = Bundle.main.infoDictionary
        let report = ApplicationErrorLog.shared.report(since: range.since, appVersion: info?["CFBundleShortVersionString"] as? String ?? "",
                                                       appBuild: info?["CFBundleVersion"] as? String ?? "")
        do {
            try ApplicationErrorLog.encode(report).write(to: url, options: .atomic)
            status = L("Error logs saved.")
        } catch {
            status = L("The error logs could not be saved.")
            ApplicationErrorLog.shared.record(error, source: .diagnostics)
        }
    }

    static func sourceTitle(_ source: ApplicationErrorLog.Source) -> String {
        switch source {
        case .fileOperation: L("File Operation")
        case .directory: L("Folder Loading")
        case .search: L("Search")
        case .fileTransit: L("File Transit")
        case .settings: L("Settings")
        case .diagnostics: L("Diagnostics")
        }
    }
}

private struct PerformanceCard: View {
    @ObservedObject var collector = PerformanceCollector.shared
    @State private var status: String?

    var body: some View {
        SettingsCard(L("Collect Performance Diagnostics")) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("Collection runs for 60 seconds: reproduce the slowdown or high CPU use meanwhile. You can close Settings while it runs."))
                    .font(.system(size: 13, weight: .semibold))
                Text(L("The report covers CPU, memory, wakeups, disk activity and main-thread responsiveness. It holds no file names, file contents or clipboard data and is saved only where you choose."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 7.5)
            .padding(.top, 14.5)
            switch collector.phase {
            case .idle:
                Button(L("Start Collection")) { collector.start() }
            case .collecting:
                HStack {
                    ProgressView(value: collector.elapsed, total: PerformanceCollector.duration).frame(maxWidth: 260)
                    Text(L("Collecting Diagnostics")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Stop and Keep Report")) { collector.stop() }
                }
            case .ready:
                if let report = collector.report {
                    Text(L("Diagnostics Ready")).font(.system(size: 12, weight: .semibold))
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            Text(L("Average CPU")).foregroundStyle(.secondary)
                            Text(String(format: "%.1f%%", report.averageCPUPercent))
                        }
                        GridRow {
                            Text(L("Peak Memory")).foregroundStyle(.secondary)
                            Text(FileSizeFormatter.string(Int64(report.peakFootprintBytes)))
                        }
                        GridRow {
                            Text(L("Slowest Main-Thread Response")).foregroundStyle(.secondary)
                            Text(report.worstMainThreadLatencyMilliseconds.map { String(format: "%.0f ms", $0) } ?? "--")
                        }
                    }
                    .font(.system(size: 12))
                    HStack {
                        Button(L("Export Diagnostic Report")) { export(report) }
                        Button(L("Start Collection")) { collector.start() }
                    }
                }
            }
            if let status { Text(status).font(.system(size: 10)).foregroundStyle(.secondary) }
            Text(L("Diagnostics point to where time goes; they are not a diagnosis on their own."))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func export(_ report: PerformanceReport) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Wumi-Diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.encoded().write(to: url, options: .atomic)
            status = L("Diagnostic Report Saved")
        } catch {
            status = L("The diagnostic report could not be saved.")
            ApplicationErrorLog.shared.record(error, source: .diagnostics)
        }
    }
}

/// Samples this process once a second on a background queue and probes main-thread latency.
@MainActor
final class PerformanceCollector: ObservableObject {
    enum Phase { case idle, collecting, ready }

    static let shared = PerformanceCollector()
    static let duration: Double = 60
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var report: PerformanceReport?
    private var sampler: Sampler?

    func start() {
        sampler?.cancel()
        report = nil
        elapsed = 0
        phase = .collecting
        let sampler = Sampler(duration: Self.duration) { [weak self] elapsed in
            Task { @MainActor in self?.elapsed = elapsed }
        } finished: { [weak self] samples, startedAt, stoppedEarly in
            Task { @MainActor in self?.finish(samples, startedAt: startedAt, stoppedEarly: stoppedEarly) }
        }
        self.sampler = sampler
        sampler.start()
    }

    func stop() { sampler?.stop() }

    private func finish(_ samples: [PerformanceSample], startedAt: Date, stoppedEarly: Bool) {
        let info = Bundle.main.infoDictionary
        report = PerformanceReport(startedAt: startedAt, requestedDurationSeconds: Self.duration, sampleIntervalSeconds: 1,
                                   termination: stoppedEarly ? .stoppedEarly : .completed,
                                   environment: .current(appVersion: info?["CFBundleShortVersionString"] as? String ?? "",
                                                         appBuild: info?["CFBundleVersion"] as? String ?? ""),
                                   samples: samples)
        phase = .ready
        sampler = nil
    }

    private final class Sampler: @unchecked Sendable {
        private let queue = DispatchQueue(label: "app.dirdesk.performance-diagnostics", qos: .utility)
        private let duration: Double
        private let progress: @Sendable (Double) -> Void
        private let finished: @Sendable ([PerformanceSample], Date, Bool) -> Void
        private var timer: DispatchSourceTimer?
        private var samples: [PerformanceSample] = []
        private var previous: ProcessUsage?
        private let startedAt = Date()
        private let startUptime = DispatchTime.now().uptimeNanoseconds
        private let lock = NSLock()
        private var probeSent: UInt64?
        private var probeLatency: Double?
        private var done = false

        init(duration: Double, progress: @escaping @Sendable (Double) -> Void,
             finished: @escaping @Sendable ([PerformanceSample], Date, Bool) -> Void) {
            self.duration = duration
            self.progress = progress
            self.finished = finished
        }

        func start() {
            previous = ProcessUsage.current()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            sendProbe()
            timer.resume()
        }

        func stop() { queue.async { [weak self] in self?.complete(stoppedEarly: true) } }

        func cancel() {
            queue.async { [weak self] in
                self?.done = true
                self?.timer?.cancel()
            }
        }

        private func sendProbe() {
            let sent = DispatchTime.now().uptimeNanoseconds
            lock.withLock { probeSent = sent }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let latency = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
                self.lock.withLock {
                    if self.probeSent == sent {
                        self.probeLatency = latency
                        self.probeSent = nil
                    }
                }
            }
        }

        private func tick() {
            guard !done, let current = ProcessUsage.current() else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let offset = Double(now - startUptime) / 1_000_000_000
            // A probe still waiting means the main thread has been busy at least that long.
            let latency: Double? = lock.withLock {
                if let sent = probeSent { return Double(now - sent) / 1_000_000 }
                defer { probeLatency = nil }
                return probeLatency
            }
            if let previous {
                samples.append(.between(previous, current, interval: 1, offset: offset, mainThreadLatencyMilliseconds: latency))
            }
            previous = current
            progress(min(offset, duration))
            if offset >= duration {
                complete(stoppedEarly: false)
            } else if lock.withLock({ probeSent == nil }) {
                sendProbe()
            }
        }

        private func complete(stoppedEarly: Bool) {
            guard !done else { return }
            done = true
            timer?.cancel()
            finished(samples, startedAt, stoppedEarly)
        }
    }
}
