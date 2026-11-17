// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DGLabConsole",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DGLabConsole", targets: ["DGLabConsole"])],
    targets: [.executableTarget(name: "DGLabConsole", path: "Sources/DGLabConsole")],
    swiftLanguageModes: [.v5]
)
