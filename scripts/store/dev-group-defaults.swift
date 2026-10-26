// Development aid, not shipped: reads or sets what the store app and its
// extension share, from outside the app. Must be signed with the same team and
// the application-groups entitlement (scripts/store/build-local-candidate.sh does it).
//   dev-group-defaults show | prefer-read-only true|false | disk-preference <serial hex> readOnly|readWrite|none
// disk-preference stands in for the app's Pro setting (it does the same as buying and choosing).
import Foundation

let group = "6N5T3G6H33.top.qisw.volisle.mas"
guard let shared = UserDefaults(suiteName: group) else { fatalError("no shared defaults") }
let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "prefer-read-only":
    guard let value = arguments.dropFirst().first.flatMap(Bool.init) else { fatalError("true or false") }
    shared.set(value, forKey: "PreferReadOnly")
    print("PreferReadOnly =", value)
case "disk-preference":
    let rest = Array(arguments.dropFirst())
    guard rest.count == 2, rest[0].count == 16, rest[0].allSatisfy(\.isHexDigit),
          ["readOnly", "readWrite", "none"].contains(rest[1]) else { fatalError("serial (16 hex digits) and readOnly, readWrite or none") }
    let key = "DiskPreference." + rest[0].lowercased()
    if rest[1] == "none" { shared.removeObject(forKey: key) } else { shared.set(rest[1], forKey: key) }
    print(key, "=", rest[1])
default:
    for (key, value) in (shared.persistentDomain(forName: group) ?? [:]).sorted(by: { $0.key < $1.key }) {
        print(key, "=", String(describing: value).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))
    }
}
