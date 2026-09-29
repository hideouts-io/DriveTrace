// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DriveMonitorSwift",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DriveCore", targets: ["DriveCore"]),
               .executable(name: "DriveExplorer", targets: ["DriveExplorer"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "DriveCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "DriveExplorer", dependencies: ["DriveCore"], resources: [.copy("Resources/drive-explorer-logo.png")]),
        .testTarget(name: "DriveCoreTests", dependencies: ["DriveCore", "DriveExplorer"])
    ]
)
