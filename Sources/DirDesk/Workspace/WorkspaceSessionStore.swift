import Foundation
import DirDeskCore

/// Window sessions as JSON files under Application Support/DirDesk/WindowSessions, one per window.
final class WorkspaceSessionStore {
    static let shared = WorkspaceSessionStore()

    let directory: URL
    private let queue = DispatchQueue(label: "com.kbwumin13.dirdesk.session-store")

    init(directory: URL? = nil) {
        let base = ApplicationSupport.directory
        self.directory = directory ?? base.appendingPathComponent("DirDesk/WindowSessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".json")
    }

    func save(_ session: WindowSession) {
        let url = url(for: session.id)
        queue.async {
            guard let data = try? PersistenceStore<WindowSession>.encoder.encode(session) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func remove(_ id: UUID) {
        let url = url(for: id)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Stored sessions, most recently modified last so the frontmost window restores last.
    func loadAll() -> [WindowSession] {
        queue.sync {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let dated = files.filter { $0.pathExtension == "json" }.map { url -> (URL, Date) in
                ((url), (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }.sorted { $0.1 < $1.1 }
            return dated.compactMap { url, _ in
                guard let data = try? Data(contentsOf: url) else { return nil }
                do {
                    return try JSONDecoder().decode(WindowSession.self, from: data)
                } catch {
                    let corrupt = url.deletingLastPathComponent().appendingPathComponent("corrupt-\(url.lastPathComponent)")
                    try? FileManager.default.moveItem(at: url, to: corrupt)
                    return nil
                }
            }
        }
    }

    func flush() {
        queue.sync {}
    }
}

/// Window frames keyed by window ID, plus the most recent frame for new windows.
enum WindowGeometryStore {
    static func frame(for id: UUID) -> NSRectValue? {
        let all = UserDefaults.standard.dictionary(forKey: DefaultsKey.windowGeometry) as? [String: [Double]] ?? [:]
        return (all[id.uuidString] ?? all["last"]).flatMap(NSRectValue.init)
    }

    static func save(_ rect: NSRectValue, for id: UUID) {
        var all = UserDefaults.standard.dictionary(forKey: DefaultsKey.windowGeometry) as? [String: [Double]] ?? [:]
        all[id.uuidString] = rect.array
        all["last"] = rect.array
        UserDefaults.standard.set(all, forKey: DefaultsKey.windowGeometry)
    }

    static func remove(_ id: UUID) {
        var all = UserDefaults.standard.dictionary(forKey: DefaultsKey.windowGeometry) as? [String: [Double]] ?? [:]
        all[id.uuidString] = nil
        UserDefaults.standard.set(all, forKey: DefaultsKey.windowGeometry)
    }
}

struct NSRectValue {
    var x, y, width, height: Double
    init?(_ array: [Double]) {
        guard array.count == 4 else { return nil }
        x = array[0]; y = array[1]; width = array[2]; height = array[3]
    }
    init(_ rect: CGRect) {
        x = rect.origin.x; y = rect.origin.y; width = rect.size.width; height = rect.size.height
    }
    var array: [Double] { [x, y, width, height] }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
