import DirDeskCore
import Foundation

/// A short-lived resource observer for visible pending transfers. It never enumerates directories or reads data.
@MainActor
final class CloudStatusObservation {
    private let urls: () -> [URL]
    private let receive: ([String: FileCloudStatus]) -> Void
    private var task: Task<Void, Never>?
    private var generation = 0

    init(urls: @escaping () -> [URL], receive: @escaping ([String: FileCloudStatus]) -> Void) {
        self.urls = urls
        self.receive = receive
    }

    deinit { task?.cancel() }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
    }

    func refresh() {
        guard !urls().isEmpty else { stop(); return }
        guard task == nil else { return }
        let revision = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let candidates = self?.urls(), !candidates.isEmpty else {
                    self?.stop()
                    return
                }
                let read = Task.detached(priority: .utility) {
                    DirectoryLoader.cloudStatuses(for: candidates, isCancelled: { Task.isCancelled })
                }
                let statuses = await withTaskCancellationHandler(operation: { await read.value }, onCancel: { read.cancel() })
                guard !Task.isCancelled, let self, revision == self.generation else { return }
                self.receive(statuses)
            }
        }
    }
}
