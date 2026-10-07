import Foundation

/// How the last disk operations ended, for diagnostics: a time and enum values
/// only (no disk, no path), newest first, kept across launches.
public enum OperationHistory {
    public struct Entry: Codable, Sendable, Equatable {
        public let time: Date
        public let purpose: String
        public let phase: String
        public let failure: String?
        public let recoveryFailure: String?
        /// Only to record each operation once; never exported.
        let id: UUID
        public init(_ operation: HelperMountOperation, at time: Date = Date()) {
            self.time = time
            purpose = operation.isWrite ? "readWrite" : "check"
            phase = operation.phase.rawValue
            failure = operation.failure?.rawValue
            recoveryFailure = operation.recoveryFailure?.rawValue
            id = operation.id
        }
    }
    public static let limit = 20
    static let key = "VolisleOperationHistory"

    public static func record(_ operation: HelperMountOperation, in defaults: UserDefaults = .standard, at time: Date = Date()) {
        var list = entries(in: defaults)
        guard !list.contains(where: { $0.id == operation.id }) else { return }
        list.insert(Entry(operation, at: time), at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(limit))) { defaults.set(data, forKey: key) }
    }

    public static func entries(in defaults: UserDefaults = .standard) -> [Entry] {
        guard let data = defaults.data(forKey: key), let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return Array(list.prefix(limit))
    }
}
