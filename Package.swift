// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fleet-rollout-kit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "FleetRollout", targets: ["FleetRollout"]),
        .library(name: "FleetRolloutUI", targets: ["FleetRolloutUI"])
    ],
    targets: [
        .target(name: "FleetRollout"),
        .target(name: "FleetRolloutUI", dependencies: ["FleetRollout"]),
        .executableTarget(name: "FleetRolloutDemo", dependencies: ["FleetRollout"]),
        .testTarget(name: "FleetRolloutTests", dependencies: ["FleetRollout"])
    ]
)
