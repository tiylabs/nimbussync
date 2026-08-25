// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CloudreveMac",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CloudreveDomainKit", targets: ["CloudreveDomainKit"]),
        .library(name: "CloudreveStoreBridge", targets: ["CloudreveStoreBridge"]),
        .library(name: "CloudreveAuthKit", targets: ["CloudreveAuthKit"]),
        .library(name: "CloudreveEventCoordinator", targets: ["CloudreveEventCoordinator"]),
        .library(name: "CloudreveFileProviderKit", targets: ["CloudreveFileProviderKit"]),
        .library(name: "CloudreveDesignSystem", targets: ["CloudreveDesignSystem"]),
        .library(name: "CloudreveObservability", targets: ["CloudreveObservability"]),
        .library(name: "CloudreveDomainService", targets: ["CloudreveDomainService"]),
        .library(name: "CloudreveProductKit", targets: ["CloudreveProductKit"]),
    ],
    targets: [
        .target(
            name: "CloudreveDomainKit",
            path: "Packages/CloudreveDomainKit/Sources"
        ),
        .systemLibrary(
            name: "CSQLite",
            path: "Packages/CSQLite"
        ),
        .target(
            name: "CloudreveStoreBridge",
            dependencies: ["CloudreveDomainKit", "CSQLite"],
            path: "Packages/CloudreveStoreBridge/Sources"
        ),
        .target(
            name: "CloudreveAuthKit",
            dependencies: ["CloudreveDomainKit"],
            path: "Packages/CloudreveAuthKit/Sources"
        ),
        .target(
            name: "CloudreveEventCoordinator",
            dependencies: ["CloudreveDomainKit", "CloudreveStoreBridge", "CloudreveAuthKit"],
            path: "Packages/CloudreveEventCoordinator/Sources"
        ),
        .target(
            name: "CloudreveFileProviderKit",
            dependencies: ["CloudreveDomainKit", "CloudreveStoreBridge", "CloudreveAuthKit", "CloudreveEventCoordinator", "CloudreveObservability"],
            path: "Packages/CloudreveFileProviderKit/Sources"
        ),
        .target(
            name: "CloudreveDesignSystem",
            dependencies: ["CloudreveDomainKit"],
            path: "Packages/CloudreveDesignSystem/Sources"
        ),
        .target(
            name: "CloudreveObservability",
            dependencies: ["CloudreveDomainKit"],
            path: "Packages/CloudreveObservability/Sources"
        ),
        .target(
            name: "CloudreveDomainService",
            dependencies: ["CloudreveDomainKit", "CloudreveStoreBridge", "CloudreveAuthKit"],
            path: "Packages/CloudreveDomainService/Sources"
        ),
        .target(
            name: "CloudreveProductKit",
            dependencies: ["CloudreveDomainKit", "CloudreveStoreBridge", "CloudreveObservability", "CloudreveAuthKit", "CloudreveEventCoordinator"],
            path: "Packages/CloudreveProductKit/Sources",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "CloudreveMacTests",
            dependencies: ["CloudreveDomainKit", "CloudreveStoreBridge", "CloudreveAuthKit", "CloudreveEventCoordinator", "CloudreveFileProviderKit", "CloudreveDomainService", "CloudreveProductKit"],
            path: "Tests/SwiftUnitTests"
        ),
    ]
)
