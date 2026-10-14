// Development aid, not shipped: reads or sets what the store app and its
// extension share, from outside the app. Must be signed with the same team and
// the application-groups entitlement (scripts/store/build-local-candidate.sh does it).
//   dev-group-defaults show | prefer-read-only true|false
import Foundation

let group = "6N5T3G6H33.top.qisw.volisle.mas"
guard let shared = UserDefaults(suiteName: group) else { fatalError("no shared defaults") }
let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "prefer-read-only":
    guard let value = arguments.dropFirst().first.flatMap(Bool.init) else { fatalError("true or false") }
    shared.set(value, forKey: "PreferReadOnly")
    print("PreferReadOnly =", value)
default:
    for (key, value) in (shared.persistentDomain(forName: group) ?? [:]).sorted(by: { $0.key < $1.key }) {
        print(key, "=", String(describing: value).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))
    }
}
