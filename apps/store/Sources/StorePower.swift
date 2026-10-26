// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import IOKit.pwr_mgt
import Observation
import os

/// What happened to the disks at the last sleep, shown after waking.
struct StoreSleepReport: Equatable {
    var ejected: [String] = []
    /// Name and why it stayed mounted.
    var failed: [String: String] = [:]

    var isEmpty: Bool { ejected.isEmpty && failed.isEmpty }
}

/// Pro: keeps the Mac awake while the extension writes, and ejects its disks
/// before the Mac sleeps. Both need the app running (window or menu bar).
@MainActor @Observable final class StorePower {
    private(set) var sleepReport: StoreSleepReport?

    @ObservationIgnored private let disks: StoreDisks
    @ObservationIgnored private let settings: StoreProSettings
    @ObservationIgnored private var assertion: IOPMAssertionID?
    @ObservationIgnored private var release: DispatchWorkItem?
    @ObservationIgnored private var rootPort: io_connect_t = 0
    @ObservationIgnored private var notifyPort: IONotificationPortRef?
    @ObservationIgnored private var notifier: io_object_t = 0
    @ObservationIgnored private let log = Logger(subsystem: "top.qisw.volisle.mas", category: "power")

    /// A copy pauses between files; the assertion stays this long after the last write.
    private static let releaseDelay = 10.0
    /// The system waits about 30 s for an answer to "will sleep"; stay well inside it.
    static let sleepEjectLimit = 20.0

    init(disks: StoreDisks, settings: StoreProSettings) {
        self.disks = disks
        self.settings = settings
    }

    func start() {
        guard rootPort == 0 else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &notifyPort, { context, _, message, argument in
            guard let context else { return }
            let power = Unmanaged<StorePower>.fromOpaque(context).takeUnretainedValue()
            // The port is on the main queue (below).
            MainActor.assumeIsolated { power.received(message, token: Int(bitPattern: argument)) }
        }, &notifier)
        guard rootPort != 0, let notifyPort else {
            log.error("无法注册睡眠通知；合盖前推出不可用")
            return
        }
        IONotificationPortSetDispatchQueue(notifyPort, .main)
    }

    /// Follows the volumes after every refresh and every settings change.
    func update() {
        let writing = settings.keepsAwakeWhileWriting && disks.volumes.contains(where: \.writing)
        if writing {
            release?.cancel()
            release = nil
            guard assertion == nil else { return }
            var id: IOPMAssertionID = 0
            let rc = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Volisle is writing to an NTFS disk" as CFString, &id)
            if rc == kIOReturnSuccess { assertion = id } else { log.error("防睡眠断言创建失败：\(rc, privacy: .public)") }
        } else if assertion != nil && release == nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.release = nil
                    if let id = self.assertion { IOPMAssertionRelease(id) }
                    self.assertion = nil
                    // Writing again in the meantime: take a new one.
                    self.update()
                }
            }
            release = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (settings.keepsAwakeWhileWriting ? Self.releaseDelay : 0), execute: work)
        }
    }

    func dismissSleepReport() { sleepReport = nil }

    private func received(_ message: UInt32, token: Int) {
        switch message {
        case PowerMessage.canSystemSleep:
            // Idle sleep is the assertion's business; never veto here.
            IOAllowPowerChange(rootPort, token)
        case PowerMessage.systemWillSleep:
            willSleep(token: token)
        default:
            break
        }
    }

    private func willSleep(token: Int) {
        let names = disks.volumes.filter(\.isOurs).map(\.name)
        guard settings.ejectsDisksBeforeSleep, !names.isEmpty else {
            IOAllowPowerChange(rootPort, token)
            return
        }
        log.notice("即将睡眠：推出盘屿挂载的磁盘")
        var answered = false
        var report = StoreSleepReport()
        var finished: Set<String> = []
        let allow = { [weak self] in
            guard let self, !answered else { return }
            answered = true
            IOAllowPowerChange(self.rootPort, token)
        }
        let limit = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                // Still busy: let the Mac sleep rather than block it, and say which disks were not done.
                for name in names where !finished.contains(name) {
                    report.failed[name] = String(localized: "推出没有在睡眠前完成")
                }
                self?.sleepReport = report
                self?.log.error("睡眠前推出超时，放行睡眠")
                allow()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sleepEjectLimit, execute: limit)
        disks.ejectAll(each: { name, failure in
            // Late results (after the time limit) still correct the report.
            finished.insert(name)
            if let failure { report.failed[name] = failure } else { report.ejected.append(name); report.failed[name] = nil }
            self.sleepReport = report
        }, done: { [weak self] in
            self?.log.notice("睡眠前推出完成：成功 \(report.ejected.count, privacy: .public) 个，失败 \(report.failed.count, privacy: .public) 个")
            limit.cancel()
            allow()
        })
    }
}

/// iokit_common_msg(x) from IOMessage.h, which Swift does not import.
enum PowerMessage {
    static func common(_ code: UInt32) -> UInt32 { 0xE000_0000 | code }
    static let canSystemSleep = common(0x270), systemWillSleep = common(0x280)
}
