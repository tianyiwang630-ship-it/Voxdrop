// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceInput",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VoiceInputCore", targets: ["VoiceInputCore"]),
        .executable(name: "VoiceInputApp", targets: ["VoiceInputApp"]),
        .executable(name: "VoiceInputCoreChecks", targets: ["VoiceInputCoreChecks"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "VoiceInputCore", dependencies: ["CSQLite"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "VoiceInputApp", dependencies: ["VoiceInputCore"]),
        .executableTarget(name: "VoiceInputCoreChecks", dependencies: ["VoiceInputCore"]),
        .testTarget(name: "VoiceInputCoreTests", dependencies: ["VoiceInputCore"]),
    ]
)
