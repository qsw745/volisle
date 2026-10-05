import Foundation
import Security

/// Diagnostics only: a signed entitlement never authorizes a disk mutation.
/// The SDK used by this build exposes mounting, but no public constructor for
/// a client's block-device proxy. Do not substitute a private selector or URL.
public struct NativeMountPrerequisites: Codable, Equatable, Sendable {
    public enum Entitlement: String, Codable, Sendable { case present, absent, unknown }
    public enum Blocker: String, Codable, Sendable {
        case unsupportedSystem, signatureUnreadable, missingEntitlement, blockResourceUnavailable
    }
    public let nativeAPIAvailable: Bool
    public let mountEntitlement: Entitlement
    public let blockResourceCreationAvailable: Bool
    public var blocker: Blocker {
        if !nativeAPIAvailable { return .unsupportedSystem }
        switch mountEntitlement {
        case .unknown: return .signatureUnreadable
        case .absent: return .missingEntitlement
        case .present: return .blockResourceUnavailable
        }
    }
    public init(osMajor: Int, entitlement: Entitlement) {
        nativeAPIAvailable = osMajor >= 27
        mountEntitlement = entitlement
        blockResourceCreationAvailable = false
    }
    public static var current: Self {
        .init(osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
              entitlement: currentEntitlement())
    }
    static func entitlementState(value: Any?) -> Entitlement {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
              value as? Bool == true else { return .absent }
        return .present
    }
    private static func currentEntitlement() -> Entitlement {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unknown }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return .unknown }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return .unknown }
        // Read only the actual signing dictionary, never Info.plist or a config
        // claiming that an entitlement was requested. Nothing sensitive leaves.
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        return entitlementState(value: entitlements?["com.apple.developer.fskit.mount"])
    }
    public var summary: String {
        switch blocker {
        case .unsupportedSystem: String(localized: "当前系统未提供此原生挂载接口")
        case .signatureUnreadable: String(localized: "无法确认当前程序的挂载签名权限")
        case .missingEntitlement: String(localized: "当前程序未签入原生挂载权限")
        case .blockResourceUnavailable: String(localized: "签名包含挂载权限，磁盘资源接入尚未完成")
        }
    }
}
