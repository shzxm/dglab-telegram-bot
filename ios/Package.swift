// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "DGLabCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "DGLabCore", targets: ["DGLabCore"])],
    targets: [
        .target(name: "DGLabCore", path: "DGLabControl/Core", exclude: ["Info.plist"]),
        .testTarget(name: "DGLabCoreTests", dependencies: ["DGLabCore"], path: "Tests/DGLabCoreTests"),
        .executableTarget(name: "DGLabCoreChecks", dependencies: ["DGLabCore"], path: "Checks")
    ]
)
