// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Observation
import ServiceManagement

extension StoreDiskPreference: Codable {}

/// What the owner chose for one disk (Pro), kept under its NTFS serial.
struct StoreDiskChoice: Codable, Equatable {
    /// nil: the general "默认只读" setting applies.
    var preference: StoreDiskPreference?
    /// Select the volume in Finder when it is mounted.
    var revealsOnConnect = false
    /// The label when last seen, for the list in Settings.
    var name: String

    var isEmpty: Bool { preference == nil && !revealsOnConnect }

    init(preference: StoreDiskPreference? = nil, revealsOnConnect: Bool = false, name: String) {
        self.preference = preference
        self.revealsOnConnect = revealsOnConnect
        self.name = name
    }

    /// A way of mounting this build does not know (written by a newer one)
    /// counts as none: only that field is lost, not every disk's settings.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preference = try? values.decodeIfPresent(StoreDiskPreference.self, forKey: .preference)
        revealsOnConnect = try values.decodeIfPresent(Bool.self, forKey: .revealsOnConnect) ?? false
        name = try values.decode(String.self, forKey: .name)
    }
}

/// What the shared group holds for the extension follows from the purchase:
/// the disks' own choices while it holds, nothing otherwise. The choices
/// themselves stay in the app, so buying again or restoring brings them back.
enum StoreProSync {
    static func sharedDiskPreferences(unlocked: Bool, choices: [String: StoreDiskChoice]) -> [String: String] {
        guard unlocked else { return [:] }
        return choices.reduce(into: [:]) { result, item in
            if let preference = item.value.preference {
                result[StoreMountStatus.diskPreferencePrefix + item.key] = preference.rawValue
            }
        }
    }
}

/// The Pro settings. Each feature is on only while the purchase holds
/// (`unlocked`); the owner's switches are kept either way.
@MainActor @Observable final class StoreProSettings {
    private(set) var unlocked = false
    private(set) var choices: [String: StoreDiskChoice] {
        didSet {
            if let data = try? JSONEncoder().encode(choices) { defaults.set(data, forKey: Keys.choices) }
            syncShared()
        }
    }
    var showsMenuBar: Bool { didSet { defaults.set(showsMenuBar, forKey: Keys.menuBar); onChange?() } }
    var preventsSleepWhileWriting: Bool { didSet { defaults.set(preventsSleepWhileWriting, forKey: Keys.preventsSleep); onChange?() } }
    var ejectsBeforeSleep: Bool { didSet { defaults.set(ejectsBeforeSleep, forKey: Keys.ejectsBeforeSleep); onChange?() } }
    /// Any switch or the purchase changed (the power and menu bar features follow).
    @ObservationIgnored var onChange: (() -> Void)?
    private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var loginProblem: String?

    var menuBarShown: Bool { unlocked && showsMenuBar }
    var keepsAwakeWhileWriting: Bool { unlocked && preventsSleepWhileWriting }
    var ejectsDisksBeforeSleep: Bool { unlocked && ejectsBeforeSleep }

    private enum Keys {
        static let choices = "ProDiskChoices", menuBar = "ProShowsMenuBar"
        static let preventsSleep = "ProPreventsSleepWhileWriting", ejectsBeforeSleep = "ProEjectsBeforeSleep"
    }
    private let defaults = UserDefaults.standard
    private let shared = UserDefaults(suiteName: StoreMountStatus.group)

    init() {
        choices = defaults.data(forKey: Keys.choices).flatMap { try? JSONDecoder().decode([String: StoreDiskChoice].self, from: $0) } ?? [:]
        showsMenuBar = defaults.bool(forKey: Keys.menuBar)
        // On once bought, unless the owner turned them off.
        preventsSleepWhileWriting = defaults.object(forKey: Keys.preventsSleep) as? Bool ?? true
        ejectsBeforeSleep = defaults.object(forKey: Keys.ejectsBeforeSleep) as? Bool ?? true
    }

    /// `revoked`: the purchase was refunded or revoked. Only then is the login
    /// item removed: a purchase merely not found this time must not undo it.
    func apply(unlocked: Bool, revoked: Bool = false) {
        self.unlocked = unlocked
        syncShared()
        if revoked && opensAtLogin { setOpensAtLogin(false) }
        onChange?()
    }

    func choice(serial: String) -> StoreDiskChoice? { choices[serial] }

    func setPreference(_ preference: StoreDiskPreference?, serial: String, name: String) {
        update(serial: serial, name: name) { $0.preference = preference }
    }

    func setRevealsOnConnect(_ reveals: Bool, serial: String, name: String) {
        update(serial: serial, name: name) { $0.revealsOnConnect = reveals }
    }

    func forget(serial: String) { choices[serial] = nil }

    func setOpensAtLogin(_ on: Bool) {
        loginProblem = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginProblem = String(localized: "没有改成功：\(error.localizedDescription)")
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func update(serial: String, name: String, _ change: (inout StoreDiskChoice) -> Void) {
        var choice = choices[serial] ?? StoreDiskChoice(name: name)
        choice.name = name
        change(&choice)
        // A disk left with nothing of its own leaves the list.
        choices[serial] = choice.isEmpty ? nil : choice
    }

    /// Makes the group's DiskPreference keys exactly what StoreProSync says.
    private func syncShared() {
        guard let shared else { return }
        let wanted = StoreProSync.sharedDiskPreferences(unlocked: unlocked, choices: choices)
        let present = (shared.dictionaryRepresentation().keys).filter { $0.hasPrefix(StoreMountStatus.diskPreferencePrefix) }
        for key in present where wanted[key] == nil { shared.removeObject(forKey: key) }
        for (key, value) in wanted where shared.string(forKey: key) != value { shared.set(value, forKey: key) }
    }
}
