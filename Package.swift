// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentPulse",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "AgentPulseCore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/AgentPulseCore"
        ),

        .executableTarget(
            name: "AgentPulse",
            dependencies: ["AgentPulseCore"],
            path: "Sources/AgentPulse",
            resources: [.process("Resources")]
        ),

        .executableTarget(
            name: "AgentPulseBridge",
            path: "Sources/AgentPulseBridge"
        ),
    ]
)
