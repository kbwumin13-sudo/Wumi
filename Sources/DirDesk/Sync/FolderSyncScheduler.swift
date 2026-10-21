import AppKit
import DirDeskCore
import Foundation

/// Runs scheduled sync tasks while DirDesk is open. Every minute it looks for tasks whose next scheduled time has
/// passed since it last looked; a run missed while the app was closed starts once, shortly after launch.
/// A due task is analyzed and synced unless conflicts need a decision, in which case the history records that it
/// needs attention and nothing is copied until the task is run by hand (Settings › Folder Sync or the toolbar).
@MainActor
final class FolderSyncScheduler {
    static let shared = FolderSyncScheduler()
    static let checkInterval: TimeInterval = 60
    static let launchDelay: TimeInterval = 20

    private var timer: Timer?

    private init() {}

    /// Starts the minute timer. Calling it again does nothing.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { _ in
            MainActor.assumeIsolated { FolderSyncScheduler.shared.runDueTasks() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay) {
            MainActor.assumeIsolated { FolderSyncScheduler.shared.runDueTasks() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func runDueTasks(now: Date = Date()) {
        guard timer != nil else { return }
        let store = FolderSyncStore.shared
        for preset in store.presets where preset.schedule.frequency != .off {
            guard let anchor = store.scheduleAnchor(for: preset.id) else {
                // First sight of this schedule: count from now rather than running at once.
                store.setScheduleAnchor(now, for: preset.id)
                continue
            }
            guard Self.isDue(preset.schedule, since: anchor, now: now) else { continue }
            let run = store.run(for: preset.id)
            // A busy task is tried again on the next check.
            guard !run.isBusy else { continue }
            store.setScheduleAnchor(now, for: preset.id)
            run.analyze(preset, trigger: .scheduled, then: .automatic)
        }
    }

    /// Whether a scheduled time falls after `anchor` and no later than `now`.
    nonisolated static func isDue(_ schedule: FolderSyncSchedule, since anchor: Date, now: Date, calendar: Calendar = .current) -> Bool {
        guard let next = schedule.nextRunDate(after: anchor, calendar: calendar) else { return false }
        return next <= now
    }
}
