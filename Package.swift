// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DriveTrace",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DriveCore", targets: ["DriveCore"]),
               .executable(name: "DriveTrace", targets: ["DriveTrace"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "DriveCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "DriveTrace", dependencies: ["DriveCore"], resources: [.copy("Resources/drivetrace-icon.png")]),
        .executableTarget(name: "DriveBenchmarks", dependencies: ["DriveCore"], path: "Benchmarks"),
        .testTarget(name: "DriveCoreTests", dependencies: ["DriveCore", "DriveTrace"])
    ]
)
