// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "anise-recorder",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "anise-recorder", targets: ["AniseRecorder"])
    ],
    targets: [
        .target(
            name: "AniseRecorderCore",
            path: "Sources/AniseRecorderCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "AniseRecorder",
            dependencies: ["AniseRecorderCore"],
            path: "Sources/AniseRecorder",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Speech"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("VideoToolbox")
            ]
        ),
        .testTarget(
            name: "AniseRecorderCoreTests",
            dependencies: ["AniseRecorderCore"],
            path: "Tests/AniseRecorderCoreTests"
        ),
        .testTarget(
            name: "AniseRecorderTests",
            dependencies: ["AniseRecorder", "AniseRecorderCore"],
            path: "Tests/AniseRecorderTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
