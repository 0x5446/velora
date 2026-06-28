// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Velora",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Velora",
            targets: ["Velora"]
        ),
        .executable(
            name: "VeloraMac",
            targets: ["VeloraMac"]
        ),
        .executable(
            name: "VeloraDiagnostics",
            targets: ["VeloraDiagnostics"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Velora"
        ),
        .executableTarget(
            name: "VeloraMac",
            dependencies: ["Velora"]
        ),
        .executableTarget(
            name: "VeloraDiagnostics",
            dependencies: ["Velora"]
        ),
        .testTarget(
            name: "VeloraTests",
            dependencies: ["Velora"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
