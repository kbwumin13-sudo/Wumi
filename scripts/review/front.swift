import AppKit
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
var n = 0
for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
    print(w[kCGWindowOwnerName as String] ?? "?", w[kCGWindowOwnerPID as String] ?? 0, w[kCGWindowNumber as String] ?? 0, (w[kCGWindowName as String] as? String) ?? "")
    n += 1; if n >= 6 { break }
}
print("frontmost app:", NSWorkspace.shared.frontmostApplication?.localizedName ?? "?", NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
