import AppKit

let application = DirDeskApplication.shared
let appDelegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = appDelegate
MainActor.assumeIsolated { DebugSnapshot.installIfRequested() }
application.run()
