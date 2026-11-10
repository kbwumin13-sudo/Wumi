import Foundation

/// Request-local diagnostics for offline evaluation. No persistence or telemetry.
public struct SearchMetrics: Codable, Sendable {
    public internal(set) var metadataCandidates = 0
    public internal(set) var sqlSteps = 0
    public internal(set) var candidates = 0
    public internal(set) var verified = 0
    public internal(set) var distinctBodies = 0
    public internal(set) var decompressions = 0
    public internal(set) var decompressedBytes = 0
    public internal(set) var summariesBuilt = 0
    public internal(set) var firstResultMS: Double?
    public internal(set) var finalMS: Double = 0
    public internal(set) var budgetExhausted = false
    public internal(set) var resultTruncated = false
    /// Stable root/path keys, only populated when explicitly requested.
    public internal(set) var candidateOrder: [String] = []
    public init() {}
}
