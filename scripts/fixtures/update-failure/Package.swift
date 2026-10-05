// swift-tools-version: 6.0
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..").standardized.path
let sparkle = root + "/.workbench/sparkle-build/Build/Products/Release"
let package = Package(name: "UpdateFailureFixture", platforms: [.macOS("26.4")], targets: [
    .executableTarget(name: "UpdateFailureFixture", swiftSettings: [.unsafeFlags(["-F", sparkle])],
        linkerSettings: [.unsafeFlags(["-F", sparkle, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]), .linkedFramework("Sparkle")])
])
