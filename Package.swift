// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotosIndex",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhotosIndexCore", targets: ["PhotosIndexCore"]),
        .library(name: "PhotosIndexCommand", targets: ["PhotosIndexCommand"]),
        .executable(name: "PhotosIndexApp", targets: ["PhotosIndexApp"]),
        .executable(name: "photosindex", targets: ["PhotosIndexCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "PhotosIndexCore"),
        .target(name: "PhotosIndexCommand", dependencies: ["PhotosIndexCore"]),
        .target(name: "PhotosIndexPhotos", dependencies: ["PhotosIndexCore"]),
        .target(name: "PhotosIndexEvidence", dependencies: ["PhotosIndexCore", "PhotosIndexPhotos"]),
        .target(name: "PhotosIndexExport", dependencies: ["PhotosIndexCore", "PhotosIndexPhotos"]),
        .executableTarget(
            name: "PhotosIndexApp",
            dependencies: [
                "PhotosIndexCore", "PhotosIndexCommand",
                "PhotosIndexPhotos", "PhotosIndexEvidence", "PhotosIndexExport",
            ]
        ),
        .executableTarget(
            name: "PhotosIndexCLI",
            dependencies: [
                "PhotosIndexCore", "PhotosIndexCommand",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "PhotosIndexCoreTests", dependencies: ["PhotosIndexCore"]),
        .testTarget(name: "PhotosIndexCommandTests", dependencies: ["PhotosIndexCommand", "PhotosIndexCore"]),
        .testTarget(name: "PhotosIndexPhotosTests", dependencies: ["PhotosIndexPhotos", "PhotosIndexCore"]),
        .testTarget(name: "PhotosIndexEvidenceTests", dependencies: ["PhotosIndexEvidence", "PhotosIndexCore"]),
        .testTarget(name: "PhotosIndexExportTests", dependencies: ["PhotosIndexExport", "PhotosIndexCore"]),
        .testTarget(name: "PhotosIndexAppTests", dependencies: ["PhotosIndexApp", "PhotosIndexCore"]),
        .testTarget(
            name: "PhotosIndexCLITests",
            dependencies: [
                "PhotosIndexCLI", "PhotosIndexCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
