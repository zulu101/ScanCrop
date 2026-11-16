// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScanCrop",
    platforms: [.macOS(.v14)],
    targets: [
        // Detection and cropping, without any UI. Tested on its own.
        .target(
            name: "ScanCropCore",
            path: "Sources/ScanCropCore"
        ),
        .executableTarget(
            name: "ScanCrop",
            dependencies: ["ScanCropCore"],
            path: "Sources/ScanCrop"
        ),
        .testTarget(
            name: "ScanCropCoreTests",
            dependencies: ["ScanCropCore"],
            path: "Tests/ScanCropCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
