import Foundation
import Security
import ServiceManagement
import Observation

public enum HelperPackage {
    public static func validate(_ bundle: Bundle = .main) throws {
        guard bundle.bundleIdentifier == HelperIdentity.application else { throw HelperServiceError.untrustedPackage }
        try validateCode(bundle.bundleURL, peer: .application)
        try validateCode(bundle.bundleURL.appendingPathComponent(HelperIdentity.executablePath), peer: .service)
        let plist = bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/" + HelperIdentity.plistName)
        let data = try Data(contentsOf: plist)
        guard data.count <= 65536,
              let document = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              document["Label"] as? String == HelperIdentity.service,
              document["BundleProgram"] as? String == HelperIdentity.executablePath,
              document["UserName"] as? String == "root",
              document["MachServices"] as? [String: Bool] == [HelperIdentity.service: true],
              document["Program"] == nil, document["ProgramArguments"] == nil else { throw HelperServiceError.untrustedPackage }
    }
    private static func validateCode(_ url: URL, peer: HelperIdentity.Peer) throws {
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(HelperIdentity.requirement(for: peer) as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw HelperServiceError.untrustedPackage
        }
    }
}

/// System boundaries are injected together so connection recovery can be exercised
/// without registering a daemon or touching a disk.
@MainActor struct HelperServiceEnvironment {
    var validate: () throws -> Void
    var status: () -> SMAppService.Status
    var register: () throws -> Void
    var systemStatus: () async throws -> HelperStatus
    static func live(_ service: SMAppService) -> Self {
        .init(validate: { try HelperPackage.validate() }, status: { service.status },
              register: { try service.register() }, systemStatus: { try await HelperRPC.systemStatus() })
    }
}

@MainActor @Observable public final class HelperServiceController {
    public enum State: Equatable, Sendable { case unavailable, notRegistered, requiresApproval, connected, failed }
    public private(set) var state: State = .unavailable
    public private(set) var isBusy = false
    public private(set) var lastError: String?
    public private(set) var packageVerified = false
    /// Reported by the connected helper; nil until it is connected.
    public private(set) var fullDiskAccess: Bool?
    /// False until the first status check finishes; `state` is a placeholder before.
    public private(set) var hasChecked = false
    private let service = SMAppService.daemon(plistName: HelperIdentity.plistName)
    static let connectAttempts = 3
    static let connectRetryDelay: Duration = .seconds(2)
    private let environment: HelperServiceEnvironment
    public init() { environment = .live(service) }
    init(environment: HelperServiceEnvironment) { self.environment = environment }
    public var summary: String {
        if isBusy { return String(localized: "正在检查…") }
        switch state {
        case .unavailable: return String(localized: "需完整签名安装版")
        case .notRegistered: return String(localized: "尚未设置")
        case .requiresApproval: return String(localized: "等待系统授权")
        case .connected: return String(localized: "已连接")
        case .failed: return String(localized: "暂时无法连接")
        }
    }
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private func finishOperation() {
        isBusy = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    public func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { finishOperation() }
        await updateState()
    }
    public func register() async {
        // A guide/activation poll may already be checking the old helper. An
        // explicit registration or post-update restore must not be dropped.
        while isBusy { await withCheckedContinuation { idleWaiters.append($0) } }
        guard !Task.isCancelled else { return }
        isBusy = true
        defer { finishOperation() }
        do {
            try environment.validate()
            if HelperRegistrationPolicy.needsRegistration(environment.status()) { try environment.register() }
            await updateState()
        } catch {
            // Register may persist the request and then report that admin
            // approval is required. Preserve that actionable state.
            let message = error.localizedDescription
            await updateState()
            if state != .requiresApproval && state != .connected { lastError = message; state = .failed }
        }
    }
    public func unregister() async {
        guard !isBusy else { return }
        isBusy = true
        defer { finishOperation() }
        do {
            try environment.validate()
            // Atomically stop accepting new cycles before unregistering. A
            // status-only check would race another client's start request.
            if service.status == .enabled {
                _ = try await HelperRPC.mountCycle(.init(action: .quiesce))
            }
            do { try await service.unregister() }
            catch {
                _ = try? await HelperRPC.mountCycle(.init(action: .resume))
                throw error
            }
            await updateState()
        } catch { lastError = error.localizedDescription; state = .failed }
    }
    public func verifyStoppedForUpdate() throws {
        guard !isBusy, service.status == .notRegistered || service.status == .notFound else {
            throw UpdateSafetyError.diskBusy
        }
    }
    public func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }
    /// Polled while the setup guide is open: work out the new values first and
    /// assign them together, so the UI never sees a half-reset state (clearing
    /// `fullDiskAccess` first made the guide flash "complete" on every poll).
    private func updateState() async {
        defer { hasChecked = true }
        var next: (state: State, access: Bool?, error: String?)
        do { try environment.validate(); packageVerified = true }
        catch { packageVerified = false; apply((.unavailable, nil, nil)); return }
        switch environment.status() {
        case .notRegistered, .notFound: next = (.notRegistered, nil, nil)
        case .requiresApproval: next = (.requiresApproval, nil, nil)
        case .enabled:
            // launchd starts the helper on the first request; a cold start
            // (after a login or an update) can outlast one request's timeout.
            next = (.failed, nil, nil)
            for attempt in 0..<Self.connectAttempts {
                if attempt > 0 { try? await Task.sleep(for: Self.connectRetryDelay) }
                do { next = (.connected, try await environment.systemStatus().fullDiskAccess, nil); break }
                catch { next = (.failed, nil, error.localizedDescription) }
            }
        @unknown default: next = (.unavailable, nil, nil)
        }
        apply(next)
    }
    private func apply(_ next: (state: State, access: Bool?, error: String?)) {
        if state != next.state { state = next.state }
        if fullDiskAccess != next.access { fullDiskAccess = next.access }
        if lastError != next.error { lastError = next.error }
    }
}

// A valid sealed package can have no BTM record on its first installation.
enum HelperRegistrationPolicy {
    static func needsRegistration(_ status: SMAppService.Status) -> Bool {
        status == .notRegistered || status == .notFound
    }
}
