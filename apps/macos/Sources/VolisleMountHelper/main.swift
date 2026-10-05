import Foundation
import VolisleCore

// Only launchd's fixed system service entry is supported. No CLI commands or
// environment-controlled operation mode exist in the shipping helper.
guard CommandLine.arguments.count == 1, geteuid() == 0 else { exit(78) }
HelperMaintenanceEngine.install(NTFSMaintenanceEngine())
let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperIdentity.service)
listener.setConnectionCodeSigningRequirement(HelperIdentity.requirement(for: .application))
listener.delegate = delegate
listener.activate()
withExtendedLifetime((delegate, listener)) { dispatchMain() }
