// SPDX-License-Identifier: GPL-2.0-only
// Store Pro step 0: what a sandboxed app may do about power and login items.
// Not part of the app. Build and sign with scripts/store/probes/build-power-probe.sh.
// Every result goes to the unified log, subsystem top.qisw.volisle.probe.
// Arguments (through `open -n … --args`): assert <seconds> | sleepwatch <hold seconds> | clamshell | login-register | login-status | login-unregister
import AppKit
import IOKit.pwr_mgt
import ServiceManagement
import os

let log = Logger(subsystem: "top.qisw.volisle.probe", category: "power")
nonisolated(unsafe) var rootPort: io_connect_t = 0
nonisolated(unsafe) var holdSeconds = 0.0

/// iokit_common_msg(x) from IOMessage.h, which Swift does not import.
enum PowerMessage {
    static func common(_ code: UInt32) -> UInt32 { 0xE000_0000 | code }
    static let canSystemSleep = common(0x270), systemWillSleep = common(0x280)
    static let systemWillPowerOn = common(0x320), systemHasPoweredOn = common(0x300)
}

func stamp() -> String { ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds]) }

func assertFor(_ seconds: Double) {
    var id: IOPMAssertionID = 0
    let rc = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                         IOPMAssertionLevel(kIOPMAssertionLevelOn), "Volisle probe: writing" as CFString, &id)
    log.notice("assert rc=\(rc, privacy: .public) id=\(id, privacy: .public) at \(stamp(), privacy: .public)")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        let released = IOPMAssertionRelease(id)
        log.notice("assert released rc=\(released, privacy: .public) at \(stamp(), privacy: .public)")
        exit(0)
    }
}

func watchSleep() {
    var notifier: io_object_t = 0
    var port: IONotificationPortRef?
    rootPort = IORegisterForSystemPower(nil, &port, { _, _, type, argument in
        let token = Int(bitPattern: argument)
        switch type {
        case PowerMessage.canSystemSleep:
            log.notice("can-sleep at \(stamp(), privacy: .public)")
            IOAllowPowerChange(rootPort, token)
        case PowerMessage.systemWillSleep:
            log.notice("will-sleep at \(stamp(), privacy: .public); holding \(holdSeconds, privacy: .public) s")
            DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds) {
                let rc = IOAllowPowerChange(rootPort, token)
                log.notice("allow-sleep rc=\(rc, privacy: .public) at \(stamp(), privacy: .public)")
            }
        case PowerMessage.systemWillPowerOn:
            log.notice("will-power-on at \(stamp(), privacy: .public)")
        case PowerMessage.systemHasPoweredOn:
            log.notice("has-powered-on at \(stamp(), privacy: .public)")
        default:
            log.notice("power message 0x\(String(type, radix: 16), privacy: .public) at \(stamp(), privacy: .public)")
        }
    }, &notifier)
    log.notice("IORegisterForSystemPower port=\(rootPort, privacy: .public) notifier=\(notifier, privacy: .public)")
    guard rootPort != 0, let port else { exit(1) }
    IONotificationPortSetDispatchQueue(port, .main)
    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
        log.notice("NSWorkspace will-sleep at \(stamp(), privacy: .public)")
    }
    center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
        log.notice("NSWorkspace did-wake at \(stamp(), privacy: .public)")
    }
}

/// Every general-interest message of the root domain (lid, sleep, wake) with the lid state,
/// to see whether closing the lid announces itself before "will sleep".
nonisolated(unsafe) var rootService: io_service_t = 0
nonisolated(unsafe) var interest: io_object_t = 0

func clamshellState() -> String {
    guard let value = IORegistryEntryCreateCFProperty(rootService, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() else { return "unknown" }
    return "\(value)"
}

func watchClamshell() {
    rootService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard rootService != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
        log.error("root domain unavailable"); exit(1)
    }
    IONotificationPortSetDispatchQueue(port, .main)
    let rc = IOServiceAddInterestNotification(port, rootService, kIOGeneralInterest, { _, _, type, _ in
        log.notice("root interest 0x\(String(type, radix: 16), privacy: .public) clamshell=\(clamshellState(), privacy: .public) at \(stamp(), privacy: .public)")
    }, nil, &interest)
    log.notice("interest rc=\(rc, privacy: .public) clamshell=\(clamshellState(), privacy: .public)")
    holdSeconds = 2
    watchSleep()
}

func login(_ action: String) {
    let service = SMAppService.mainApp
    do {
        switch action {
        case "login-register": try service.register()
        case "login-unregister": try service.unregister()
        default: break
        }
        log.notice("\(action, privacy: .public) ok, status=\(service.status.rawValue, privacy: .public)")
    } catch {
        log.error("\(action, privacy: .public) failed: \(error.localizedDescription, privacy: .public), status=\(service.status.rawValue, privacy: .public)")
    }
    exit(0)
}

@main struct PowerProbe {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        log.notice("probe start sandboxed=\(sandboxed, privacy: .public) args=\(arguments.joined(separator: " "), privacy: .public)")
        switch arguments.first {
        case "assert": assertFor(Double(arguments.dropFirst().first ?? "") ?? 30)
        case "sleepwatch": holdSeconds = Double(arguments.dropFirst().first ?? "") ?? 15; watchSleep()
        case "clamshell": watchClamshell()
        case let action? where action.hasPrefix("login-"): login(action)
        default: log.error("unknown arguments"); exit(2)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }
}
