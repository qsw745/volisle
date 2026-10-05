// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "VolisleCore", platforms: [.macOS("15.4")],
    products: [.library(name: "VolisleCore", targets: ["VolisleCore"])],
    targets: [.target(name: "VolisleDiskIO"), .target(name: "VolisleCore", dependencies: ["VolisleDiskIO"]), .testTarget(name: "VolisleCoreTests", dependencies: ["VolisleCore"])])
