import CoreGraphics
import Foundation
// Prints the window numbers of the layer-0 on-screen windows of process <pid>, front to back.
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where w[kCGWindowOwnerPID as String] as? Int == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
    print(w[kCGWindowNumber as String] as? Int ?? 0)
}
