// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OneImageCompare",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OneImageCompare", targets: ["OneImageCompare"])
    ],
    targets: [
        .executableTarget(
            name: "OneImageCompare",
            path: "Sources/OneImageCompare",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Metal"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Vision"),
                .linkedFramework("PDFKit")
            ]
        )
    ]
)
