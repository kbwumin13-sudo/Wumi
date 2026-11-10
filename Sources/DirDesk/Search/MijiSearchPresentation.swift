import Foundation
import MijiCore

/// Every condition that affects the result set, plus a monotonic request generation.
struct MijiSearchSnapshot: Equatable {
    let generation: UInt64
    let query: String
    let kind: FileKind?
    let rootID: String?
    let scope: SearchScope
    let sort: SearchSort
    let onlineOnly: Bool
    let limit: Int
    let contextPath: String?
    let currentFolderOnly: Bool
}

enum MijiSearchPhase: Equatable { case idle, searching, supplementing, complete, failed }
enum MijiSearchTiming: Equatable { case firstBatch, complete }
struct MijiSearchStatus {
    let phase: MijiSearchPhase
    let count: Int
    let milliseconds: Double?
    let timing: MijiSearchTiming?
    let error: String?
    let isLimited: Bool
}
enum MijiSearchFilterID: String { case kind, root, scope, sort, onlineOnly, currentFolder }
struct MijiSearchFilter: Identifiable {
    let id: MijiSearchFilterID
    let label: String
}
struct MijiResultLocation {
    let short: String
    let fullPath: String
}
enum MijiResultAvailabilityState { case available, diskOffline, fileUnavailable, indexedOnly, partial, extractionFailed }
struct MijiResultAvailability {
    let state: MijiResultAvailabilityState
    let message: String?
    let volumeName: String
    let contentMessage: String?
}
enum MijiFileAction { case open, reveal, revealInFinder, copyFile, copyPath, quickLook, preview, openAtLine }

