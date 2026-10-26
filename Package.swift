// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Corral",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Corral", targets: ["Corral"]),
        .executable(name: "corral-cli", targets: ["CorralCLI"]),
    ],
    targets: [
        .target(name: "CorralCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "CorralUI", dependencies: ["CorralCore"]),
        .executableTarget(
            name: "Corral",
            dependencies: ["CorralCore", "CorralUI"],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .executableTarget(name: "CorralCLI", dependencies: ["CorralCore"]),
        .executableTarget(name: "CorralPreview", dependencies: ["CorralCore", "CorralUI"]),
        .testTarget(name: "CorralCoreTests", dependencies: ["CorralCore"]),
    ]
)
