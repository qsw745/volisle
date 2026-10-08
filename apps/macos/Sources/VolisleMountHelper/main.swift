import Foundation
import os
import VolisleCore

// Only launchd's fixed system service entry is supported. No CLI commands or
// environment-controlled operation mode exist in the shipping helper.
guard CommandLine.arguments.count == 1, geteuid() == 0 else { exit(78) }
// In the diagnostics' run log: whether launchd started the helper at all.
// The helper sits in <app>/Contents/Library/LaunchServices: the version is the app's.
let appURL = Bundle.main.executableURL.map { (1...4).reduce($0) { url, _ in url.deletingLastPathComponent() } }
let version = appURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String } ?? "?"
Logger(subsystem: "top.qisw.volisle.helper", category: "service").notice("后台组件已启动：版本 \(version, privacy: .public)")
HelperMaintenanceEngine.install(NTFSMaintenanceEngine())
let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperIdentity.service)
listener.setConnectionCodeSigningRequirement(HelperIdentity.requirement(for: .application))
listener.delegate = delegate
listener.activate()
withExtendedLifetime((delegate, listener)) { dispatchMain() }
