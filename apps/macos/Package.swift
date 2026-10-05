// swift-tools-version: 6.0
import PackageDescription
import Foundation
let formatEnginePath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../.workbench/format-engine").standardized.path
let sparklePath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../.workbench/sparkle-build/Build/Products/Release").standardized.path
let package = Package(name: "Volisle", defaultLocalization: "zh-Hans", platforms: [.macOS("15.4")],
    products: [.executable(name: "Volisle", targets: ["Volisle"]), .executable(name: "VolisleProbe", targets: ["VolisleProbe"]),
               .executable(name: "VolisleMountProbe", targets: ["VolisleMountProbe"]),
               .executable(name: "VolisleMountHelper", targets: ["VolisleMountHelper"]),
               .executable(name: "VolisleHelperProbe", targets: ["VolisleHelperProbe"])],
    dependencies: [.package(path: "../../packages/VolisleCore")],
    targets: [.executableTarget(name: "Volisle", dependencies: ["VolisleCore"], resources: [.process("Resources")],
                  swiftSettings: [.unsafeFlags(["-F", sparklePath])],
                  linkerSettings: [.unsafeFlags(["-F", sparklePath, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]), .linkedFramework("Sparkle")]),
              .executableTarget(name: "VolisleProbe", dependencies: ["VolisleCore"]),
              .executableTarget(name: "VolisleMountProbe", dependencies: ["VolisleCore"]),
              .target(name: "VolisleNTFSFormat"),
              // Only the root helper can format: it alone links the NTFS engine.
              .executableTarget(name: "VolisleMountHelper", dependencies: ["VolisleCore", "VolisleNTFSFormat"],
                  linkerSettings: [.unsafeFlags(["-L", formatEnginePath, "-lvolisleformat"])]),
              .executableTarget(name: "VolisleHelperProbe", dependencies: ["VolisleCore"])])
