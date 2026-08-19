// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FaceUnlock",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "faceunlock", targets: ["FaceUnlock"])
    ],
    targets: [
        .executableTarget(
            name: "FaceUnlock",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("OpenDirectory"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Vision")
            ]
        )
    ]
)
