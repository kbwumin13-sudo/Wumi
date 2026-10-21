import Darwin
import Foundation

/// Resource usage of this process, read with proc_pid_rusage.
public struct ProcessUsage: Equatable, Sendable {
    public var cpuTimeNanoseconds: UInt64
    public var footprintBytes: UInt64
    public var wakeups: UInt64
    public var diskReadBytes: UInt64
    public var diskWrittenBytes: UInt64

    public static func current() -> ProcessUsage? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = info.ri_user_time + info.ri_system_time
        let nanoseconds = timebase.denom == 0 ? ticks : ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
        return ProcessUsage(cpuTimeNanoseconds: nanoseconds, footprintBytes: info.ri_phys_footprint,
                            wakeups: info.ri_pkg_idle_wkups + info.ri_interrupt_wkups,
                            diskReadBytes: info.ri_diskio_bytesread, diskWrittenBytes: info.ri_diskio_byteswritten)
    }
}

/// One second of a performance collection.
public struct PerformanceSample: Codable, Equatable, Sendable {
    public var offsetSeconds: Double
    public var cpuPercent: Double
    public var footprintBytes: UInt64
    public var wakeupsPerSecond: Double
    public var diskReadBytesPerSecond: Double
    public var diskWrittenBytesPerSecond: Double
    /// Delay before a block queued on the main thread ran; nil when it had not run by the next sample.
    public var mainThreadLatencyMilliseconds: Double?

    /// Sample between two usage readings taken `interval` seconds apart.
    public static func between(_ previous: ProcessUsage, _ current: ProcessUsage, interval: Double, offset: Double,
                               mainThreadLatencyMilliseconds: Double?) -> PerformanceSample {
        let seconds = max(interval, 0.001)
        func rate(_ a: UInt64, _ b: UInt64) -> Double { Double(b >= a ? b - a : 0) / seconds }
        return PerformanceSample(offsetSeconds: offset,
                                 cpuPercent: rate(previous.cpuTimeNanoseconds, current.cpuTimeNanoseconds) / 1_000_000_000 * 100,
                                 footprintBytes: current.footprintBytes,
                                 wakeupsPerSecond: rate(previous.wakeups, current.wakeups),
                                 diskReadBytesPerSecond: rate(previous.diskReadBytes, current.diskReadBytes),
                                 diskWrittenBytesPerSecond: rate(previous.diskWrittenBytes, current.diskWrittenBytes),
                                 mainThreadLatencyMilliseconds: mainThreadLatencyMilliseconds)
    }
}

/// Exported diagnostic report. It holds process metrics and system versions only — no file names,
/// contents or clipboard data.
public struct PerformanceReport: Codable, Equatable, Sendable {
    public struct Environment: Codable, Equatable, Sendable {
        public var appVersion: String
        public var appBuild: String
        public var operatingSystem: String
        public var hardwareModel: String
        public var processorCount: Int
        public var physicalMemoryBytes: UInt64

        public static func current(appVersion: String, appBuild: String) -> Environment {
            var size = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)
            var model = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname("hw.model", &model, &size, nil, 0)
            let modelName = String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return Environment(appVersion: appVersion, appBuild: appBuild,
                               operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                               hardwareModel: modelName, processorCount: ProcessInfo.processInfo.activeProcessorCount,
                               physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        }
    }

    public enum Termination: String, Codable, Sendable { case completed, stoppedEarly }

    public var schemaVersion = 1
    public var startedAt: Date
    public var requestedDurationSeconds: Double
    public var sampleIntervalSeconds: Double
    public var termination: Termination
    public var environment: Environment
    public var samples: [PerformanceSample]

    public init(startedAt: Date, requestedDurationSeconds: Double, sampleIntervalSeconds: Double, termination: Termination,
                environment: Environment, samples: [PerformanceSample]) {
        self.startedAt = startedAt
        self.requestedDurationSeconds = requestedDurationSeconds
        self.sampleIntervalSeconds = sampleIntervalSeconds
        self.termination = termination
        self.environment = environment
        self.samples = samples
    }

    public var averageCPUPercent: Double { samples.isEmpty ? 0 : samples.map(\.cpuPercent).reduce(0, +) / Double(samples.count) }
    public var peakFootprintBytes: UInt64 { samples.map(\.footprintBytes).max() ?? 0 }
    public var worstMainThreadLatencyMilliseconds: Double? { samples.compactMap(\.mainThreadLatencyMilliseconds).max() }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
