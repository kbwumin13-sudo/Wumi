// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DirDesk",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "DirDesk", targets: ["DirDesk"]),
        .library(name: "DirDeskCore", targets: ["DirDeskCore"]),
    ],
    dependencies: [.package(path: "Vendor/Miji")],
    targets: [
        .target(
            name: "CArchive",
            linkerSettings: [.linkedLibrary("archive")]
        ),
        .target(
            name: "DirDeskCore",
            dependencies: ["CArchive", .product(name: "MijiCore", package: "Miji")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedLibrary("z")]
        ),
        .executableTarget(
            name: "DirDesk",
            dependencies: ["DirDeskCore", .product(name: "MijiCore", package: "Miji")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DirDeskCoreTests",
            dependencies: ["DirDeskCore", .product(name: "MijiCore", package: "Miji")],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
