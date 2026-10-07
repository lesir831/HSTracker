// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AccountProgressProbe",
    platforms: [.macOS(.v10_15)],
    products: [.executable(name: "progress-probe", targets: ["ProgressProbe"])],
    targets: [
        .target(name: "ProgressProbeCore"),
        .executableTarget(name: "ProgressProbe", dependencies: ["ProgressProbeCore"]),
        .testTarget(name: "ProgressProbeCoreTests", dependencies: ["ProgressProbeCore"], resources: [.copy("Fixtures")])
    ]
)
