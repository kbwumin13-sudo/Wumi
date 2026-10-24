// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Miji",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MijiCore", targets: ["MijiCore"]), .executable(name: "miji-extract", targets: ["MijiCLI"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "CContentIndex", dependencies: ["CSQLite"]),
        .target(name: "COilFind", path: "Vendor/OilFind/Sources/COilFind", publicHeadersPath: "include"),
        .target(name: "OilFindCore", dependencies: ["COilFind"], path: "Vendor/OilFind/Sources/OilFindCore"),
        .target(name: "MijiCore", dependencies: ["CSQLite", "OilFindCore", "CContentIndex"]),
        .executableTarget(name: "MijiCLI", dependencies: ["MijiCore"]),
        .testTarget(name: "MijiCoreTests", dependencies: ["MijiCore", "CSQLite", "CContentIndex", "OilFindCore"])
    ],
    swiftLanguageVersions: [.v5]
)
